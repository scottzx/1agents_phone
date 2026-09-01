import Foundation

// MARK: - Shared persistence value domain

/// A persisted conversation independent of SQLite, CloudKit and presentation.
/// Coding keys intentionally match the historical iOS `ChatSession` payload.
public struct ChatSession: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String?
    public var category: String?
    public let modelId: String
    public let createdAt: Date
    public var updatedAt: Date
    public var lastMessage: String?
    public var source: String?
    public var lastSyncedAt: Date?
    public var remoteDeviceId: String?
    public var remoteDeviceName: String?
    public var pinnedAt: Date?
    public var folderId: String?   // non-nil if filed into a folder; NULL = ungrouped
    public var agentId: String?
    public var parentSessionId: String?
    public var spawnRole: String?
    public var spawnTitle: String?
    public var spawnStatus: String?
    public var spawnResult: String?

    public init(
        id: String,
        title: String? = nil,
        category: String? = nil,
        modelId: String,
        createdAt: Date,
        updatedAt: Date,
        lastMessage: String? = nil,
        source: String? = nil,
        lastSyncedAt: Date? = nil,
        remoteDeviceId: String? = nil,
        remoteDeviceName: String? = nil,
        pinnedAt: Date? = nil,
        agentId: String? = nil,
        parentSessionId: String? = nil,
        spawnRole: String? = nil,
        spawnTitle: String? = nil,
        spawnStatus: String? = nil,
        spawnResult: String? = nil,
        folderId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.modelId = modelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessage = lastMessage
        self.source = source
        self.lastSyncedAt = lastSyncedAt
        self.remoteDeviceId = remoteDeviceId
        self.remoteDeviceName = remoteDeviceName
        self.pinnedAt = pinnedAt
        self.agentId = agentId
        self.parentSessionId = parentSessionId
        self.spawnRole = spawnRole
        self.spawnTitle = spawnTitle
        self.spawnStatus = spawnStatus
        self.spawnResult = spawnResult
        self.folderId = folderId
    }

    public var isSubagent: Bool { spawnRole == "subagent" }
    public var isRemote: Bool { remoteDeviceId != nil }
    public var isPinned: Bool { pinnedAt != nil }
    /// Whether this session belongs to a folder.
    public var isFiled: Bool { folderId != nil }

    public static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        lhs.id == rhs.id
            && lhs.updatedAt == rhs.updatedAt
            && lhs.pinnedAt == rhs.pinnedAt
            // `folderId` MUST be compared: moving a session between folders
            // changes neither `updatedAt` nor any other compared field, so
            // without this the sidebar would keep rendering the row in its old
            // section until some unrelated mutation bumped the diff.
            && lhs.folderId == rhs.folderId
            && lhs.title == rhs.title
            && lhs.category == rhs.category
            && lhs.source == rhs.source
            && lhs.lastSyncedAt == rhs.lastSyncedAt
            && lhs.remoteDeviceId == rhs.remoteDeviceId
            && lhs.remoteDeviceName == rhs.remoteDeviceName
            && lhs.spawnStatus == rhs.spawnStatus
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(updatedAt)
    }
}

/// A user-created folder that groups sessions on the home list.
///
/// Named "Folder" rather than "Group" on purpose: the codebase already has
/// three other "group"s — `ModelGroup` (the LLM provider fallback group behind
/// the home FAB's "New Chat with Group"), the `__grp__` draft-session id
/// encoding (which embeds a ModelGroup id), and SwiftUI's `Group {}`.
///
/// Identity is a locally generated UUID, and `name` deliberately carries no
/// uniqueness constraint:
///
/// - **Why not key on the name.** Renaming would stop being a single-field
///   edit and become an identity change (delete old key, create new key,
///   migrate every member). That multi-row operation tears across devices: if
///   device A renames while device B files sessions under the old name, B's
///   sessions end up referencing a key that no longer exists and silently fall
///   back to ungrouped. With a UUID, a rename is one LWW field on `FolderV2`
///   and members are untouched.
/// - **Why duplicate names are allowed.** Two devices each creating "Work"
///   offline produce two distinct UUIDs, and both are kept. Auto-merging is
///   irreversible and two same-named folders are not necessarily the same
///   thing; the user can always move sessions across and dissolve the leftover.
///   Consequence: any *name-based* lookup must tolerate multiple matches (see
///   `findFolderByName`).
public struct ChatFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var icon: String?         // SF Symbol name; nil = use the composed icon
    public var color: String?        // theme color token
    public var origin: String        // "manual" | "ai" — provenance only, no behavior
    public var sortIndex: Int        // reserved for V2 drag-reorder
    public var pinnedAt: Date?       // non-nil = folder pinned above unpinned folders
    /// One-sentence description (≤100 chars). Auto-grouping context; never
    /// rendered in the home list, but shown as the Move-to-Group picker row
    /// subtitle and surfaced for editing in the rename dialog.
    public var desc: String?
    public let createdAt: Date
    public var updatedAt: Date

    public var isPinned: Bool { pinnedAt != nil }

    public init(
        id: String = UUID().uuidString,
        name: String,
        icon: String? = nil,
        color: String? = nil,
        origin: String = "manual",
        sortIndex: Int = 0,
        pinnedAt: Date? = nil,
        desc: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.origin = origin
        self.sortIndex = sortIndex
        self.pinnedAt = pinnedAt
        self.desc = desc
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
}

