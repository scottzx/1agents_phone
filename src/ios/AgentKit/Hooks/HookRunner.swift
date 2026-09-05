//
//  HookRunner.swift
//  Minis
//
//  The agent loop's handle on the hook engine.
//
//  One runner per ViewModel. It owns the resolved bindings, the per-turn
//  ledger, and the context assembly, so each call site in the loop is a single
//  line that reads as what it guards rather than as hook plumbing.
//
//  Every entry point is safe to call unconditionally: with no bindings
//  configured (the default), each one returns an empty result without building
//  a context.
//

import Foundation

private let logger = AppLogger(category: "Hooks")

@MainActor
final class HookRunner {

    private var engine: HookEngine
    private var state = HookTurnState()

    private let sessionID: String
    private let agentID: String?
    private var sessionSource: String?
    private var wakeSource: TurnWakeSource = .unknown
    /// The loop iteration currently running. Set by `beginRound` so the tool
    /// events — which fire deep inside tool execution, far from the loop
    /// counter — do not have to thread a round through every call site.
    private var round = 0

    /// Resolve the bindings in force for this session. Called once per turn —
    /// a config edit mid-turn applies from the next turn, which is the same
    /// rule the rest of the app follows for session settings.
    static func resolve(sessionID: String, agentID: String?) -> HookRunner {
        HookRunner(
            sessionID: sessionID,
            agentID: agentID,
            bindings: HookConfigStore.shared.resolvedBindings(sessionId: sessionID, agentId: agentID)
        )
    }

    /// `handlers` is injectable so a test can exercise a decision the shipped
    /// registry cannot yet produce — `.restrictTools` and `.block` have no
    /// handler until the rules land, and the wiring that carries them needs to
    /// be provable before then.
    init(
        sessionID: String,
        agentID: String?,
        bindings: [ResolvedHookBinding],
        handlers: [any HookHandler] = HookRegistry.handlers
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.engine = HookEngine(
            handlers: handlers,
            bindings: bindings,
            log: { message in logger.warning("\(message)") }
        )
    }

    /// True when at least one binding is in force. The loop checks this before
    /// doing any per-round hook work.
    var isActive: Bool { !engine.isEmpty }

    /// Where an `.emitSystemRow` decision goes. Set by the owner, so the runner
    /// never has to know the ViewModel's message-array invariants.
    var onSystemRow: ((String, String) -> Void)?

    /// The bindings in force, for the settings UI.
    var resolvedBindings: [ResolvedHookBinding] { engine.resolvedBindings }

    /// Start a fresh turn: clears the tool ledger and the continue budget.
    func beginTurn(sessionSource: String?, isNoticeDriven: Bool, isExecutor: Bool) {
        state = HookTurnState()
        self.sessionSource = sessionSource
        wakeSource = TurnWakeSource.derive(
            sessionSource: sessionSource,
            isNoticeDriven: isNoticeDriven,
            isExecutor: isExecutor
        )
        round = 0
    }

    /// Called at the top of every agent-loop iteration.
    func beginRound(_ round: Int) { self.round = round }

    /// Tool names called so far this turn, in order.
    var toolCallsThisTurn: [String] { state.toolCalls }

    // MARK: - Events

    func turnWillStart() -> [HookOutcome] {
        guard isActive else { return [] }
        return engine.run(context(.turnWillStart))
    }

    /// Narrow this round's tool list. Returns `offered` unchanged when no hook
    /// restricts it — including when hooks are off entirely, which is the path
    /// every existing session takes.
    func tools(_ offered: [AgentToolDefinition]) -> [AgentToolDefinition] {
        guard isActive, engine.hasBindings(for: .toolsWillBeSent) else { return offered }
        let names = offered.map(\.name)
        let outcomes = engine.run(context(.toolsWillBeSent, availableTools: names))
        guard !outcomes.isEmpty else { return offered }
        let allowed = Set(HookEngine.applyToolRestrictions(offered: names, outcomes: outcomes))
        guard allowed.count != names.count else { return offered }
        logger.info("[Hooks] round \(round): tool surface narrowed \(names.count) → \(allowed.count)")
        return offered.filter { allowed.contains($0.name) }
    }

