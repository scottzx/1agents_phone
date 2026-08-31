import Foundation

/// A platform-neutral message used while an agent is completing a turn. The
/// adapters own their provider wire formats; this is only the common loop
/// ledger shared by iOS and macOS.
public struct AgentRunMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var content: String?
    public var toolCallID: String?
    public var toolCalls: [AgentRunToolCall]

    public init(
        role: Role,
        content: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [AgentRunToolCall] = []
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}

/// A provider-requested tool invocation. Arguments intentionally remain a JSON
/// string: iOS already receives JSON fragments while streaming and macOS keeps
/// its OpenAI-compatible wire payload in this shape.
public struct AgentRunToolCall: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// The provider-independent tool surface sent on each completion request.
public struct AgentRunToolDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    /// Provider adapters encode this JSON schema in their native request form.
    public let parametersJSON: String

    public init(id: String? = nil, name: String, description: String, parametersJSON: String = "{}") {
        self.id = id ?? name
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct AgentRunProviderTurn: Equatable, Sendable {
    public let text: String?
    public let toolCalls: [AgentRunToolCall]

    public init(text: String?, toolCalls: [AgentRunToolCall] = []) {
        self.text = text
        self.toolCalls = toolCalls
    }
}

/// The request an adapter gives to its own provider implementation. It is
/// deliberately independent from endpoint, credentials, streaming UI and
/// persistence, which stay platform/provider concerns.
public struct AgentRunProviderRequest: Sendable {
    public let messages: [AgentRunMessage]
    public let systemPrompt: String?
    public let tools: [AgentRunToolDefinition]
    public let round: Int

    public init(messages: [AgentRunMessage], systemPrompt: String?, tools: [AgentRunToolDefinition], round: Int) {
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.round = round
    }
}

public struct AgentRunConfiguration: Sendable, Equatable {
    /// A tool round is one provider response containing one or more calls.
    public let maximumToolRounds: Int

    public init(maximumToolRounds: Int = 8) {
        self.maximumToolRounds = max(1, maximumToolRounds)
    }
}

public struct AgentRunResult: Sendable, Equatable {
    public let text: String
    public let messages: [AgentRunMessage]
    public let toolRounds: Int

    public init(text: String, messages: [AgentRunMessage], toolRounds: Int) {
        self.text = text
        self.messages = messages
        self.toolRounds = toolRounds
    }
}

public enum AgentRunEvent: Equatable, Sendable {
    case started
    case providerRequested(round: Int)
    case providerResponded(round: Int, toolCallCount: Int)
    case toolStarted(AgentRunToolCall)
    case toolOutput(callID: String, toolName: String, output: String)
    case toolFailed(callID: String, toolName: String, message: String)
    case completed(text: String, toolRounds: Int)
    case cancelled
    case failed(message: String)
}

public enum AgentRunEngineError: LocalizedError, Equatable, Sendable {
    case toolUnavailable(String)
    case toolRoundLimitExceeded(Int)

    public var errorDescription: String? {
        switch self {
        case .toolUnavailable(let name): "Tool is unavailable: \(name)"
        case .toolRoundLimitExceeded(let maximum): "The Agent exceeded the maximum of \(maximum) tool rounds."
        }
    }
}

/// Executes the provider → tool → provider loop without owning an app model,
/// a store, provider protocol or UI. Every dependency is injected as a
/// Sendable closure so an iOS MainActor adapter and a macOS actor adapter can
/// both bridge their existing implementations without cross-platform imports.
public struct AgentRunEngine: Sendable {
    public typealias Provider = @Sendable (AgentRunProviderRequest) async throws -> AgentRunProviderTurn
    public typealias ToolExecutor = @Sendable (AgentRunToolCall) async throws -> String
    public typealias EventSink = @Sendable (AgentRunEvent) async -> Void
    public typealias CancellationProbe = @Sendable () async -> Bool

    public struct Dependencies: Sendable {
        public let provider: Provider
        public let executeTool: ToolExecutor
        public let emit: EventSink
        public let isCancelled: CancellationProbe

        public init(
            provider: @escaping Provider,
            executeTool: @escaping ToolExecutor,
            emit: @escaping EventSink = { _ in },
            isCancelled: @escaping CancellationProbe = { false }
        ) {
            self.provider = provider
            self.executeTool = executeTool
            self.emit = emit
            self.isCancelled = isCancelled
        }
    }

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Runs tool calls in provider order. This deterministic baseline matches
    /// the macOS Runtime and gives iOS a safe integration seam; an adapter that
    /// needs concurrent execution can expose one composite tool instead.
    public func run(
        messages initialMessages: [AgentRunMessage],
        systemPrompt: String? = nil,
        tools: [AgentRunToolDefinition] = [],
        configuration: AgentRunConfiguration = AgentRunConfiguration()
    ) async throws -> AgentRunResult {
        var messages = initialMessages
        var toolRounds = 0
        let permittedTools = Set(tools.map(\.name))

        await dependencies.emit(.started)
        do {
            while true {
                try await checkCancellation()
                await dependencies.emit(.providerRequested(round: toolRounds))
                let turn = try await dependencies.provider(
                    AgentRunProviderRequest(messages: messages, systemPrompt: systemPrompt, tools: tools, round: toolRounds)
                )
                try await checkCancellation()
                await dependencies.emit(.providerResponded(round: toolRounds, toolCallCount: turn.toolCalls.count))

                guard !turn.toolCalls.isEmpty else {
                    let text = turn.text ?? ""
                    messages.append(.init(role: .assistant, content: turn.text))
                    let result = AgentRunResult(text: text, messages: messages, toolRounds: toolRounds)
                    await dependencies.emit(.completed(text: text, toolRounds: toolRounds))
                    return result
                }

                guard toolRounds < configuration.maximumToolRounds else {
                    throw AgentRunEngineError.toolRoundLimitExceeded(configuration.maximumToolRounds)
                }
                toolRounds += 1
                messages.append(.init(role: .assistant, content: turn.text, toolCalls: turn.toolCalls))

                for call in turn.toolCalls {
                    try await checkCancellation()
                    await dependencies.emit(.toolStarted(call))
                    guard permittedTools.contains(call.name) else {
                        let error = AgentRunEngineError.toolUnavailable(call.name)
                        let message = error.localizedDescription
                        await dependencies.emit(.toolFailed(callID: call.id, toolName: call.name, message: message))
                        messages.append(.init(role: .tool, content: "Tool error: \(message)", toolCallID: call.id))
                        continue
                    }

                    do {
                        let output = try await dependencies.executeTool(call)
                        try await checkCancellation()
                        await dependencies.emit(.toolOutput(callID: call.id, toolName: call.name, output: output))
                        messages.append(.init(role: .tool, content: output, toolCallID: call.id))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let message = error.localizedDescription
                        await dependencies.emit(.toolFailed(callID: call.id, toolName: call.name, message: message))
                        messages.append(.init(role: .tool, content: "Tool error: \(message)", toolCallID: call.id))
                    }
                }
            }
        } catch is CancellationError {
            await dependencies.emit(.cancelled)
            throw CancellationError()
        } catch {
            await dependencies.emit(.failed(message: error.localizedDescription))
            throw error
        }
    }

    private func checkCancellation() async throws {
        try Task.checkCancellation()
        if await dependencies.isCancelled() {
            throw CancellationError()
        }
    }
}