public struct MediaRef: Codable, Hashable, Sendable {
    public let id: String
    public let relativePath: String
    public let mimeType: String
    public let originalFileName: String?
    public let linuxPath: String?

    public init(id: String, relativePath: String, mimeType: String, originalFileName: String?, linuxPath: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.originalFileName = originalFileName
        self.linuxPath = linuxPath
    }
}

public struct ToolUse: Codable, Hashable, Sendable {
    public let toolUseId: String
    public let name: String
    public let input: String
    public let description: String?
    public let thoughtSignature: String?

    public init(toolUseId: String, name: String, input: String, description: String? = nil, thoughtSignature: String? = nil) {
        self.toolUseId = toolUseId
        self.name = name
        self.input = input
        self.description = description
        self.thoughtSignature = thoughtSignature
    }
}

public struct ToolSnapshot: Codable, Hashable, Sendable {
    public enum SnapshotType: String, Codable, Hashable, Sendable { case text, image }
    public let type: SnapshotType
    public let text: String?
    public let mediaRef: MediaRef?
    public let duration: TimeInterval?

    public init(type: SnapshotType, text: String? = nil, mediaRef: MediaRef? = nil, duration: TimeInterval? = nil) {
        self.type = type
        self.text = text
        self.mediaRef = mediaRef
        self.duration = duration
    }
}

public struct ToolResult: Codable, Hashable, Sendable {
    public let toolUseId: String
    public let output: String
    public let success: Bool
    public let mediaRef: MediaRef?
    public let snapshot: ToolSnapshot?
    public let pageURL: String?
    public let status: String?

    public init(toolUseId: String, output: String, success: Bool, mediaRef: MediaRef? = nil, snapshot: ToolSnapshot? = nil, pageURL: String? = nil, status: String? = nil) {
        self.toolUseId = toolUseId
        self.output = output
        self.success = success
        self.mediaRef = mediaRef
        self.snapshot = snapshot
        self.pageURL = pageURL
        self.status = status
    }

    public static func truncateURL(_ url: String, maxLength: Int = 512) -> String {
        guard url.count > maxLength else { return url }
        let marker = "…[truncated]…"
        let keep = (maxLength - marker.count) / 2
        return String(url.prefix(keep)) + marker + String(url.suffix(keep))
    }
}

public enum ContentPart: Codable, Hashable, Sendable {
    case text(String)
    case mediaRef(MediaRef)
    case toolUse(ToolUse)
    case toolResult(ToolResult)

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum PartType: String, Codable { case text, mediaRef, toolUse, toolResult }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(PartType.text, forKey: .type)
            try container.encode(value, forKey: .value)
        case .mediaRef(let value):
            try container.encode(PartType.mediaRef, forKey: .type)
            try container.encode(value, forKey: .value)
        case .toolUse(let value):
            try container.encode(PartType.toolUse, forKey: .type)
            try container.encode(value, forKey: .value)
        case .toolResult(let value):
            try container.encode(PartType.toolResult, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PartType.self, forKey: .type) {
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .mediaRef: self = .mediaRef(try container.decode(MediaRef.self, forKey: .value))
        case .toolUse: self = .toolUse(try container.decode(ToolUse.self, forKey: .value))
        case .toolResult: self = .toolResult(try container.decode(ToolResult.self, forKey: .value))
        }
    }
}

