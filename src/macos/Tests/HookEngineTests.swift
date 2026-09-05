import XCTest
@testable import MinisAppleDomain

/// Stub handler: returns whatever it was constructed with, or throws.
private struct StubHandler: HookHandler {
    let handlerID: String
    let events: Set<HookEvent>
    let decision: HookDecision
    var shouldThrow = false
    var delay: TimeInterval = 0
    /// Records every context it saw, so ordering assertions have evidence.
    let recorder: Recorder?

    final class Recorder: @unchecked Sendable {
        private(set) var calls: [String] = []
        func record(_ id: String) { calls.append(id) }
    }

    private struct Boom: Error {}

    func run(_ context: HookContext, params: HookParams) throws -> HookDecision {
        recorder?.record(handlerID)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if shouldThrow { throw Boom() }
        return decision
    }
}

private func binding(
    _ id: String,
    handler: String = "h",
    event: HookEvent = .willRunTool,
    enabled: Bool = true,
    match: HookMatch = HookMatch(),
    order: Int = 100,
    maxContinues: Int = 1
) -> HookBinding {
    HookBinding(id: id, handler: handler, event: event, enabled: enabled,
                match: match, order: order, maxContinuesPerTurn: maxContinues)
}

private func context(
    _ event: HookEvent = .willRunTool,
    wakeSource: TurnWakeSource = .human,
    toolName: String? = "shell_execute",
    availableTools: [String] = []
) -> HookContext {
    HookContext(event: event, sessionID: "s1", agentID: "agent-1", wakeSource: wakeSource,
                sessionSource: "user", toolName: toolName, availableTools: availableTools)
}

final class HookEngineTests: XCTestCase {

    // MARK: - Scope merge

