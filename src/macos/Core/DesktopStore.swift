import Foundation
import SQLite3
import MinisAppleDomain
import MinisProviderDomain

public enum DesktopStoreError: LocalizedError, Sendable {
    case open(String)
    case sqlite(String)
    case encoding(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): "Unable to open Minis database: \(message)"
        case .sqlite(let message): "Minis database error: \(message)"
        case .encoding(let message): "Unable to decode Minis record: \(message)"
        }
    }
}

/// Single-writer persistence owned by the desktop Runtime. Records are kept as
/// versionable JSON inside the same logical tables used by the mobile store;
/// the runtime protocol, rather than the UI, is the only write path.
public actor DesktopStore: ChatRepository, PortableRecordRepository {
    private var db: OpaquePointer?
    public let databaseURL: URL

    public init(baseURL: URL? = nil) throws {
        let root: URL
        if let baseURL {
            root = baseURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            root = support.appendingPathComponent("Minis", isDirectory: true).appendingPathComponent("Database", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep the desktop store versioned and physically separate until its
        // migrations are proven compatible with the legacy iOS ChatStore.
        databaseURL = root.appendingPathComponent("minis-desktop-v1.db")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw DesktopStoreError.open(message)
        }
        db = handle
        try Self.configure(handle)
    }

    public func snapshot(states: [String: RuntimeState] = [:]) throws -> RuntimeSnapshot {
        RuntimeSnapshot(conversations: try list(RuntimeConversation.self, table: "desktop_sessions"), agents: try list(RuntimeAgentRecord.self, table: "desktop_agents").filter { !$0.archived }, groups: try list(RuntimeGroupRecord.self, table: "desktop_agent_groups").filter { !$0.archived }, states: states)
    }

    public func listConversations() throws -> [RuntimeConversation] {
        try list(RuntimeConversation.self, table: "desktop_sessions").sorted { $0.updatedAt > $1.updatedAt }
    }

    public func conversation(_ id: String) throws -> RuntimeConversation? {
        try record(RuntimeConversation.self, id: id, table: "desktop_sessions")
    }

    public func upsertConversation(_ value: RuntimeConversation) throws {
        try upsert(value, id: value.id, table: "desktop_sessions", updatedAt: value.updatedAt)
        try markPortableDirtyRow(PortableDirtyRecord(id: SyncRecordID(type: SyncedSession.recordType, id: value.id), updatedAt: value.updatedAt))
    }

    public func deleteConversation(_ id: String) throws {
        let deletedAt = Date()
        try transaction {
            try delete(id: id, table: "desktop_sessions")
            try execute("DELETE FROM desktop_messages WHERE session_id = ?", bindings: [id])
            try recordPortableTombstone(SyncRecordID(type: SyncedSession.recordType, id: id), deletedAt: deletedAt)
            try markPortableDirtyRow(PortableDirtyRecord(id: SyncRecordID(type: SyncedSession.recordType, id: id), operation: .delete, updatedAt: deletedAt))
        }
    }

    public func messages(sessionID: String) throws -> [RuntimeMessageRecord] {
        let sql = "SELECT record_json FROM desktop_messages WHERE session_id = ? ORDER BY sequence ASC"
        return try query(sql, bindings: [sessionID]).map { data in
            do { return try JSONDecoder.runtime.decode(RuntimeMessageRecord.self, from: data) }
            catch { throw DesktopStoreError.encoding(error.localizedDescription) }
        }
    }

    public func appendMessage(_ message: RuntimeMessageRecord) throws {
        let sequence = try scalarInt("SELECT COALESCE(MAX(sequence), -1) + 1 FROM desktop_messages WHERE session_id = ?", bindings: [message.sessionID])
        let data = try JSONEncoder.runtime.encode(message)
        try execute("INSERT OR REPLACE INTO desktop_messages (id, session_id, sequence, record_json, created_at) VALUES (?, ?, ?, ?, ?)", bindings: [message.id, message.sessionID, sequence, data, message.createdAt.timeIntervalSince1970])
        try markPortableDirtyRow(PortableDirtyRecord(id: SyncRecordID(type: SyncedMessage.recordType, id: message.id), updatedAt: message.createdAt))
        if var conversation = try conversation(message.sessionID) {
            conversation.updatedAt = message.createdAt
            try upsertConversation(conversation)
        }
    }

    public func listAgents() throws -> [RuntimeAgentRecord] {
        try list(RuntimeAgentRecord.self, table: "desktop_agents").filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func agent(_ id: String) throws -> RuntimeAgentRecord? { try record(RuntimeAgentRecord.self, id: id, table: "desktop_agents") }
    public func upsertAgent(_ value: RuntimeAgentRecord) throws { try upsert(value, id: value.id, table: "desktop_agents", updatedAt: value.updatedAt) }

    public func listGroups() throws -> [RuntimeGroupRecord] {
        try list(RuntimeGroupRecord.self, table: "desktop_agent_groups").filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func group(_ id: String) throws -> RuntimeGroupRecord? { try record(RuntimeGroupRecord.self, id: id, table: "desktop_agent_groups") }
    public func upsertGroup(_ value: RuntimeGroupRecord) throws { try upsert(value, id: value.id, table: "desktop_agent_groups", updatedAt: value.updatedAt) }

    public func appendAudit(_ value: RuntimeAuditRecord) throws {
        let data = try JSONEncoder.runtime.encode(value)
        try execute(
            "INSERT INTO runtime_audit (id, session_id, record_json, created_at) VALUES (?, ?, ?, ?)",
            bindings: [value.id, value.sessionID ?? NSNull(), data, value.createdAt.timeIntervalSince1970]
        )
    }

    public func audit(sessionID: String? = nil, limit: Int = 200) throws -> [RuntimeAuditRecord] {
        let boundedLimit = max(1, min(limit, 1_000))
        let sql: String
        let bindings: [Any]
        if let sessionID {
            sql = "SELECT record_json FROM runtime_audit WHERE session_id = ? ORDER BY created_at DESC LIMIT ?"
            bindings = [sessionID, boundedLimit]
        } else {
            sql = "SELECT record_json FROM runtime_audit ORDER BY created_at DESC LIMIT ?"
            bindings = [boundedLimit]
        }
        return try query(sql, bindings: bindings).map { data in
            do { return try JSONDecoder.runtime.decode(RuntimeAuditRecord.self, from: data) }
            catch { throw DesktopStoreError.encoding(error.localizedDescription) }
        }
    }

    public func setMetadata<T: Encodable>(_ value: T, for key: String) throws {
        let data = try JSONEncoder.runtime.encode(value)
        guard let string = String(data: data, encoding: .utf8) else { throw DesktopStoreError.encoding("Metadata is not UTF-8 JSON.") }
        try execute("INSERT OR REPLACE INTO runtime_metadata (key, value) VALUES (?, ?)", bindings: [key, string])
    }

    public func metadata<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM runtime_metadata WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        try bind([key], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        do { return try JSONDecoder.runtime.decode(type, from: Data(String(cString: text).utf8)) }
        catch { throw DesktopStoreError.encoding(error.localizedDescription) }
    }

    // MARK: - Provider configuration registry

    /// Returns every non-secret provider configuration. The first macOS
    /// preview persisted only `provider.default`; fold that record into the
    /// registry on read so upgrades do not require a destructive migration.
    public func providerConfigurations() throws -> [ProviderConfiguration] {
        var values = try metadata([ProviderConfiguration].self, for: "provider.configurations") ?? []
        if let legacy = try metadata(ProviderConfiguration.self, for: "provider.default"),
           !values.contains(where: { $0.id == legacy.id }) {
            values.insert(legacy, at: 0)
        }

        var seen = Set<String>()
        return values.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    /// Upserts a configuration while keeping the legacy default key current.
    /// Credentials remain exclusively in the injected CredentialStore.
    public func upsertProviderConfiguration(_ value: ProviderConfiguration, makeDefault: Bool = false) throws {
        let legacyDefault = try metadata(ProviderConfiguration.self, for: "provider.default")
        var values = try providerConfigurations()
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
        try setMetadata(values, for: "provider.configurations")

        let persistedDefaultID = try metadata(String.self, for: "provider.default-id")
        let existingDefaultID = persistedDefaultID ?? legacyDefault?.id
        if makeDefault || existingDefaultID == nil || value.id == existingDefaultID || value.id == "default" {
            try setMetadata(value.id, for: "provider.default-id")
            try setMetadata(value, for: "provider.default")
        } else if persistedDefaultID == nil, let existingDefaultID {
            try setMetadata(existingDefaultID, for: "provider.default-id")
        }
    }

    public func providerConfiguration(id: String) throws -> ProviderConfiguration? {
        try providerConfigurations().first { $0.id == id }
    }

    public func defaultProviderConfiguration() throws -> ProviderConfiguration? {
        let values = try providerConfigurations()
        if let id = try metadata(String.self, for: "provider.default-id"),
           let selected = values.first(where: { $0.id == id }) {
            return selected
        }
        return try metadata(ProviderConfiguration.self, for: "provider.default") ?? values.first
    }

    @discardableResult
    public func setProviderConfigurationID(_ providerID: String?, forSession sessionID: String) throws -> RuntimeConversation? {
        guard var conversation = try conversation(sessionID) else { return nil }
        conversation.providerConfigurationID = providerID
        conversation.updatedAt = Date()
        try upsertConversation(conversation)
        return conversation
    }

    public func createGroup(_ group: RuntimeGroupRecord, conversation: RuntimeConversation) throws {
        try transaction {
            try upsert(conversation, id: conversation.id, table: "desktop_sessions", updatedAt: conversation.updatedAt)
            try upsert(group, id: group.id, table: "desktop_agent_groups", updatedAt: group.updatedAt)
        }
    }

    // MARK: - Shared ChatRepository adapter

    public func repositorySessions() async throws -> [ChatSession] {
        try listConversations().compactMap { conversation in
            let session = Self.mergedChatSession(try storedChatSession(id: conversation.id), with: conversation)
            guard session.spawnRole != "subagent", session.spawnRole != "group-member" else { return nil }
            return session
        }
    }

    public func repositorySession(id: String) async throws -> ChatSession? {
        guard let conversation = try conversation(id) else { return nil }
        return Self.mergedChatSession(try storedChatSession(id: id), with: conversation)
    }

    public func repositorySaveSession(_ session: ChatSession) async throws {
        var conversation = Self.runtimeConversation(from: session)
        // ChatSession intentionally has no desktop-only workspace, shell or
        // provider binding fields. Preserve them when Sync V2 or the shared
        // repository updates the portable portion of an existing session.
        if let existing = try self.conversation(session.id) {
            conversation.groupID = existing.groupID
            conversation.workspaceID = existing.workspaceID
            conversation.agentShellAccess = existing.agentShellAccess
            conversation.providerConfigurationID = existing.providerConfigurationID
        }
        try upsertConversation(conversation)
        let data = try JSONEncoder.runtime.encode(session)
        try execute("UPDATE desktop_sessions SET chat_record_json = ? WHERE id = ?", bindings: [data, session.id])
    }

    public func repositoryDeleteSession(id: String) async throws {
        try deleteConversation(id)
    }

    public func repositoryMessages(sessionId: String) async throws -> [RawMessage] {
        let sql = "SELECT record_json, chat_record_json FROM desktop_messages WHERE session_id = ? ORDER BY sequence ASC"
        return try queryChatMessages(sql, bindings: [sessionId]).map { runtimeData, chatData in
            if let chatData {
                do { return try JSONDecoder.runtime.decode(RawMessage.self, from: chatData) }
                catch { throw DesktopStoreError.encoding(error.localizedDescription) }
            }
            do {
                let runtime = try JSONDecoder.runtime.decode(RuntimeMessageRecord.self, from: runtimeData)
                return Self.rawMessage(from: runtime)
            } catch {
                throw DesktopStoreError.encoding(error.localizedDescription)
            }
        }
    }

    public func repositoryAppendMessages(_ messages: [RawMessage]) async throws {
        try appendRepositoryMessages(messages, markDirty: true)
    }

    private func appendRepositoryMessages(_ messages: [RawMessage], markDirty: Bool) throws {
        guard !messages.isEmpty else { return }
        try transaction {
            for message in messages {
                let sequence = try scalarInt(
                    "SELECT COALESCE(MAX(sequence), -1) + 1 FROM desktop_messages WHERE session_id = ?",
                    bindings: [message.sessionId]
                )
                let runtime = Self.runtimeMessage(from: message)
                let runtimeData = try JSONEncoder.runtime.encode(runtime)
                let chatData = try JSONEncoder.runtime.encode(message)
                try execute(
                    "INSERT OR REPLACE INTO desktop_messages (id, session_id, sequence, record_json, chat_record_json, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                    bindings: [message.id, message.sessionId, sequence, runtimeData, chatData, message.createdAt.timeIntervalSince1970]
                )
                if markDirty {
                    try markPortableDirtyRow(PortableDirtyRecord(id: SyncRecordID(type: SyncedMessage.recordType, id: message.id), updatedAt: message.createdAt))
                }
            }
            let messagesBySession = Dictionary(grouping: messages, by: \.sessionId)
            for (sessionID, sessionMessages) in messagesBySession {
                if var conversation = try conversation(sessionID),
                   let newest = sessionMessages.max(by: { $0.createdAt < $1.createdAt }) {
                    conversation.updatedAt = max(conversation.updatedAt, newest.createdAt)
                    if markDirty { try upsertConversation(conversation) }
                    else { try upsert(conversation, id: conversation.id, table: "desktop_sessions", updatedAt: conversation.updatedAt) }
                }
            }
        }
    }

    // MARK: - Portable Sync V2 repository

    public func exportPortableRecord(id: SyncRecordID) async throws -> PortableRecord? {
        let previous = try storedPortableRecord(id)
        switch id.type {
        case SyncedSession.recordType:
            guard let session = try await repositorySession(id: id.id) else { return nil }
            let previousShape = previous.flatMap(SyncedSession.init(portableRecord:))
            let shape = SyncedSession.from(
                session,
                memoryEnabled: (previousShape?.memoryEnabled ?? 1) != 0,
                modelBinding: previousShape?.modelBinding
            )
            return shape.portableRecord(unknownFields: previous?.unknownFields ?? [:])
        case SyncedMessage.recordType:
            guard let message = try repositoryMessage(id: id.id) else { return nil }
            let updatedAt = max(previous?.updatedAt ?? message.createdAt, message.createdAt)
            return SyncedMessage.from(message, updatedAt: updatedAt)
                .portableRecord(unknownFields: previous?.unknownFields ?? [:])
        default:
            return nil
        }
    }

    public func applyPortableRecord(_ record: PortableRecord) async throws -> PortableApplyResult {
        guard (record.minimumCompatibleVersion ?? 1) <= 1 else { return .unsupportedType }
        guard record.id.type == SyncedSession.recordType || record.id.type == SyncedMessage.recordType else {
            return .unsupportedType
        }
        if let deletedAt = try portableTombstoneDate(record.id), deletedAt >= record.updatedAt {
            return .ignoredOlder
        }
        if let localUpdatedAt = try await portableLocalUpdatedAt(record.id), localUpdatedAt > record.updatedAt {
            return .ignoredOlder
        }

        switch record.id.type {
        case SyncedSession.recordType:
            guard let remote = SyncedSession(portableRecord: record) else { return .invalidRecord }
            let local = try await repositorySession(id: remote.id)
            let session = ChatSession(
                id: remote.id,
                title: remote.title,
                category: remote.category,
                modelId: remote.modelId,
                createdAt: remote.createdAt,
                updatedAt: remote.updatedAt,
                lastMessage: local?.lastMessage,
                source: local?.source,
                lastSyncedAt: local?.lastSyncedAt,
                remoteDeviceId: local?.remoteDeviceId,
                remoteDeviceName: local?.remoteDeviceName,
                pinnedAt: remote.pinnedAt,
                agentId: local?.agentId,
                parentSessionId: local?.parentSessionId,
                spawnRole: local?.spawnRole,
                spawnTitle: local?.spawnTitle,
                spawnStatus: local?.spawnStatus,
                spawnResult: local?.spawnResult
            )
            try await repositorySaveSession(session)
        case SyncedMessage.recordType:
            guard let remote = SyncedMessage(portableRecord: record),
                  let role = MessageRole(rawValue: remote.role),
                  let partsData = remote.partsJson.data(using: .utf8),
                  let parts = try? JSONDecoder().decode([ContentPart].self, from: partsData) else {
                return .invalidRecord
            }
            let usage: StoredTokenUsage?
            if let usageJSON = remote.tokenUsageJson, let data = usageJSON.data(using: .utf8) {
                usage = try? JSONDecoder().decode(StoredTokenUsage.self, from: data)
            } else {
                usage = nil
            }
            let existing = try repositoryMessage(id: remote.id)
            let message = RawMessage(
                id: remote.id,
                sessionId: remote.sessionId,
                role: role,
                parts: parts,
                createdAt: remote.createdAt,
                tokenUsage: usage,
                reasoningContent: remote.reasoningContent,
                streamInterruptCount: remote.streamInterruptCount,
                sortOrder: remote.sortOrder,
                errorInfo: existing?.errorInfo,
                senderAgentId: existing?.senderAgentId
            )
            try appendRepositoryMessages([message], markDirty: false)
        default:
            return .unsupportedType
        }

        let normalized = Self.separatingUnknownFields(record)
        try storePortableRecord(normalized)
        try deletePortableTombstone(record.id)
        try clearPortableDirtyRows([record.id])
        return .applied
    }

    public func applyPortableDelete(_ id: SyncRecordID, updatedAt: Date) async throws -> PortableApplyResult {
        guard id.type == SyncedSession.recordType || id.type == SyncedMessage.recordType else { return .unsupportedType }
        if let localUpdatedAt = try await portableLocalUpdatedAt(id), localUpdatedAt > updatedAt { return .ignoredOlder }
        try transaction {
            switch id.type {
            case SyncedSession.recordType:
                // A remote delete must retain the wire timestamp. Routing it
                // through deleteConversation would manufacture a newer local
                // Date() tombstone and could incorrectly reject a later peer
                // write that is newer than the delete but older than this Mac.
                try delete(id: id.id, table: "desktop_sessions")
                try execute("DELETE FROM desktop_messages WHERE session_id = ?", bindings: [id.id])
            case SyncedMessage.recordType:
                try execute("DELETE FROM desktop_messages WHERE id = ?", bindings: [id.id])
            default:
                return
            }
            try execute("DELETE FROM desktop_sync_records WHERE record_name = ?", bindings: [id.description])
            try recordPortableTombstone(id, deletedAt: updatedAt)
            try clearPortableDirtyRows([id])
        }
        return .applied
    }

    public func markPortableDirty(_ dirty: PortableDirtyRecord) async throws {
        try markPortableDirtyRow(dirty)
    }

    public func pendingPortableDirty(limit: Int = 200) async throws -> [PortableDirtyRecord] {
        let bounded = max(1, min(limit, 2_000))
        var statement: OpaquePointer?
        let sql = "SELECT record_type, object_id, operation, priority, updated_at FROM desktop_sync_dirty ORDER BY priority ASC, updated_at ASC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        try bind([bounded], to: statement)
        var result: [PortableDirtyRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let typeText = sqlite3_column_text(statement, 0),
                  let idText = sqlite3_column_text(statement, 1),
                  let operationText = sqlite3_column_text(statement, 2),
                  let operation = PortableDirtyRecord.Operation(rawValue: String(cString: operationText)) else { continue }
            result.append(PortableDirtyRecord(
                id: SyncRecordID(type: String(cString: typeText), id: String(cString: idText)),
                operation: operation,
                priority: Int(sqlite3_column_int64(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return result
    }

    public func clearPortableDirty(_ ids: [SyncRecordID]) async throws {
        try clearPortableDirtyRows(ids)
    }

    /// Applies a complete, read-only snapshot from an iOS ChatStore. The
    /// importer builds this value before calling the store, so an unreadable or
    /// malformed legacy database cannot leave a partially-imported desktop DB.
    ///
    /// Records with a newer desktop timestamp win on repeat imports. Messages
    /// are immutable transcript entries and therefore use their stable legacy
    /// IDs as an `INSERT OR IGNORE` key.
    public func importLegacy(_ value: LegacyChatStoreImport) throws -> LegacyChatStoreImportResult {
        var importedConversations = 0
        var importedAgents = 0
        var importedGroups = 0
        var importedMessages = 0

        try transaction {
            for conversation in value.conversations {
                if try importIfNewer(conversation, id: conversation.id, table: "desktop_sessions", updatedAt: conversation.updatedAt) {
                    importedConversations += 1
                }
            }
            for agent in value.agents {
                if try importIfNewer(agent, id: agent.id, table: "desktop_agents", updatedAt: agent.updatedAt) {
                    importedAgents += 1
                }
            }
            for group in value.groups {
                if try importIfNewer(group, id: group.id, table: "desktop_agent_groups", updatedAt: group.updatedAt) {
                    importedGroups += 1
                }
            }
            for message in value.messages {
                if try insertLegacyMessageIfMissing(message) {
                    importedMessages += 1
                }
            }
        }

        return LegacyChatStoreImportResult(
            conversations: importedConversations,
            agents: importedAgents,
            groups: importedGroups,
            messages: importedMessages
        )
    }

    private static func configure(_ db: OpaquePointer?) throws {
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS runtime_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS desktop_sessions (id TEXT PRIMARY KEY, record_json BLOB NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS desktop_messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, sequence INTEGER NOT NULL, record_json BLOB NOT NULL, chat_record_json BLOB, created_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_desktop_messages_session_sequence ON desktop_messages(session_id, sequence);
        CREATE TABLE IF NOT EXISTS desktop_agents (id TEXT PRIMARY KEY, record_json BLOB NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS desktop_agent_groups (id TEXT PRIMARY KEY, record_json BLOB NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS runtime_audit (id TEXT PRIMARY KEY, session_id TEXT, record_json BLOB NOT NULL, created_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_runtime_audit_session_created ON runtime_audit(session_id, created_at DESC);
        CREATE TABLE IF NOT EXISTS desktop_sync_records (record_name TEXT PRIMARY KEY, record_type TEXT NOT NULL, object_id TEXT NOT NULL, record_json BLOB NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS desktop_sync_dirty (record_name TEXT PRIMARY KEY, record_type TEXT NOT NULL, object_id TEXT NOT NULL, operation TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_desktop_sync_dirty_order ON desktop_sync_dirty(priority ASC, updated_at ASC);
        CREATE TABLE IF NOT EXISTS desktop_sync_tombstones (record_name TEXT PRIMARY KEY, deleted_at REAL NOT NULL);
        INSERT OR REPLACE INTO runtime_metadata(key, value) VALUES ('schema_version', '1');
        """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, schema, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "schema setup failed"
            sqlite3_free(error)
            throw DesktopStoreError.sqlite(message)
        }
        try addColumnIfMissing(db, table: "desktop_sessions", column: "chat_record_json", definition: "BLOB")
        try addColumnIfMissing(db, table: "desktop_messages", column: "chat_record_json", definition: "BLOB")
    }

    private func list<T: Decodable>(_ type: T.Type, table: String) throws -> [T] {
        try query("SELECT record_json FROM \(table) ORDER BY updated_at DESC").map { data in
            do { return try JSONDecoder.runtime.decode(type, from: data) }
            catch { throw DesktopStoreError.encoding(error.localizedDescription) }
        }
    }

    private func record<T: Decodable>(_ type: T.Type, id: String, table: String) throws -> T? {
        guard let data = try query("SELECT record_json FROM \(table) WHERE id = ? LIMIT 1", bindings: [id]).first else { return nil }
        do { return try JSONDecoder.runtime.decode(type, from: data) }
        catch { throw DesktopStoreError.encoding(error.localizedDescription) }
    }

    private func upsert<T: Encodable>(_ value: T, id: String, table: String, updatedAt: Date) throws {
        let data = try JSONEncoder.runtime.encode(value)
        try execute(
            "INSERT INTO \(table) (id, record_json, updated_at) VALUES (?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET record_json = excluded.record_json, updated_at = excluded.updated_at",
            bindings: [id, data, updatedAt.timeIntervalSince1970]
        )
    }

    private func storedChatSession(id: String) throws -> ChatSession? {
        guard let data = try query("SELECT chat_record_json FROM desktop_sessions WHERE id = ? AND chat_record_json IS NOT NULL LIMIT 1", bindings: [id]).first else {
            return nil
        }
        do { return try JSONDecoder.runtime.decode(ChatSession.self, from: data) }
        catch { throw DesktopStoreError.encoding(error.localizedDescription) }
    }

    private func repositoryMessage(id: String) throws -> RawMessage? {
        guard let (runtimeData, chatData) = try queryChatMessages(
            "SELECT record_json, chat_record_json FROM desktop_messages WHERE id = ? LIMIT 1",
            bindings: [id]
        ).first else { return nil }
        do {
            if let chatData { return try JSONDecoder.runtime.decode(RawMessage.self, from: chatData) }
            return Self.rawMessage(from: try JSONDecoder.runtime.decode(RuntimeMessageRecord.self, from: runtimeData))
        } catch {
            throw DesktopStoreError.encoding(error.localizedDescription)
        }
    }

    private func storedPortableRecord(_ id: SyncRecordID) throws -> PortableRecord? {
        guard let data = try query("SELECT record_json FROM desktop_sync_records WHERE record_name = ? LIMIT 1", bindings: [id.description]).first else { return nil }
        do { return try JSONDecoder.runtime.decode(PortableRecord.self, from: data) }
        catch { throw DesktopStoreError.encoding(error.localizedDescription) }
    }

    private func storePortableRecord(_ record: PortableRecord) throws {
        let data = try JSONEncoder.runtime.encode(record)
        try execute(
            "INSERT INTO desktop_sync_records (record_name, record_type, object_id, record_json, updated_at) VALUES (?, ?, ?, ?, ?) "
                + "ON CONFLICT(record_name) DO UPDATE SET record_json = excluded.record_json, updated_at = excluded.updated_at",
            bindings: [record.id.description, record.id.type, record.id.id, data, record.updatedAt.timeIntervalSince1970]
        )
    }

    private static func separatingUnknownFields(_ record: PortableRecord) -> PortableRecord {
        let knownKeys: Set<String>
        switch record.id.type {
        case SyncedSession.recordType: knownKeys = SyncedSession.fieldKeys
        case SyncedMessage.recordType: knownKeys = SyncedMessage.fieldKeys
        default: knownKeys = []
        }
        let knownFields = record.fields.filter { knownKeys.contains($0.key) }
        return PortableRecord(
            id: record.id,
            fields: knownFields,
            assets: record.assets,
            schemaVersion: record.schemaVersion,
            minimumCompatibleVersion: record.minimumCompatibleVersion,
            unknownFields: record.unknownFields(includingUnrecognizedFields: knownKeys),
            updatedAt: record.updatedAt
        )
    }

    private func portableLocalUpdatedAt(_ id: SyncRecordID) async throws -> Date? {
        var dates: [Date] = []
        if let stored = try storedPortableRecord(id) { dates.append(stored.updatedAt) }
        switch id.type {
        case SyncedSession.recordType:
            if let session = try await repositorySession(id: id.id) { dates.append(session.updatedAt) }
        case SyncedMessage.recordType:
            if let message = try repositoryMessage(id: id.id) { dates.append(message.createdAt) }
        default:
            break
        }
        return dates.max()
    }

    private func markPortableDirtyRow(_ dirty: PortableDirtyRecord) throws {
        try execute(
            "INSERT INTO desktop_sync_dirty (record_name, record_type, object_id, operation, priority, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
                + "ON CONFLICT(record_name) DO UPDATE SET operation = excluded.operation, priority = excluded.priority, updated_at = excluded.updated_at "
                + "WHERE excluded.updated_at >= desktop_sync_dirty.updated_at",
            bindings: [dirty.id.description, dirty.id.type, dirty.id.id, dirty.operation.rawValue, dirty.priority, dirty.updatedAt.timeIntervalSince1970]
        )
    }

    private func clearPortableDirtyRows(_ ids: [SyncRecordID]) throws {
        for id in ids { try execute("DELETE FROM desktop_sync_dirty WHERE record_name = ?", bindings: [id.description]) }
    }

    private func recordPortableTombstone(_ id: SyncRecordID, deletedAt: Date) throws {
        try execute(
            "INSERT INTO desktop_sync_tombstones (record_name, deleted_at) VALUES (?, ?) "
                + "ON CONFLICT(record_name) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)",
            bindings: [id.description, deletedAt.timeIntervalSince1970]
        )
    }

    private func portableTombstoneDate(_ id: SyncRecordID) throws -> Date? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT deleted_at FROM desktop_sync_tombstones WHERE record_name = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        try bind([id.description], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    private func deletePortableTombstone(_ id: SyncRecordID) throws {
        try execute("DELETE FROM desktop_sync_tombstones WHERE record_name = ?", bindings: [id.description])
    }

    private static func runtimeConversation(from session: ChatSession) -> RuntimeConversation {
        let kind: RuntimeConversationKind
        if session.spawnRole == "group" { kind = .group }
        else if session.agentId != nil { kind = .agent }
        else { kind = .conversation }
        return RuntimeConversation(
            id: session.id,
            title: session.title ?? "Untitled",
            kind: kind,
            agentID: session.agentId,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt
        )
    }

    private static func chatSession(from conversation: RuntimeConversation) -> ChatSession {
        ChatSession(
            id: conversation.id,
            title: conversation.title,
            modelId: "desktop-default",
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            agentId: conversation.agentID,
            spawnRole: conversation.kind == .group ? "group" : nil
        )
    }

    private static func mergedChatSession(_ stored: ChatSession?, with conversation: RuntimeConversation) -> ChatSession {
        guard var stored else { return chatSession(from: conversation) }
        if conversation.updatedAt > stored.updatedAt {
            stored.title = conversation.title
            stored.updatedAt = conversation.updatedAt
            stored.agentId = conversation.agentID ?? stored.agentId
            if conversation.kind == .group { stored.spawnRole = "group" }
        }
        return stored
    }

    private static func runtimeMessage(from message: RawMessage) -> RuntimeMessageRecord {
        let textParts = message.parts.compactMap { part -> String? in
            switch part {
            case .text(let text): return text
            case .toolUse(let tool): return "[Tool call: \(tool.name)]"
            case .toolResult(let result): return result.output
            case .mediaRef(let media): return "[Attachment: \(media.originalFileName ?? media.relativePath)]"
            }
        }
        return RuntimeMessageRecord(
            id: message.id,
            sessionID: message.sessionId,
            role: message.role == .user ? .user : .assistant,
            text: textParts.joined(separator: "\n"),
            senderAgentID: message.senderAgentId,
            createdAt: message.createdAt
        )
    }

    private static func rawMessage(from message: RuntimeMessageRecord) -> RawMessage {
        RawMessage(
            id: message.id,
            sessionId: message.sessionID,
            role: message.role == .assistant ? .assistant : .user,
            parts: [.text(message.text)],
            createdAt: message.createdAt,
            senderAgentId: message.senderAgentID
        )
    }

    private func importIfNewer<T: Encodable>(_ value: T, id: String, table: String, updatedAt: Date) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT updated_at FROM \(table) WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        try bind([id], to: statement)
        if sqlite3_step(statement) == SQLITE_ROW,
           sqlite3_column_double(statement, 0) >= updatedAt.timeIntervalSince1970 {
            return false
        }
        try upsert(value, id: id, table: table, updatedAt: updatedAt)
        return true
    }

    private func insertLegacyMessageIfMissing(_ value: LegacyChatStoreImport.Message) throws -> Bool {
        let data = try JSONEncoder.runtime.encode(value.record)
        try execute(
            "INSERT OR IGNORE INTO desktop_messages (id, session_id, sequence, record_json, created_at) VALUES (?, ?, ?, ?, ?)",
            bindings: [value.record.id, value.record.sessionID, value.sequence, data, value.record.createdAt.timeIntervalSince1970]
        )
        return sqlite3_changes(db) == 1
    }

    private func delete(id: String, table: String) throws {
        try execute("DELETE FROM \(table) WHERE id = ?", bindings: [id])
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func scalarInt(_ sql: String, bindings: [Any]) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func query(_ sql: String, bindings: [Any] = []) throws -> [Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            if let bytes = sqlite3_column_blob(statement, 0) { result.append(Data(bytes: bytes, count: count)) }
        }
        return result
    }

    private func queryChatMessages(_ sql: String, bindings: [Any]) throws -> [(Data, Data?)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [(Data, Data?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let runtimeCount = Int(sqlite3_column_bytes(statement, 0))
            guard let runtimeBytes = sqlite3_column_blob(statement, 0) else { continue }
            let runtimeData = Data(bytes: runtimeBytes, count: runtimeCount)
            let chatData: Data?
            if sqlite3_column_type(statement, 1) == SQLITE_NULL {
                chatData = nil
            } else {
                let chatCount = Int(sqlite3_column_bytes(statement, 1))
                chatData = sqlite3_column_blob(statement, 1).map { Data(bytes: $0, count: chatCount) }
            }
            result.append((runtimeData, chatData))
        }
        return result
    }

    private static func addColumnIfMissing(_ db: OpaquePointer?, table: String, column: String, definition: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            throw DesktopStoreError.sqlite("Unable to inspect \(table) schema.")
        }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                exists = true
                break
            }
        }
        sqlite3_finalize(statement)
        guard !exists else { return }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)", nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unable to migrate \(table).\(column)."
            sqlite3_free(error)
            throw DesktopStoreError.sqlite(message)
        }
    }

    private func execute(_ sql: String, bindings: [Any] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func bind(_ values: [Any], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case let value as String:
                status = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                status = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case let value as Double:
                status = sqlite3_bind_double(statement, index, value)
            case let value as Data:
                status = value.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT) }
            default:
                status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw lastError() }
        }
    }

    private func lastError() -> DesktopStoreError {
        DesktopStoreError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