    /// The verdict on one tool call, plus its position in the turn.
    ///
    /// The index is handed back rather than looked up again later: with
    /// parallel tool calls, two invocations of the same tool are
    /// indistinguishable by name, and a `lastIndex(of:)` on the ledger would
    /// quietly attribute the wrong position to the wrong call.
    struct ToolGate {
        let index: Int
        let blockReason: String?
    }

    /// Record the call and ask whether it may run.
    ///
    /// The call is recorded even when a hook blocks it: "the first tool this
    /// turn was X, and it was refused" is the true history, and a later rule
    /// reading the ledger must see it.
    ///
    /// Note on ordering: a model may emit several tool calls in ONE response,
    /// and the loop executes those concurrently. They are serialized here by
    /// the main actor, so indices are unique and stable once assigned — but for
    /// a parallel batch the index reflects execution arrival, not the order the
    /// model wrote them. A rule about "the first tool call" is therefore exact
    /// for sequential calls and arbitrary-but-consistent within one batch.
    func willRunTool(name: String, argsJSON: String?) -> ToolGate {
        let index = state.recordToolCall(name)
        guard isActive else { return ToolGate(index: index, blockReason: nil) }
        let outcomes = engine.run(context(
            .willRunTool, toolName: name, toolArgsJSON: argsJSON, toolCallIndex: index
        ))
        apply(systemRowsIn: outcomes)
        return ToolGate(index: index, blockReason: HookEngine.blockReason(in: outcomes))
    }

    func didRunTool(name: String, index: Int, succeeded: Bool) {
        guard isActive else { return }
        let outcomes = engine.run(context(
            .didRunTool, toolName: name, toolCallIndex: index, toolDidSucceed: succeeded
        ))
        apply(systemRowsIn: outcomes)
    }

    /// Ask whether the turn may end. Returns a reminder to inject and run one
    /// more round, or nil to let it stop.
    ///
    /// The per-binding continue budget is consumed here, so a rule that keeps
    /// being unsatisfied stops forcing rounds instead of pinning the loop
    /// against its turn ceiling.
    func turnWillEnd(assistantText: String?) -> String? {
        guard isActive else { return nil }
        let outcomes = engine.run(context(.turnWillEnd, assistantText: assistantText))
        apply(systemRowsIn: outcomes)
        guard let request = HookEngine.continueRequest(in: outcomes) else { return nil }
        guard let binding = engine.binding(id: request.bindingID) else { return nil }
        guard state.consumeContinueBudget(bindingID: request.bindingID, limit: binding.maxContinuesPerTurn) else {
            logger.warning("[Hooks] \(request.bindingID) is out of continue budget this turn — letting the turn end")
            return nil
        }
        logger.info("[Hooks] \(request.bindingID) refused the turn end — running one more round")
        return request.reminder
    }

    // MARK: - Reminders

    /// Reminders produced by hooks that the next request should carry.
    /// Drained by the loop.
    private(set) var pendingReminders: [String] = []

    func drainReminders() -> [String] {
        defer { pendingReminders.removeAll() }
        return pendingReminders
    }

    func absorb(_ outcomes: [HookOutcome]) {
        apply(systemRowsIn: outcomes)
        pendingReminders.append(contentsOf: HookEngine.reminders(in: outcomes))
    }

    // MARK: - Private

    private func apply(systemRowsIn outcomes: [HookOutcome]) {
        for row in HookEngine.systemRows(in: outcomes) {
            onSystemRow?(row.text, row.icon)
        }
    }

    private func context(
        _ event: HookEvent,
        toolName: String? = nil,
        toolArgsJSON: String? = nil,
        toolCallIndex: Int? = nil,
        toolDidSucceed: Bool? = nil,
        availableTools: [String] = [],
        assistantText: String? = nil
    ) -> HookContext {
        HookContext(
            event: event,
            sessionID: sessionID,
            agentID: agentID,
            wakeSource: wakeSource,
            sessionSource: sessionSource,
            round: round,
            toolCallsThisTurn: state.toolCalls,
            toolName: toolName,
            toolArgsJSON: toolArgsJSON,
            toolCallIndexInTurn: toolCallIndex,
            toolDidSucceed: toolDidSucceed,
            availableTools: availableTools,
            assistantText: assistantText
        )
    }
}