public struct CompactMarker: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sessionId: String
    public let summary: String
    public let firstKeptSortOrder: Int
    public let compactedCount: Int
    public let createdAt: Date
    public let uiBoundarySortOrder: Int?
    public let boundaryMessageId: String?
    public let firstKeptMessageId: String?
    public let lastCompactedMessageId: String?
    public var version: Int

    public init(id: String, sessionId: String, summary: String, firstKeptSortOrder: Int, compactedCount: Int, createdAt: Date, uiBoundarySortOrder: Int? = nil, boundaryMessageId: String? = nil, firstKeptMessageId: String? = nil, lastCompactedMessageId: String? = nil, version: Int = 1) {
        self.id = id
        self.sessionId = sessionId
        self.summary = summary
        self.firstKeptSortOrder = firstKeptSortOrder
        self.compactedCount = compactedCount
        self.createdAt = createdAt
        self.uiBoundarySortOrder = uiBoundarySortOrder
        self.boundaryMessageId = boundaryMessageId
        self.firstKeptMessageId = firstKeptMessageId
        self.lastCompactedMessageId = lastCompactedMessageId
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, summary, firstKeptSortOrder, compactedCount, createdAt
        case uiBoundarySortOrder, boundaryMessageId, firstKeptMessageId, lastCompactedMessageId, version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        summary = try container.decode(String.self, forKey: .summary)
        firstKeptSortOrder = try container.decodeIfPresent(Int.self, forKey: .firstKeptSortOrder) ?? 0
        compactedCount = try container.decodeIfPresent(Int.self, forKey: .compactedCount) ?? 0
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        uiBoundarySortOrder = try container.decodeIfPresent(Int.self, forKey: .uiBoundarySortOrder)
        boundaryMessageId = try container.decodeIfPresent(String.self, forKey: .boundaryMessageId)
        firstKeptMessageId = try container.decodeIfPresent(String.self, forKey: .firstKeptMessageId)
        lastCompactedMessageId = try container.decodeIfPresent(String.self, forKey: .lastCompactedMessageId)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
}

public struct StoredTokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var latestContextTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int, latestContextTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.latestContextTokens = latestContextTokens
    }
}

public struct RawMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sessionId: String
    public let role: MessageRole
    public let parts: [ContentPart]
    public let createdAt: Date
    public var tokenUsage: StoredTokenUsage?
    public var reasoningContent: String?
    public var streamInterruptCount: Int
    public var sortOrder: Int
    public var errorInfo: String?
    public var senderAgentId: String?

    public init(id: String, sessionId: String, role: MessageRole, parts: [ContentPart], createdAt: Date, tokenUsage: StoredTokenUsage? = nil, reasoningContent: String? = nil, streamInterruptCount: Int = 0, sortOrder: Int = 0, errorInfo: String? = nil, senderAgentId: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.parts = parts
        self.createdAt = createdAt
        self.tokenUsage = tokenUsage
        self.reasoningContent = reasoningContent
        self.streamInterruptCount = streamInterruptCount
        self.sortOrder = sortOrder
        self.errorInfo = errorInfo
        self.senderAgentId = senderAgentId
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, role, parts, createdAt, tokenUsage, reasoningContent
        case streamInterruptCount, sortOrder, errorInfo, senderAgentId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        role = try container.decode(MessageRole.self, forKey: .role)
        parts = try container.decode([ContentPart].self, forKey: .parts)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        tokenUsage = try container.decodeIfPresent(StoredTokenUsage.self, forKey: .tokenUsage)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        streamInterruptCount = try container.decodeIfPresent(Int.self, forKey: .streamInterruptCount) ?? 0
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        errorInfo = try container.decodeIfPresent(String.self, forKey: .errorInfo)
        senderAgentId = try container.decodeIfPresent(String.self, forKey: .senderAgentId)
    }

    public var isToolResultOnly: Bool {
        role == .user && !parts.isEmpty && parts.allSatisfy {
            if case .toolResult = $0 { return true }
            return false
        }
    }

    public static let internalBridgeText =
        "(Interrupted mid-task by a new user message. Decide based on the new message and overall context whether the prior task should continue — do not forget or abandon it unless the user explicitly says to stop, or the new message makes clear it is no longer needed.)"
    public static let internalBridgeTexts = [
        internalBridgeText,
        "(Interrupted mid-task to handle your new message. Will return to the prior task after.)"
    ]

    public static func isInternalBridgeText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return internalBridgeTexts.contains(trimmed)
    }

    public var isInternalBridge: Bool {
        guard role == .assistant, parts.count == 1, case .text(let value) = parts[0] else { return false }
        return Self.isInternalBridgeText(value)
    }

    public var isAsyncTaskNotice: Bool {
        guard role == .assistant, !parts.isEmpty else { return false }
        return parts.allSatisfy {
            if case .toolUse(let tu) = $0 {
                return tu.name == ChatPersistenceSchema.asyncTaskNoticeToolName
            }
            return false
        }
    }
}

