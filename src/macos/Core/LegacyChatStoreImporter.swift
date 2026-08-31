import Foundation
import SQLite3

/// A complete, immutable snapshot decoded from an iOS `ChatStore` database.
/// It intentionally contains only the data the first desktop runtime can
/// render today; attachment bytes, tool payloads and provider credentials stay
/// in their original platform storage.
public struct LegacyChatStoreImport: Sendable {
    public struct Message: Sendable {
        public let record: RuntimeMessageRecord
        public let sequence: Int

        public init(record: RuntimeMessageRecord, sequence: Int) {
            self.record = record
            self.sequence = sequence
        }
    }

    public let conversations: [RuntimeConversation]
    public let agents: [RuntimeAgentRecord]
    public let groups: [RuntimeGroupRecord]
    public let messages: [Message]

    public init(
        conversations: [RuntimeConversation],
        agents: [RuntimeAgentRecord],
        groups: [RuntimeGroupRecord],
        messages: [Message]
    ) {
        self.conversations = conversations
        self.agents = agents
        self.groups = groups
        self.messages = messages
    }
}

public struct LegacyChatStoreImportResult: Codable, Sendable, Equatable {
    public let conversations: Int
    public let agents: Int
    public let groups: Int
    public let messages: Int

    public init(conversations: Int, agents: Int, groups: Int, messages: Int) {
        self.conversations = conversations
        self.agents = agents
        self.groups = groups
        self.messages = messages
    }
}

public enum LegacyChatStoreImportError: LocalizedError, Sendable {
    case sourceMissing(URL)
    case open(String)
    case sqlite(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let url): "The selected ChatStore database does not exist: \(url.path)"
        case .open(let message): "Unable to open the iOS ChatStore database: \(message)"
        case .sqlite(let message): "Unable to read the iOS ChatStore database: \(message)"
        case .unsupported(let message): "Unsupported iOS ChatStore database: \(message)"
        }
    }
}

/// Imports the stable, persisted iOS ChatStore rows into the versioned desktop
/// store. The source is opened `READONLY`, queried inside a read transaction,
/// fully decoded in memory, and only then submitted to DesktopStore's one
/// write transaction. Re-running the importer is safe: desktop records with a
/// newer timestamp win and messages retain their iOS UUIDs.
public struct LegacyChatStoreImporter {
    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func importInto(_ destination: DesktopStore) async throws -> LegacyChatStoreImportResult {
        let snapshot = try readSnapshot()
        return try await destination.importLegacy(snapshot)
    }

    public func readSnapshot() throws -> LegacyChatStoreImport {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw LegacyChatStoreImportError.sourceMissing(databaseURL)
        }
        let reader = try LegacyDatabaseReader(url: databaseURL)
        defer { reader.close() }
        return try reader.snapshot()
    }
}

private struct LegacySession {
    let id: String
    let title: String
    let agentID: String?
    let parentSessionID: String?
    let spawnRole: String?
    let createdAt: Date
    let updatedAt: Date
}

private struct LegacyGroup {
    let id: String
    let sessionID: String
    let title: String
    let emoji: String
    let members: [String]
    let ownerAgentID: String?
    let mode: String
    let archived: Bool
    let updatedAt: Date
}

private struct LegacyMessageRow {
    let id: String
    let sessionID: String
    let role: RuntimeMessageRole
    let text: String
    let senderAgentID: String?
    let createdAt: Date
    let sequence: Int
}

private final class LegacyDatabaseReader {
    private var db: OpaquePointer?

