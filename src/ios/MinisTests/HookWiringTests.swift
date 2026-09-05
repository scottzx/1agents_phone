import XCTest
@testable import Minis

/// Device-side proof that the hook framework is actually wired into the loop.
///
/// The engine's own rules are unit-tested in the macOS package (HookEngineTests);
/// what can only be checked here is the part that touches the app: the real
/// config store writing real files, and `executeSingleToolUse` honouring a hook
/// decision. Both use handlers that do not ship yet — `.block` and
/// `.restrictTools` have no registered handler until the rules land — so the
/// carrying wiring is proven before anything depends on it.
@MainActor
final class HookWiringTests: XCTestCase {

    /// Returns the named decision at the named event, for any context.
    private struct FixedHandler: HookHandler {
        let handlerID: String
        let events: Set<HookEvent>
        let decision: HookDecision
        func run(_ context: HookContext, params: HookParams) throws -> HookDecision { decision }
    }

    private func binding(
        _ id: String,
        handler: String,
        event: HookEvent,
        match: HookMatch = HookMatch()
    ) -> [ResolvedHookBinding] {
        [ResolvedHookBinding(
            binding: HookBinding(id: id, handler: handler, event: event, match: match),
            scope: .global
        )]
    }

    // MARK: - Runner behaviour with the shipped registry

    func testShippedRegistryHasOnlyTheInertTraceHandler() {
        XCTAssertEqual(HookRegistry.handlers.count, 1)
        guard let trace = HookRegistry.handler(id: "trace") else {
            return XCTFail("the trace handler must be registered")
        }
        XCTAssertEqual(trace.events, Set(HookEvent.allCases),
                       "trace must be bindable to every event so the wiring can be observed end to end")
        let decision = try? HookRegistry.handler(id: "trace")?.run(
            HookContext(event: .willRunTool, sessionID: "s"), params: HookParams()
        )
        XCTAssertEqual(decision, .proceed, "the only shipped handler must not change behaviour")
    }

    func testRunnerWithNoBindingsIsFullyTransparent() {
        let runner = HookRunner(sessionID: "s", agentID: nil, bindings: [])
        runner.beginTurn(sessionSource: "user", isNoticeDriven: false, isExecutor: false)
        XCTAssertFalse(runner.isActive)

        let offered = [shellTool, sendTool]
        XCTAssertEqual(runner.tools(offered).map(\.name), offered.map(\.name))
        XCTAssertNil(runner.willRunTool(name: "shell_execute", argsJSON: "{}").blockReason)
        XCTAssertNil(runner.turnWillEnd(assistantText: "done"))
        XCTAssertTrue(runner.drainReminders().isEmpty)
    }

    // MARK: - toolsWillBeSent

    func testToolsWillBeSentNarrowsTheRoundToolset() {
        let runner = HookRunner(
            sessionID: "s", agentID: nil,
            bindings: binding("reply-first", handler: "only-send", event: .toolsWillBeSent),
            handlers: [FixedHandler(handlerID: "only-send", events: [.toolsWillBeSent],
                                    decision: .restrictTools(allow: ["send_message"]))]
        )
        runner.beginTurn(sessionSource: "user", isNoticeDriven: false, isExecutor: false)
        runner.beginRound(0)
        XCTAssertEqual(runner.tools([shellTool, sendTool]).map(\.name), ["send_message"],
                       "this is the mechanism reply-first will use instead of provider tool_choice")
    }

    func testWakeSourceMatchKeepsAgentTurnsUnrestricted() {
        let runner = HookRunner(
            sessionID: "s", agentID: nil,
            bindings: binding("human-only", handler: "only-send", event: .toolsWillBeSent,
                              match: HookMatch(wakeSource: [.human])),
            handlers: [FixedHandler(handlerID: "only-send", events: [.toolsWillBeSent],
                                    decision: .restrictTools(allow: ["send_message"]))]
        )
        runner.beginTurn(sessionSource: "group", isNoticeDriven: false, isExecutor: false)
        runner.beginRound(0)
        XCTAssertEqual(runner.tools([shellTool, sendTool]).count, 2,
                       "a rule scoped to human-opened turns must not fire on a group member turn")
    }

