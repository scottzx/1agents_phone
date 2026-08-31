import Foundation

public enum RuntimeConversationKind: String, Codable, Sendable, CaseIterable {
    case conversation
    case agent
    case group
}

public struct RuntimeConversation: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public var title: String
    public var kind: RuntimeConversationKind
    public var agentID: String?
    public var groupID: String?
    public var workspaceID: String?
    public var agentShellAccess: Bool?
    /// Stable provider configuration selected for this conversation. A nil
    /// value follows the Runtime-wide default and preserves records written by
    /// the first desktop preview.
    public var providerConfigurationID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, title: String, kind: RuntimeConversationKind = .conversation, agentID: String? = nil, groupID: String? = nil, workspaceID: String? = nil, agentShellAccess: Bool = false, providerConfigurationID: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.kind = kind
        self.agentID = agentID
        self.groupID = groupID
        self.workspaceID = workspaceID
        self.agentShellAccess = agentShellAccess
        self.providerConfigurationID = providerConfigurationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum RuntimeMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct RuntimeMessageRecord: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let sessionID: String
    public let role: RuntimeMessageRole
    public let text: String
    public let senderAgentID: String?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, sessionID: String, role: RuntimeMessageRole, text: String, senderAgentID: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.senderAgentID = senderAgentID
        self.createdAt = createdAt
    }
}

public struct RuntimeAgentRecord: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public var name: String
    public var emoji: String
    public var title: String
    public var summary: String
    public var accentColor: String
    public var mainSessionID: String?
    public var defaultModelID: String?
    public var toolPolicy: String
    public var archived: Bool
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, emoji: String = "🤖", title: String = "", summary: String = "", accentColor: String = "#5B8DEF", mainSessionID: String? = nil, defaultModelID: String? = nil, toolPolicy: String = "standalone", archived: Bool = false, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.title = title
        self.summary = summary
        self.accentColor = accentColor
        self.mainSessionID = mainSessionID
        self.defaultModelID = defaultModelID
        self.toolPolicy = toolPolicy
        self.archived = archived
        self.updatedAt = updatedAt
    }
}

public struct RuntimeGroupRecord: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public var sessionID: String
    public var title: String
    public var emoji: String
    public var memberIDs: [String]
    public var ownerAgentID: String?
    public var memberSessionIDs: [String: String]
    public var mode: String
    public var archived: Bool
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, sessionID: String, title: String, emoji: String = "👥", memberIDs: [String], ownerAgentID: String? = nil, memberSessionIDs: [String: String] = [:], mode: String = "freeform", archived: Bool = false, updatedAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.emoji = emoji
        self.memberIDs = memberIDs
        self.ownerAgentID = ownerAgentID
        self.memberSessionIDs = memberSessionIDs
        self.mode = mode
        self.archived = archived
        self.updatedAt = updatedAt
    }
}

public struct RuntimeSnapshot: Codable, Sendable, Equatable {
    public let conversations: [RuntimeConversation]
    public let agents: [RuntimeAgentRecord]
    public let groups: [RuntimeGroupRecord]
    public let states: [String: RuntimeState]

    public init(conversations: [RuntimeConversation], agents: [RuntimeAgentRecord], groups: [RuntimeGroupRecord], states: [String: RuntimeState]) {
        self.conversations = conversations
        self.agents = agents
        self.groups = groups
        self.states = states
    }
}

public struct RuntimeProviderTestResult: Codable, Sendable, Equatable {
    public let providerID: String
    public let success: Bool
    public let elapsedMilliseconds: Int
    public let error: String?

    public init(providerID: String, success: Bool, elapsedMilliseconds: Int, error: String? = nil) {
        self.providerID = providerID
        self.success = success
        self.elapsedMilliseconds = elapsedMilliseconds
        self.error = error
    }
}

public struct RuntimeAuditRecord: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let sessionID: String?
    public let category: String
    public let action: String
    public let decision: String
    public let detail: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionID: String? = nil,
        category: String,
        action: String,
        decision: String,
        detail: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.category = category
        self.action = action
        self.decision = decision
        self.detail = detail
        self.createdAt = createdAt
    }
}

public struct RuntimeTerminalEventRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case output, exited }
    public let kind: Kind
    public let base64Data: String?
    public let exitCode: Int32?

    public init(kind: Kind, base64Data: String? = nil, exitCode: Int32? = nil) {
        self.kind = kind
        self.base64Data = base64Data
        self.exitCode = exitCode
    }
}

/// Ephemeral UI state for one interactive PTY. This deliberately stays outside
/// persisted conversations: closing the app terminates the attached process
/// instead of attempting to restore a stale terminal on the next launch.
public struct TerminalTabState: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let terminalID: UUID
    public let workspaceID: String
    public let sessionID: String?
    public var title: String
    public var output: String
    public var input: String
    public var isRunning: Bool
    public var columns: Int
    public var rows: Int

    public init(
        id: UUID = UUID(),
        terminalID: UUID,
        workspaceID: String,
        sessionID: String? = nil,
        title: String,
        output: String = "",
        input: String = "",
        isRunning: Bool = true,
        columns: Int = 100,
        rows: Int = 30
    ) {
        self.id = id
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.title = title
        self.output = output
        self.input = input
        self.isRunning = isRunning
        self.columns = columns
        self.rows = rows
    }

    public mutating func appendOutput(_ value: String, limit: Int = 200_000) {
        output.append(value)
        guard output.count > limit else { return }
        output.removeFirst(output.count - limit)
    }

    public mutating func clearOutput() {
        output = ""
    }
}

public extension JSONValue {
    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.runtime.encode(value)
        return try JSONDecoder.runtime.decode(JSONValue.self, from: data)
    }

    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder.runtime.encode(self)
        return try JSONDecoder.runtime.decode(T.self, from: data)
    }
}

public extension JSONEncoder {
    static var runtime: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

public extension JSONDecoder {
    static var runtime: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
