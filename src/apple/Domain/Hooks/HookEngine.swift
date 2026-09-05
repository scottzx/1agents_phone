//
//  HookEngine.swift
//  Minis
//
//  Resolves declared bindings into decisions. Contains no rules of its own.
//
//  Everything here is deliberately synchronous and value-typed. A hook runs
//  between the agent loop and the thing it guards — a tool about to execute, a
//  turn about to end — so it cannot be allowed to suspend, and it must not be
//  able to take the turn down with it. The three guarantees this file exists to
//  provide: a handler that throws is a no-op, a handler set that runs long is
//  cut off, and a decision made at the wrong event never takes effect.
//

import Foundation

// MARK: - Handler

/// A rule implementation. Registered by `handlerID`; bound to events by config.
public protocol HookHandler: Sendable {
    var handlerID: String { get }
    var events: Set<HookEvent> { get }
    func run(_ context: HookContext, params: HookParams) throws -> HookDecision
}

// MARK: - Per-turn state

/// The mutable bookkeeping one turn needs, owned by the caller.
///
/// Kept out of the engine so the engine stays a pure function of
/// (bindings, context): the loop already owns per-run state of exactly this
/// shape (`didInjectEmptyToolReminderThisRun`), and hiding a second copy inside
/// a shared engine is how the two would drift.
public struct HookTurnState: Sendable, Equatable {
    public private(set) var toolCalls: [String] = []
    private var continueCounts: [String: Int] = [:]

    public init() {}

    /// Record a tool call and return its 0-based index within this turn.
    @discardableResult
    public mutating func recordToolCall(_ name: String) -> Int {
        toolCalls.append(name)
        return toolCalls.count - 1
    }

    /// Whether `bindingID` may still force another round, consuming one budget
    /// unit if so. Without this a `continueTurn` rule and a model that keeps
    /// not complying would spin until the turn ceiling.
    public mutating func consumeContinueBudget(bindingID: String, limit: Int) -> Bool {
        let used = continueCounts[bindingID] ?? 0
        guard used < max(0, limit) else { return false }
        continueCounts[bindingID] = used + 1
        return true
    }
}

// MARK: - Outcome

public struct HookOutcome: Sendable, Equatable {
    public let bindingID: String
    public let handlerID: String
    public let decision: HookDecision

    public init(bindingID: String, handlerID: String, decision: HookDecision) {
        self.bindingID = bindingID
        self.handlerID = handlerID
        self.decision = decision
    }
}

// MARK: - Engine

public struct HookEngine: Sendable {
    /// Wall-clock budget for all handlers of a single event, in seconds.
    /// Checked between handlers: a single handler that blocks for longer than
    /// this cannot be preempted (handlers are synchronous by design), but it
    /// stops every handler queued behind it.
    public static let defaultBudget: TimeInterval = 0.050

    private let handlers: [String: any HookHandler]
    private let bindings: [ResolvedHookBinding]
    private let budget: TimeInterval
    private let log: @Sendable (String) -> Void

    public init(
        handlers: [any HookHandler],
        bindings: [ResolvedHookBinding],
        budget: TimeInterval = HookEngine.defaultBudget,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.handlers = Dictionary(handlers.map { ($0.handlerID, $0) }, uniquingKeysWith: { _, last in last })
        self.bindings = bindings
        self.budget = budget
        self.log = log
    }

    /// True when nothing at all is bound — the loop uses this to skip building
    /// a context on the hot path.
    public var isEmpty: Bool { bindings.isEmpty }

    public func hasBindings(for event: HookEvent) -> Bool {
        bindings.contains { $0.binding.enabled && $0.binding.event == event }
    }

    /// The binding behind an outcome — callers need its per-turn limits.
    public func binding(id: String) -> HookBinding? {
        bindings.first { $0.binding.id == id }?.binding
    }

    /// Every binding in force, for the settings UI.
    public var resolvedBindings: [ResolvedHookBinding] { bindings }

    // MARK: Scope merge