/// A pending or delivered asynchronous background task completion notice.
public struct AsyncTaskNotice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sourceSessionId: String
    public let taskType: String       // "shell" | "subagent" | "a2a" | "group"
    public let taskId: String
    public let title: String?
    public let status: String         // "done" | "failed" | "stopped"
    public let result: String
    public let filesPath: String?
    public let createdAt: Date
    public var isDelivered: Bool
    public var deliveredAt: Date?

    public init(
        id: String,
        sourceSessionId: String,
        taskType: String,
        taskId: String,
        title: String? = nil,
        status: String = "done",
        result: String,
        filesPath: String? = nil,
        createdAt: Date = Date(),
        isDelivered: Bool = false,
        deliveredAt: Date? = nil
    ) {
        self.id = id
        self.sourceSessionId = sourceSessionId
        self.taskType = taskType
        self.taskId = taskId
        self.title = title
        self.status = status
        self.result = result
        self.filesPath = filesPath
        self.createdAt = createdAt
        self.isDelivered = isDelivered
        self.deliveredAt = deliveredAt
    }
}

// MARK: - Shared schema contract

/// The stable base of the historical iOS SQLite schema. Platform stores may
/// add indexes and columns, but these names and wire formats cannot be renamed.
public enum ChatPersistenceSchema {
    public static let asyncTaskNoticeToolName = "async_task_notice"
    public static let sessionsTable = "sessions"
    public static let messagesTable = "messages"
    public static let asyncTaskNoticesTable = "async_task_notices"

    public static let createSessionsSQL = """
        CREATE TABLE IF NOT EXISTS sessions (
            id          TEXT PRIMARY KEY,
            title       TEXT,
            model_id    TEXT NOT NULL,
            created_at  REAL NOT NULL,
            updated_at  REAL NOT NULL
        )
        """

    public static let createMessagesSQL = """
        CREATE TABLE IF NOT EXISTS messages (
            id          TEXT PRIMARY KEY,
            session_id  TEXT NOT NULL REFERENCES sessions(id),
            role        TEXT NOT NULL,
            parts_json  TEXT NOT NULL,
            created_at  REAL NOT NULL,
            token_usage TEXT,
            sort_order  INTEGER NOT NULL
        )
        """

    public static let createMessageIndexSQL =
        "CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, sort_order)"

    public static let createAsyncTaskNoticesSQL = """
        CREATE TABLE IF NOT EXISTS async_task_notices (
            id                TEXT PRIMARY KEY,
            source_session_id TEXT NOT NULL,
            task_type         TEXT NOT NULL,
            task_id           TEXT NOT NULL,
            title             TEXT,
            status            TEXT NOT NULL,
            result            TEXT NOT NULL,
            files_path        TEXT,
            created_at        REAL NOT NULL,
            is_delivered      INTEGER NOT NULL DEFAULT 0,
            delivered_at      REAL
        )
        """

    public static let createAsyncTaskNoticesIndexSQL =
        "CREATE INDEX IF NOT EXISTS idx_async_notices_session ON async_task_notices(source_session_id, is_delivered)"
}

// MARK: - Repository contract

public enum ChatRepositoryError: Error, LocalizedError, Sendable {
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .persistence(let message): return message
        }
    }
}

public protocol ChatRepository: Sendable {
    /// User-visible top-level sessions. Scratch subagent and group-member
    /// sessions remain addressable through `repositorySession(id:)`.
    func repositorySessions() async throws -> [ChatSession]
    func repositorySession(id: String) async throws -> ChatSession?
    func repositorySaveSession(_ session: ChatSession) async throws
    func repositoryDeleteSession(id: String) async throws
    func repositoryMessages(sessionId: String) async throws -> [RawMessage]
    func repositoryAppendMessages(_ messages: [RawMessage]) async throws
}