    init(url: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(result))
            if let handle { sqlite3_close(handle) }
            throw LegacyChatStoreImportError.open(message)
        }
        db = handle
        try execute("PRAGMA query_only=ON")
    }

    deinit { close() }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    func snapshot() throws -> LegacyChatStoreImport {
        guard tableExists("sessions"), tableExists("messages") else {
            throw LegacyChatStoreImportError.unsupported("missing required sessions or messages table")
        }

        try execute("BEGIN")
        do {
            let agents = try readAgents()
            let groups = try readGroups()
            let sessions = try readSessions()
            let messages = try readMessages()
            try execute("COMMIT")
            return makeImport(sessions: sessions, agents: agents, groups: groups, messages: messages)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func makeImport(
        sessions: [LegacySession],
        agents: [RuntimeAgentRecord],
        groups: [LegacyGroup],
        messages: [LegacyMessageRow]
    ) -> LegacyChatStoreImport {
        let groupIDBySession = Dictionary(uniqueKeysWithValues: groups.map { ($0.sessionID, $0.id) })
        var importedGroups = groups.map {
            RuntimeGroupRecord(
                id: $0.id,
                sessionID: $0.sessionID,
                title: $0.title,
                emoji: $0.emoji,
                memberIDs: $0.members,
                ownerAgentID: $0.ownerAgentID,
                mode: $0.mode,
                archived: $0.archived,
                updatedAt: $0.updatedAt
            )
        }
        let groupIndexes = Dictionary(uniqueKeysWithValues: importedGroups.enumerated().map { ($0.element.id, $0.offset) })

        var conversations: [RuntimeConversation] = []
        var knownSessionIDs = Set<String>()
        for session in sessions {
            knownSessionIDs.insert(session.id)
            let directGroupID = groupIDBySession[session.id]
            let parentGroupID = session.parentSessionID.flatMap { groupIDBySession[$0] }
            let kind: RuntimeConversationKind = directGroupID == nil && session.agentID == nil ? .conversation : (directGroupID == nil ? .agent : .group)
            conversations.append(RuntimeConversation(
                id: session.id,
                title: session.title,
                kind: kind,
                agentID: directGroupID == nil ? session.agentID : nil,
                groupID: directGroupID ?? parentGroupID,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
            ))

            if session.spawnRole == "group-member",
               let groupID = parentGroupID,
               let agentID = session.agentID,
               let index = groupIndexes[groupID] {
                importedGroups[index].memberSessionIDs[agentID] = session.id
            }
        }

        // A damaged/partial iOS database may have group metadata but no
        // transcript row. Keep the relationship visible instead of silently
        // discarding the group during import.
        for group in importedGroups where !knownSessionIDs.contains(group.sessionID) {
            conversations.append(RuntimeConversation(
                id: group.sessionID,
                title: group.title,
                kind: .group,
                groupID: group.id,
                createdAt: group.updatedAt,
                updatedAt: group.updatedAt
            ))
        }

        let importedMessages = messages.map {
            LegacyChatStoreImport.Message(
                record: RuntimeMessageRecord(
                    id: $0.id,
                    sessionID: $0.sessionID,
                    role: $0.role,
                    text: $0.text,
                    senderAgentID: $0.senderAgentID,
                    createdAt: $0.createdAt
                ),
                sequence: $0.sequence
            )
        }
        return LegacyChatStoreImport(
            conversations: conversations,
            agents: agents,
            groups: importedGroups,
            messages: importedMessages
        )
    }

    private func readSessions() throws -> [LegacySession] {
        let columns = columns(in: "sessions")
        let sql = """
        SELECT id, \(column("title", in: columns, fallback: "''")),
               \(column("agent_id", in: columns)), \(column("parent_session_id", in: columns)),
               \(column("spawn_role", in: columns)),
               \(column("created_at", in: columns, fallback: "0")),
               \(column("updated_at", in: columns, fallback: "0"))
        FROM sessions
        """
        return try rows(sql) { statement in
            guard let id = string(statement, 0), !id.isEmpty else { return nil }
            return LegacySession(
                id: id,
                title: string(statement, 1) ?? "Untitled conversation",
                agentID: string(statement, 2),
                parentSessionID: string(statement, 3),
                spawnRole: string(statement, 4),
                createdAt: date(statement, 5),
                updatedAt: date(statement, 6)
            )
        }
    }

    private func readAgents() throws -> [RuntimeAgentRecord] {
        guard tableExists("agents") else { return [] }
        let columns = columns(in: "agents")
        let sql = """
        SELECT id, \(column("name", in: columns, fallback: "'Agent'")),
               \(column("emoji", in: columns, fallback: "'🤖'")), \(column("title", in: columns, fallback: "''")),
               \(column("summary", in: columns, fallback: "''")), \(column("accent_color", in: columns, fallback: "'#5B8DEF'")),
               \(column("main_session_id", in: columns)), \(column("default_model_entry", in: columns)),
               \(column("tool_policy", in: columns, fallback: "'orchestrator'")),
               \(column("archived_at", in: columns)), \(column("updated_at", in: columns, fallback: "0"))
        FROM agents
        """
        return try rows(sql) { statement in
            guard let id = string(statement, 0), !id.isEmpty else { return nil }
            return RuntimeAgentRecord(
                id: id,
                name: string(statement, 1) ?? "Agent",
                emoji: string(statement, 2) ?? "🤖",
                title: string(statement, 3) ?? "",
                summary: string(statement, 4) ?? "",
                accentColor: string(statement, 5) ?? "#5B8DEF",
                mainSessionID: string(statement, 6),
                defaultModelID: string(statement, 7),
                toolPolicy: string(statement, 8) ?? "orchestrator",
                archived: !isNull(statement, 9),
                updatedAt: date(statement, 10)
            )
        }
    }

    private func readGroups() throws -> [LegacyGroup] {
        guard tableExists("agent_groups") else { return [] }
        let columns = columns(in: "agent_groups")
        let sql = """
        SELECT id, \(column("session_id", in: columns)), \(column("title", in: columns, fallback: "'Group'")),
               \(column("emoji", in: columns, fallback: "'👥'")), \(column("mode", in: columns, fallback: "'freeform'")),
               \(column("owner_agent_id", in: columns)), \(column("archived_at", in: columns)),
               \(column("updated_at", in: columns, fallback: "0"))
        FROM agent_groups
        """
        return try rows(sql) { statement in
            guard let id = string(statement, 0), let sessionID = string(statement, 1), !id.isEmpty, !sessionID.isEmpty else { return nil }
            return LegacyGroup(
                id: id,
                sessionID: sessionID,
                title: string(statement, 2) ?? "Group",
                emoji: string(statement, 3) ?? "👥",
                members: try memberIDs(groupID: id),
                ownerAgentID: string(statement, 5),
                mode: string(statement, 4) ?? "freeform",
                archived: !isNull(statement, 6),
                updatedAt: date(statement, 7)
            )
        }
    }

    private func memberIDs(groupID: String) throws -> [String] {
        guard tableExists("agent_group_members") else { return [] }
        return try rows("SELECT agent_id FROM agent_group_members WHERE group_id = ? ORDER BY sort_order ASC, joined_at ASC", bindings: [groupID]) { statement in
            string(statement, 0)
        }
    }

    private func readMessages() throws -> [LegacyMessageRow] {
        let columns = columns(in: "messages")
        let sql = """
        SELECT id, session_id, role, \(column("parts_json", in: columns, fallback: "'[]'")),
               \(column("created_at", in: columns, fallback: "0")), \(column("sort_order", in: columns, fallback: "0")),
               \(column("sender_agent_id", in: columns))
        FROM messages
        ORDER BY session_id ASC, \(column("sort_order", in: columns, fallback: "0")) ASC, \(column("created_at", in: columns, fallback: "0")) ASC, id ASC
        """
        return try rows(sql) { statement in
            guard let id = string(statement, 0), let sessionID = string(statement, 1),
                  let rawRole = string(statement, 2), let role = RuntimeMessageRole(rawValue: rawRole) else { return nil }
            return LegacyMessageRow(
                id: id,
                sessionID: sessionID,
                role: role,
                text: extractText(from: string(statement, 3) ?? "[]"),
                senderAgentID: string(statement, 6),
                createdAt: date(statement, 4),
                sequence: Int(sqlite3_column_int64(statement, 5))
            )
        }
    }

    private func tableExists(_ name: String) -> Bool {
        (try? rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", bindings: [name]) { _ in true }.first) ?? false
    }

    private func columns(in table: String) -> Set<String> {
        Set((try? rows("PRAGMA table_info(\(table))") { statement in string(statement, 1) }.compactMap { $0 }) ?? [])
    }

    private func column(_ name: String, in available: Set<String>, fallback: String = "NULL") -> String {
        available.contains(name) ? name : fallback
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError()
            sqlite3_free(error)
            throw LegacyChatStoreImportError.sqlite(message)
        }
    }

    private func rows<T>(_ sql: String, bindings: [String] = [], transform: (OpaquePointer?) throws -> T?) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LegacyChatStoreImportError.sqlite(lastError())
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, legacySQLiteTransient) == SQLITE_OK else {
                throw LegacyChatStoreImportError.sqlite(lastError())
            }
        }
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw LegacyChatStoreImportError.sqlite(lastError()) }
            if let value = try transform(statement) { result.append(value) }
        }
    }

    private func lastError() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
    }
}