    // MARK: - turnWillEnd

    func testTurnWillEndCanRefuseOnceThenGivesUp() {
        let runner = HookRunner(
            sessionID: "s", agentID: nil,
            bindings: binding("close-loop", handler: "insist", event: .turnWillEnd),
            handlers: [FixedHandler(handlerID: "insist", events: [.turnWillEnd],
                                    decision: .continueTurn(reminder: "you never published"))]
        )
        runner.beginTurn(sessionSource: "user", isNoticeDriven: false, isExecutor: false)
        XCTAssertEqual(runner.turnWillEnd(assistantText: "x"), "you never published")
        XCTAssertNil(runner.turnWillEnd(assistantText: "x"),
                     "the per-binding budget must stop a rule from pinning the loop")
    }

    func testBeginTurnResetsTheContinueBudget() {
        let runner = HookRunner(
            sessionID: "s", agentID: nil,
            bindings: binding("close-loop", handler: "insist", event: .turnWillEnd),
            handlers: [FixedHandler(handlerID: "insist", events: [.turnWillEnd],
                                    decision: .continueTurn(reminder: "again"))]
        )
        runner.beginTurn(sessionSource: "user", isNoticeDriven: false, isExecutor: false)
        XCTAssertNotNil(runner.turnWillEnd(assistantText: "x"))
        XCTAssertNil(runner.turnWillEnd(assistantText: "x"))
        runner.beginTurn(sessionSource: "user", isNoticeDriven: false, isExecutor: false)
        XCTAssertNotNil(runner.turnWillEnd(assistantText: "x"), "a new turn gets a fresh budget")
    }

    // MARK: - The tool ledger

