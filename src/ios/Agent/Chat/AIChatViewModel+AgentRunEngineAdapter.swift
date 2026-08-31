import Foundation

/// The streaming iOS loop still owns progressive UI blocks, retry/fallback and
/// concurrent tool execution. This adapter is the compile-time/runtime seam
/// for moving provider/tool cycles to the shared Foundation-only engine one
/// path at a time without importing UIKit or provider implementations there.
extension AIChatViewModel {
    func sharedAgentRunToolDefinitions(from tools: [AgentToolDefinition]) -> [AgentRunToolDefinition] {
        tools.map { tool in
            var properties: [String: Any] = [:]
            for (name, parameter) in tool.parameters {
                var value: [String: Any] = [
                    "type": parameter.type.rawValue,
                    "description": parameter.description
                ]
                if let enumValues = parameter.enumValues { value["enum"] = enumValues }
                if parameter.type == .stringArray { value["items"] = ["type": "string"] }
                properties[name] = value
            }
            let schema: [String: Any] = [
                "type": "object",
                "properties": properties,
                "required": tool.required,
                "additionalProperties": false
            ]
            let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
            return AgentRunToolDefinition(
                name: tool.name,
                description: tool.description,
                parametersJSON: String(decoding: data, as: UTF8.self)
            )
        }
    }

    /// Builds an executable shared run engine for an iOS provider/tool adapter.
    /// Callers provide the provider-specific stream-to-turn bridge and the
    /// existing tool executor; cancellation remains tied to the view model's
    /// Stop action. The first live migration can opt in per execution path.
    func makeSharedAgentRunEngine(
        provider: @escaping AgentRunEngine.Provider,
        executeTool: @escaping AgentRunEngine.ToolExecutor,
        emit: @escaping AgentRunEngine.EventSink = { _ in }
    ) -> AgentRunEngine {
        AgentRunEngine(dependencies: .init(
            provider: provider,
            executeTool: executeTool,
            emit: emit,
            isCancelled: { [weak self] in
                guard let self else { return true }
                return await self.isSharedAgentRunCancelled()
            }
        ))
    }

    private func isSharedAgentRunCancelled() -> Bool {
        userDidCancel || Task.isCancelled
    }

    /// Executes one low-risk text tool through the shared provider→tool→provider
    /// state machine. The provider turn has already been streamed by the iOS
    /// UI loop, so the replay provider supplies that captured tool request and
    /// the engine owns the cancellation/event/tool ledger from this point on.
    /// Concurrent, browser and media batches deliberately stay on the existing
    /// implementation until their richer result payloads have shared models.
    func executeSharedAgentRunToolBatch(
        entries: [StreamResult.ToolEntry],
        msgIdx: Int,
        tools: [AgentToolDefinition],
        sharedTools: [AgentRunToolDefinition]
    ) async throws -> [ToolExecOutcome] {
        let adapter = SharedAgentRunToolBatchAdapter(viewModel: self, entries: entries, msgIdx: msgIdx, tools: tools)
        let replay = SharedAgentRunReplayProvider(calls: entries.map {
            AgentRunToolCall(id: $0.id, name: $0.name, argumentsJSON: Self.agentRunArgumentsJSON($0.args))
        })
        let engine = makeSharedAgentRunEngine(
            provider: { _ in await replay.nextTurn() },
            executeTool: { call in try await adapter.execute(call) },
            emit: { event in
                if case .toolStarted(let call) = event {
                    AgentRequestTrace.shared.step("agentLoop.sharedRunTool", detail: "tool=\(call.name)")
                }
            }
        )
        _ = try await engine.run(
            messages: [],
            tools: sharedTools,
            configuration: AgentRunConfiguration(maximumToolRounds: 1)
        )
        return adapter.outcomes
    }

    func shouldUseSharedAgentRunEngine(for entries: [StreamResult.ToolEntry]) -> Bool {
        if UserDefaults.standard.bool(forKey: "Minis.UseSharedAgentRunEngine") { return !entries.isEmpty }
        guard entries.count == 1, let entry = entries.first else { return false }
        return Self.sharedEngineDefaultToolNames.contains(entry.name)
    }

    private static let sharedEngineDefaultToolNames: Set<String> = [
        "file_read", "file_write", "file_edit", "file_list",
        "memory_write", "memory_get", "shell_execute"
    ]

    private static func agentRunArgumentsJSON(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
private final class SharedAgentRunToolBatchAdapter {
    private weak var viewModel: AIChatViewModel?
    private let entries: [String: AIChatViewModel.StreamResult.ToolEntry]
    private let msgIdx: Int
    private let tools: [AgentToolDefinition]
    private let imageBudget: AIChatViewModel.BatchImageBudget
    private(set) var outcomes: [AIChatViewModel.ToolExecOutcome] = []

    init(viewModel: AIChatViewModel, entries: [AIChatViewModel.StreamResult.ToolEntry], msgIdx: Int, tools: [AgentToolDefinition]) {
        self.viewModel = viewModel
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        self.msgIdx = msgIdx
        self.tools = tools
        self.imageBudget = AIChatViewModel.BatchImageBudget(initial: AIChatViewModel.kImageContextKeepCount)
    }

    func execute(_ call: AgentRunToolCall) async throws -> String {
        guard let viewModel, let entry = entries[call.id] else { throw CancellationError() }
        let outcome = await viewModel.executeSingleToolUse(
            tu: entry,
            msgIdx: msgIdx,
            tools: tools,
            batchBudget: imageBudget
        )
        outcomes.append(outcome)
        guard case .toolResult(_, _, let content, _, _, _, _, _) = outcome.resultPart else {
            return "Tool completed."
        }
        return content
    }
}

private actor SharedAgentRunReplayProvider {
    private var didReplay = false
    private let calls: [AgentRunToolCall]

    init(calls: [AgentRunToolCall]) {
        self.calls = calls
    }

    func nextTurn() -> AgentRunProviderTurn {
        defer { didReplay = true }
        return didReplay ? .init(text: "") : .init(text: nil, toolCalls: calls)
    }
}