private struct LegacyContentPart: Decodable {
    let type: String
    let value: JSONValue
}

private func extractText(from partsJSON: String) -> String {
    guard let data = partsJSON.data(using: .utf8),
          let parts = try? JSONDecoder.runtime.decode([LegacyContentPart].self, from: data) else {
        return "[Legacy message content unavailable]"
    }
    let text = parts.compactMap { part -> String? in
        switch (part.type, part.value) {
        case ("text", .string(let value)):
            return value
        case ("toolResult", .object(let value)):
            return value["output"].flatMap { if case .string(let output) = $0 { return "[Tool result] \(output)" }; return nil }
        case ("toolUse", .object(let value)):
            return value["name"].flatMap { if case .string(let name) = $0 { return "[Tool: \(name)]" }; return nil }
        case ("mediaRef", _):
            return "[Attachment]"
        default:
            return nil
        }
    }.filter { !$0.isEmpty }
    return text.isEmpty ? "[Legacy non-text message]" : text.joined(separator: "\n\n")
}

private func string(_ statement: OpaquePointer?, _ column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
          let value = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: value)
}

private func date(_ statement: OpaquePointer?, _ column: Int32) -> Date {
    Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
}

private func isNull(_ statement: OpaquePointer?, _ column: Int32) -> Bool {
    sqlite3_column_type(statement, column) == SQLITE_NULL
}

private let legacySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
