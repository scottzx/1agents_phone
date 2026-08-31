import Foundation

/// Everything needed to create a headless-capable session without exposing a
/// platform ViewModel. Platform adapters translate these strings into their
/// native persistence and model-binding representations.
public struct AgentSessionCreateRequest: Sendable, Equatable {
    public let title: String?
    public let agentId: String?
    public let groupId: String?
    public let parentSessionId: String?
    public let source: String
    public let role: String
    public let spawnTitle: String?
    public let toolPolicy: String?
    public let defaultModelEntryId: String?
    public let inheritModelFromSessionId: String?
    public let groupMemberIds: [String]

    public init(
        title: String? = nil,
        agentId: String? = nil,
        groupId: String? = nil,
        parentSessionId: String? = nil,
        source: String = "runtime",
        role: String = "main",
        spawnTitle: String? = nil,
        toolPolicy: String? = nil,
        defaultModelEntryId: String? = nil,
        inheritModelFromSessionId: String? = nil,
        groupMemberIds: [String] = []
    ) {
        self.title = title
        self.agentId = agentId
        self.groupId = groupId
        self.parentSessionId = parentSessionId
        self.source = source
        self.role = role
        self.spawnTitle = spawnTitle
        self.toolPolicy = toolPolicy
        self.defaultModelEntryId = defaultModelEntryId
        self.inheritModelFromSessionId = inheritModelFromSessionId
        self.groupMemberIds = groupMemberIds
    }
}

/// Platform-neutral contract used by AgentKit orchestration. UI layers and
/// group rules no longer need to know whether a session is backed by the iOS
/// in-process engine or the macOS Runtime service.
public struct AgentSessionRunRequest: Sendable, Equatable {
    public let sessionId: String
    public let prompt: String
    public let agentId: String?
    public let groupId: String?
    public let source: String
    public let systemPromptBlock: String?
    public let thinkingLevel: String?
    public let role: String
    public let toolPolicy: String?
    public let timeoutSeconds: TimeInterval

    public init(
        sessionId: String,
        prompt: String,
        agentId: String? = nil,
        groupId: String? = nil,
        source: String = "runtime",
        systemPromptBlock: String? = nil,
        thinkingLevel: String? = nil,
        role: String = "main",
        toolPolicy: String? = nil,
        timeoutSeconds: TimeInterval = 120
    ) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.agentId = agentId
        self.groupId = groupId
        self.source = source
        self.systemPromptBlock = systemPromptBlock
        self.thinkingLevel = thinkingLevel
        self.role = role
        self.toolPolicy = toolPolicy
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct AgentSessionRunResult: Sendable, Equatable {
    public let text: String?
    public let accepted: Bool
    public let timedOut: Bool
    public let cancelled: Bool

    public init(text: String?, accepted: Bool, timedOut: Bool, cancelled: Bool) {
        self.text = text
        self.accepted = accepted
        self.timedOut = timedOut
        self.cancelled = cancelled
    }

    public static let rejected = AgentSessionRunResult(text: nil, accepted: false, timedOut: false, cancelled: false)
}

public struct AgentSessionStatus: Sendable, Equatable {
    public let isRunning: Bool
    public let lastAssistantText: String?
    public let currentActivity: String
    public let iteration: Int

    public init(isRunning: Bool, lastAssistantText: String? = nil, currentActivity: String = "", iteration: Int = 0) {
        self.isRunning = isRunning
        self.lastAssistantText = lastAssistantText
        self.currentActivity = currentActivity
        self.iteration = iteration
    }
}

@MainActor
public protocol AgentSessionRunning: AnyObject {
    func createSession(_ request: AgentSessionCreateRequest) async -> String?
    func run(_ request: AgentSessionRunRequest) async -> AgentSessionRunResult
    func status(sessionId: String) async -> AgentSessionStatus
    func isRunning(sessionId: String) async -> Bool
    func cancel(sessionId: String)
}