    func testToolLedgerRecordsOrderIncludingBlockedCalls() {
        let runner = HookRunner(
            sessionID: "s", agentID: nil,
            bindings: binding("no-shell", handler: "deny", event: .willRunTool,
                              match: HookMatch(toolName: ["shell_execute"])),
            handlers: [FixedHandler(handlerID: "deny", events: [.willRunTool],
                                    decision: .block(reason: "not yet"))]
        )
        runner.beginTurn(sessionSource: "user", isNoticeDriven: false, isExecutor: false)
        runner.beginRound(0)
        let first = runner.willRunTool(name: "shell_execute", argsJSON: "{}")
        let second = runner.willRunTool(name: "send_message", argsJSON: "{}")
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.blockReason, "not yet")
        XCTAssertEqual(second.index, 1)
        XCTAssertNil(second.blockReason)
        XCTAssertEqual(runner.toolCallsThisTurn, ["shell_execute", "send_message"],
                       "a refused call still happened and the ledger must show it")
    }

    // MARK: - The loop wiring itself

    /// The real payoff: `executeSingleToolUse` consults the hook and turns a
    /// refusal into an error tool_result instead of running the tool.
    func testExecuteSingleToolUseHonoursABlockingHook() async {
        let vm = AIChatViewModel()
        let message = ChatMessage(role: .assistant, content: "")
        message.blocks = [AssistantBlock(kind: .text, content: "")]
        vm.messages = [message]

        let runner = HookRunner(
            sessionID: "s", agentID: nil,
            bindings: binding("no-shell", handler: "deny", event: .willRunTool),
            handlers: [FixedHandler(handlerID: "deny", events: [.willRunTool],
                                    decision: .block(reason: "blocked on purpose"))]
        )
        runner.beginTurn(sessionSource: "user", isNoticeDriven: false, isExecutor: false)
        vm.hooks = runner

        let entry = AIChatViewModel.StreamResult.ToolEntry(
            id: "tool-1", name: "shell_execute",
            args: ["command": "echo hi"], blockIdx: 0,
            metadata: nil as ToolCallMetadata?, inputChunkRing: []
        )
        let outcome = await vm.executeSingleToolUse(
            tu: entry, msgIdx: 0, tools: [shellTool],
            batchBudget: AIChatViewModel.BatchImageBudget(initial: 1)
        )

        guard case .toolResult(_, _, let content, let isError, _, _, _, _) = outcome.resultPart else {
            return XCTFail("a blocked call must still produce a tool_result so history stays paired")
        }
        XCTAssertTrue(isError)
        XCTAssertTrue(content.contains("blocked on purpose"), "the reason must reach the model")
        XCTAssertTrue(content.contains("NOT executed"))
        XCTAssertEqual(runner.toolCallsThisTurn, ["shell_execute"])
    }

    func testExecuteSingleToolUseIsUnaffectedWhenNoHookIsSet() async {
        let vm = AIChatViewModel()
        let message = ChatMessage(role: .assistant, content: "")
        message.blocks = [AssistantBlock(kind: .text, content: "")]
        vm.messages = [message]
        vm.hooks = nil

        // An unknown tool takes the ordinary "unknown tool" path rather than a
        // hook path; the point is that nothing throws and no block is applied.
        let entry = AIChatViewModel.StreamResult.ToolEntry(
            id: "tool-1", name: "definitely_not_a_tool",
            args: ["a": "b"], blockIdx: 0,
            metadata: nil as ToolCallMetadata?, inputChunkRing: []
        )
        let outcome = await vm.executeSingleToolUse(
            tu: entry, msgIdx: 0, tools: [],
            batchBudget: AIChatViewModel.BatchImageBudget(initial: 1)
        )
        guard case .toolResult(_, _, let content, _, _, _, _, _) = outcome.resultPart else {
            return XCTFail("expected a tool_result")
        }
        XCTAssertFalse(content.contains("NOT executed"), "no hook is configured, so nothing may be blocked")
    }

    // MARK: - Config store round trip on real files

    func testConfigStoreRoundTripsAndMirrorsIntoTheSandbox() throws {
        let store = HookConfigStore.shared
        let sessionID = "hooktest-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in
            store.save(HookConfig(), scope: .session, id: sessionID)
        }

        let config = HookConfig(bindings: [
            HookBinding(id: "t", handler: "trace", event: .willRunTool)
        ])
        store.save(config, scope: .session, id: sessionID)
        store.reload()

        XCTAssertEqual(store.config(scope: .session, id: sessionID), config)
        let resolved = store.resolvedBindings(sessionId: sessionID, agentId: nil)
        XCTAssertTrue(resolved.contains { $0.binding.id == "t" && $0.scope == .session })

        // The sandbox mirror is the "an agent can read the rules it runs under"
        // claim; assert the file is really there and really parses.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mirror = documents
            .appendingPathComponent("alpine-rootfs/data/var/minis/config/hooks/sessions")
            .appendingPathComponent("\(sessionID).json")
        let data = try Data(contentsOf: mirror)
        XCTAssertEqual(try JSONDecoder().decode(HookConfig.self, from: data), config)
    }

    func testMasterSwitchOffYieldsNoBindings() {
        let store = HookConfigStore.shared
        let sessionID = "hooktest-\(UUID().uuidString)"
        let wasEnabled = store.isEnabled
        addTeardownBlock { @MainActor in
            store.isEnabled = wasEnabled
            store.save(HookConfig(), scope: .session, id: sessionID)
        }

        store.save(HookConfig(bindings: [
            HookBinding(id: "t", handler: "trace", event: .willRunTool)
        ]), scope: .session, id: sessionID)

        store.isEnabled = true
        XCTAssertFalse(store.resolvedBindings(sessionId: sessionID, agentId: nil).isEmpty)
        store.isEnabled = false
        XCTAssertTrue(store.resolvedBindings(sessionId: sessionID, agentId: nil).isEmpty,
                      "the kill switch must return the app to its pre-hooks behaviour")
    }

    // MARK: - Fixtures

    private var shellTool: AgentToolDefinition {
        AgentToolDefinition(name: "shell_execute", description: "", parameters: [:], required: [])
    }

    private var sendTool: AgentToolDefinition {
        AgentToolDefinition(name: "send_message", description: "", parameters: [:], required: [])
    }
}