    func testNarrowerScopeReplacesBindingWithSameID() {
        let merged = HookEngine.merge(
            global: HookConfig(bindings: [binding("reply-first", enabled: true)]),
            agent: HookConfig(bindings: [binding("reply-first", enabled: false)])
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].scope, .agent)
        XCTAssertFalse(merged[0].binding.enabled, "an agent must be able to switch off a global rule by redeclaring it")
    }

    func testDistinctIDsFromAllThreeScopesAllSurvive() {
        let merged = HookEngine.merge(
            global: HookConfig(bindings: [binding("g")]),
            agent: HookConfig(bindings: [binding("a")]),
            session: HookConfig(bindings: [binding("s")])
        )
        XCTAssertEqual(merged.map(\.binding.id).sorted(), ["a", "g", "s"])
        XCTAssertEqual(Set(merged.map(\.scope)), [.global, .agent, .session])
    }

    func testOrderWinsOverScopeAndDeclarationOrderIsStable() {
        let merged = HookEngine.merge(
            global: HookConfig(bindings: [binding("late", order: 900), binding("first", order: 1)]),
            session: HookConfig(bindings: [binding("mid", order: 50)])
        )
        XCTAssertEqual(merged.map(\.binding.id), ["first", "mid", "late"])
    }

    func testEqualOrderPutsBroaderScopeFirst() {
        let merged = HookEngine.merge(
            global: HookConfig(bindings: [binding("g", order: 10)]),
            session: HookConfig(bindings: [binding("s", order: 10)])
        )
        XCTAssertEqual(merged.map(\.binding.id), ["g", "s"])
    }

    // MARK: - Matching

    func testWakeSourceFilterSelectsOnlyMatchingTurns() {
        let engine = HookEngine(
            handlers: [StubHandler(handlerID: "h", events: [.willRunTool], decision: .block(reason: "no"), recorder: nil)],
            bindings: HookEngine.merge(global: HookConfig(bindings: [
                binding("human-only", match: HookMatch(wakeSource: [.human]))
            ]))
        )
        XCTAssertEqual(HookEngine.blockReason(in: engine.run(context(wakeSource: .human))), "no")
        XCTAssertTrue(engine.run(context(wakeSource: .async)).isEmpty)
        XCTAssertTrue(engine.run(context(wakeSource: .agent)).isEmpty)
    }

    func testToolNameFilterAndDisabledBindingAreBothRespected() {
        let engine = HookEngine(
            handlers: [StubHandler(handlerID: "h", events: [.willRunTool], decision: .block(reason: "no"), recorder: nil)],
            bindings: HookEngine.merge(global: HookConfig(bindings: [
                binding("only-shell", match: HookMatch(toolName: ["shell_execute"])),
                binding("off", enabled: false)
            ]))
        )
        XCTAssertNotNil(HookEngine.blockReason(in: engine.run(context(toolName: "shell_execute"))))
        XCTAssertNil(HookEngine.blockReason(in: engine.run(context(toolName: "file_read"))))
    }

    func testMatchOnAbsentContextFieldDoesNotMatch() {
        // A binding that asks about a tool name must not fire on a turn-level
        // event that has none — otherwise every tool filter silently becomes a
        // turn filter too.
        let engine = HookEngine(
            handlers: [StubHandler(handlerID: "h", events: HookEvent.allCases.reduce(into: Set()) { $0.insert($1) }, decision: .injectReminder("x"), recorder: nil)],
            bindings: HookEngine.merge(global: HookConfig(bindings: [
                binding("needs-tool", event: .turnWillStart, match: HookMatch(toolName: ["shell_execute"]))
            ]))
        )
        XCTAssertTrue(engine.run(context(.turnWillStart, toolName: nil)).isEmpty)
    }

    // MARK: - Decision legality

    func testDecisionUnsupportedByTheEventIsDowngraded() {
        // `.continueTurn` only means something at turnWillEnd. Bound to
        // willRunTool it must be dropped, not silently applied elsewhere.
        let engine = HookEngine(
            handlers: [StubHandler(handlerID: "h", events: [.willRunTool], decision: .continueTurn(reminder: "again"), recorder: nil)],
            bindings: HookEngine.merge(global: HookConfig(bindings: [binding("wrong-event")]))
        )
        XCTAssertTrue(engine.run(context()).isEmpty)
    }

    func testEveryEventAcceptsProceedAndRejectsForeignControlDecisions() {
        for event in HookEvent.allCases {
            XCTAssertTrue(event.allows(.proceed), "\(event) must accept .proceed")
        }
        XCTAssertTrue(HookEvent.willRunTool.allows(.block(reason: "r")))
        XCTAssertFalse(HookEvent.didRunTool.allows(.block(reason: "r")))
        XCTAssertTrue(HookEvent.toolsWillBeSent.allows(.restrictTools(allow: ["a"])))
        XCTAssertFalse(HookEvent.willRunTool.allows(.restrictTools(allow: ["a"])))
        XCTAssertTrue(HookEvent.turnWillEnd.allows(.continueTurn(reminder: "r")))
        XCTAssertFalse(HookEvent.turnWillStart.allows(.continueTurn(reminder: "r")))
        XCTAssertTrue(HookEvent.turnWillStart.allows(.injectReminder("r")))
        XCTAssertFalse(HookEvent.turnWillEnd.allows(.injectReminder("r")),
                       "a reminder at turn end would have no round to ride on — .continueTurn carries its own")
    }

    // MARK: - Failure containment

    func testThrowingHandlerIsTreatedAsProceedAndLaterHooksStillRun() {
        let recorder = StubHandler.Recorder()
        var boom = StubHandler(handlerID: "boom", events: [.willRunTool], decision: .proceed, recorder: recorder)
        boom.shouldThrow = true
        let engine = HookEngine(
            handlers: [
                boom,
                StubHandler(handlerID: "ok", events: [.willRunTool], decision: .block(reason: "second ran"), recorder: recorder),
            ],
            bindings: HookEngine.merge(global: HookConfig(bindings: [
                binding("b1", handler: "boom", order: 1),
                binding("b2", handler: "ok", order: 2),
            ]))
        )
        XCTAssertEqual(HookEngine.blockReason(in: engine.run(context())), "second ran")
        XCTAssertEqual(recorder.calls, ["boom", "ok"])
    }

    func testUnknownHandlerAndUndeclaredEventAreSkipped() {
        let engine = HookEngine(
            handlers: [StubHandler(handlerID: "h", events: [.didRunTool], decision: .block(reason: "no"), recorder: nil)],
            bindings: HookEngine.merge(global: HookConfig(bindings: [
                binding("ghost", handler: "does-not-exist"),
                binding("mismatched", handler: "h"),   // handler declares didRunTool only
            ]))
        )
        XCTAssertTrue(engine.run(context()).isEmpty)
    }

    func testBudgetStopsLaterHandlers() {
        let recorder = StubHandler.Recorder()
        var slow = StubHandler(handlerID: "slow", events: [.willRunTool], decision: .proceed, recorder: recorder)
        slow.delay = 0.05
        let engine = HookEngine(
            handlers: [
                slow,
                StubHandler(handlerID: "never", events: [.willRunTool], decision: .block(reason: "should not run"), recorder: recorder),
            ],
            bindings: HookEngine.merge(global: HookConfig(bindings: [
                binding("b1", handler: "slow", order: 1),
                binding("b2", handler: "never", order: 2),
            ])),
            budget: 0.001
        )
        XCTAssertTrue(engine.run(context()).isEmpty)
        XCTAssertEqual(recorder.calls, ["slow"], "the handler queued behind an over-budget one must not run")
    }

    func testTerminalDecisionStopsLaterHooks() {
        let recorder = StubHandler.Recorder()
        let engine = HookEngine(
            handlers: [
                StubHandler(handlerID: "first", events: [.willRunTool], decision: .block(reason: "stop"), recorder: recorder),
                StubHandler(handlerID: "second", events: [.willRunTool], decision: .block(reason: "unreached"), recorder: recorder),
            ],
            bindings: HookEngine.merge(global: HookConfig(bindings: [
                binding("b1", handler: "first", order: 1),
                binding("b2", handler: "second", order: 2),
            ]))
        )
        let outcomes = engine.run(context())
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(HookEngine.blockReason(in: outcomes), "stop")
        XCTAssertEqual(recorder.calls, ["first"])
    }

    // MARK: - Tool restriction folding

    func testRestrictToolsIntersectsAndNeverAddsUnofferedTools() {
        let offered = ["send_message", "shell_execute", "file_read"]
        let outcomes = [
            HookOutcome(bindingID: "b", handlerID: "h",
                        decision: .restrictTools(allow: ["send_message", "pass", "browser_open"]))
        ]
        XCTAssertEqual(HookEngine.applyToolRestrictions(offered: offered, outcomes: outcomes), ["send_message"],
                       "a hook may narrow the toolset but must never conjure a tool the session does not offer")
    }

    func testMultipleRestrictionsCompose() {
        let offered = ["a", "b", "c"]
        let outcomes = [
            HookOutcome(bindingID: "1", handlerID: "h", decision: .restrictTools(allow: ["a", "b"])),
            HookOutcome(bindingID: "2", handlerID: "h", decision: .restrictTools(allow: ["b", "c"])),
        ]
        XCTAssertEqual(HookEngine.applyToolRestrictions(offered: offered, outcomes: outcomes), ["b"])
    }

    func testNoOutcomesLeavesTheToolsetUntouched() {
        let offered = ["a", "b"]
        XCTAssertEqual(HookEngine.applyToolRestrictions(offered: offered, outcomes: []), offered)
    }

    // MARK: - Turn state

    func testToolCallIndexIsZeroBasedAndOrdered() {
        var state = HookTurnState()
        XCTAssertEqual(state.recordToolCall("send_message"), 0)
        XCTAssertEqual(state.recordToolCall("shell_execute"), 1)
        XCTAssertEqual(state.toolCalls, ["send_message", "shell_execute"])
    }

    func testContinueBudgetIsPerBindingAndExhausts() {
        var state = HookTurnState()
        XCTAssertTrue(state.consumeContinueBudget(bindingID: "close-loop", limit: 1))
        XCTAssertFalse(state.consumeContinueBudget(bindingID: "close-loop", limit: 1),
                       "a continueTurn rule must not be able to spin the loop")
        XCTAssertTrue(state.consumeContinueBudget(bindingID: "other", limit: 1))
    }

    func testZeroBudgetForbidsForcingAnotherRound() {
        var state = HookTurnState()
        XCTAssertFalse(state.consumeContinueBudget(bindingID: "b", limit: 0))
    }

    // MARK: - Wake source derivation

    func testNoticeDrivenTurnsAreAsyncWhateverTheSessionSourceSays() {
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: "user", isNoticeDriven: true), .async)
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: "group", isNoticeDriven: true), .async)
    }

    func testWakeSourceDerivationTable() {
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: "user", isNoticeDriven: false), .human)
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: "hardware", isNoticeDriven: false), .human)
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: "siri", isNoticeDriven: false), .human)
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: "shortcut", isNoticeDriven: false), .human)
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: nil, isNoticeDriven: false), .human)
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: "group", isNoticeDriven: false), .agent)
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: "schedule", isNoticeDriven: false), .schedule)
        XCTAssertEqual(TurnWakeSource.derive(sessionSource: "wat", isNoticeDriven: false), .unknown)
    }

    func testSubagentLoopIsNeverAHumanTurn() {
        XCTAssertEqual(
            TurnWakeSource.derive(sessionSource: "user", isNoticeDriven: false, isExecutor: true), .agent,
            "an executor inherits its parent's session source but nobody is waiting on its opening line"
        )
    }

    // MARK: - Config decoding

    func testBindingJSONDecodesWithDefaultsForOmittedFields() throws {
        let json = """
        { "version": 1, "bindings": [
            { "id": "reply-first", "handler": "require_first_tool", "event": "willRunTool",
              "match": { "wakeSource": ["human"] },
              "params": { "tool": "send_message", "allow": ["pass"], "limit": 3, "strict": true } }
        ]}
        """
        let config = try JSONDecoder().decode(HookConfig.self, from: Data(json.utf8))
        let binding = try XCTUnwrap(config.bindings.first)
        XCTAssertTrue(binding.enabled)
        XCTAssertEqual(binding.order, 100)
        XCTAssertEqual(binding.maxContinuesPerTurn, 1)
        XCTAssertEqual(binding.match.wakeSource, [.human])
        XCTAssertNil(binding.match.toolName)
        XCTAssertEqual(binding.params.string("tool"), "send_message")
        XCTAssertEqual(binding.params.stringArray("allow"), ["pass"])
        XCTAssertEqual(binding.params.int("limit"), 3)
        XCTAssertTrue(binding.params.bool("strict"))
        XCTAssertEqual(binding.params.string("missing", default: "fallback"), "fallback")
    }

    func testConfigRoundTripsThroughJSON() throws {
        let original = HookConfig(bindings: [
            binding("b", handler: "trace", event: .turnWillEnd, match: HookMatch(wakeSource: [.agent, .async], agentID: ["a1"]))
        ])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(HookConfig.self, from: data), original)
    }

    func testEmptyEngineReportsItself() {
        let engine = HookEngine(handlers: [], bindings: [])
        XCTAssertTrue(engine.isEmpty)
        XCTAssertFalse(engine.hasBindings(for: .willRunTool))
        XCTAssertTrue(engine.run(context()).isEmpty)
    }
}