    /// Merge the three layers. Narrower scopes win: a binding id declared again
    /// at a narrower scope replaces the broader one wholesale (so an agent can
    /// disable a global rule by redeclaring it with `enabled: false`).
    ///
    /// Result is sorted by `order`, then by scope breadth, then by the order
    /// they were declared — a stable sort, so a config that pins no `order`
    /// still runs top-to-bottom as written.
    public static func merge(
        global: HookConfig = .empty,
        agent: HookConfig = .empty,
        session: HookConfig = .empty
    ) -> [ResolvedHookBinding] {
        var byID: [String: ResolvedHookBinding] = [:]
        var declarationOrder: [String] = []
        for (scope, config) in [(HookScope.global, global), (.agent, agent), (.session, session)] {
            for binding in config.bindings {
                if byID[binding.id] == nil { declarationOrder.append(binding.id) }
                byID[binding.id] = ResolvedHookBinding(binding: binding, scope: scope)
            }
        }
        let scopeRank: [HookScope: Int] = [.global: 0, .agent: 1, .session: 2]
        return declarationOrder.compactMap { byID[$0] }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.binding.order != rhs.element.binding.order {
                    return lhs.element.binding.order < rhs.element.binding.order
                }
                let l = scopeRank[lhs.element.scope] ?? 0
                let r = scopeRank[rhs.element.scope] ?? 0
                if l != r { return l < r }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: Run

    /// Run every binding that matches `context`, in order.
    ///
    /// Stops early on the first terminal decision (`.block`, `.continueTurn`).
    /// Never throws: a handler that does is logged and treated as `.proceed`,
    /// because a rule failing open costs one unenforced rule while failing
    /// closed costs the user their turn.
    public func run(_ context: HookContext) -> [HookOutcome] {
        guard !bindings.isEmpty else { return [] }
        let started = Date()
        var outcomes: [HookOutcome] = []

        for resolved in bindings {
            let binding = resolved.binding
            guard binding.enabled, binding.event == context.event, binding.match.matches(context) else { continue }
            guard let handler = handlers[binding.handler] else {
                log("[Hooks] binding \(binding.id) references unknown handler \(binding.handler)")
                continue
            }
            guard handler.events.contains(context.event) else {
                log("[Hooks] handler \(binding.handler) is not declared for \(context.event.rawValue) — skipping binding \(binding.id)")
                continue
            }
            if Date().timeIntervalSince(started) > budget {
                log("[Hooks] budget exhausted at \(context.event.rawValue); skipping \(binding.id) and any later binding")
                break
            }

            let decision: HookDecision
            do {
                decision = try handler.run(context, params: binding.params)
            } catch {
                log("[Hooks] handler \(binding.handler) threw for binding \(binding.id): \(error) — proceeding")
                continue
            }

            if case .proceed = decision { continue }
            guard context.event.allows(decision) else {
                log("[Hooks] binding \(binding.id) returned a decision \(context.event.rawValue) does not support — ignoring")
                continue
            }
            outcomes.append(HookOutcome(bindingID: binding.id, handlerID: binding.handler, decision: decision))
            if HookEvent.isTerminal(decision) { break }
        }
        return outcomes
    }

    // MARK: Decision folding

    /// The tool list for this round: `offered` narrowed by every
    /// `.restrictTools` outcome. Intersection only — a hook can take a tool
    /// away but never add one the session does not already offer, so a bad
    /// config cannot widen an agent's reach.
    public static func applyToolRestrictions(offered: [String], outcomes: [HookOutcome]) -> [String] {
        var allowed = offered
        for outcome in outcomes {
            guard case .restrictTools(let allow) = outcome.decision else { continue }
            let allowSet = Set(allow)
            allowed = allowed.filter { allowSet.contains($0) }
        }
        return allowed
    }

    /// The first block reason, if any.
    public static func blockReason(in outcomes: [HookOutcome]) -> String? {
        for outcome in outcomes {
            if case .block(let reason) = outcome.decision { return reason }
        }
        return nil
    }

    /// The first continue request, if any, as (bindingID, reminder).
    public static func continueRequest(in outcomes: [HookOutcome]) -> (bindingID: String, reminder: String)? {
        for outcome in outcomes {
            if case .continueTurn(let reminder) = outcome.decision {
                return (outcome.bindingID, reminder)
            }
        }
        return nil
    }

    public static func reminders(in outcomes: [HookOutcome]) -> [String] {
        outcomes.compactMap {
            if case .injectReminder(let text) = $0.decision { return text }
            return nil
        }
    }

    public static func systemRows(in outcomes: [HookOutcome]) -> [(text: String, icon: String)] {
        outcomes.compactMap {
            if case .emitSystemRow(let text, let icon) = $0.decision { return (text, icon) }
            return nil
        }
    }
}
