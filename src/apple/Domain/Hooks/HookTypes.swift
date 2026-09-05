//
//  HookTypes.swift
//  Minis
//
//  The vocabulary of the turn-lifecycle hook framework.
//
//  This file deliberately contains no rules. It defines WHERE a rule can be
//  attached (`HookEvent`), WHAT a rule may do (`HookDecision`), WHAT it gets to
//  look at (`HookContext`) and HOW it is declared (`HookBinding`). Concrete
//  handlers live on the platform side and are registered by id.
//
//  The event set is the minimal-necessary intersection of three shipping
//  designs — Claude Code (30+ events), Cursor (~20), Gemini CLI (10) — plus one
//  addition, `toolsWillBeSent`, taken from Gemini's `BeforeToolSelection`.
//  That one event is what lets a "the first thing you do must be X" rule be
//  enforced by narrowing the tool list, instead of plumbing a forced
//  `tool_choice` through every provider's request builder.
//

import Foundation

// MARK: - Events

/// A point in the agent loop where a hook may run.
///
/// Blocking events run synchronously between the loop and the thing they guard;
/// their decision changes what happens next. Observational events cannot alter
/// control flow — a decision that would is logged and downgraded.
public enum HookEvent: String, Codable, Sendable, CaseIterable {
    /// A turn is starting, before the first provider request. Blocking.
    case turnWillStart
    /// A round's tool list is about to be sent to the model. Blocking.
    case toolsWillBeSent
    /// A tool call is about to execute, after arg repair + preflight. Blocking.
    case willRunTool
    /// A tool call finished. Observational.
    case didRunTool
    /// The loop is about to end the turn. Blocking — this is the only place a
    /// rule can refuse to let the turn stop.
    case turnWillEnd

    /// Whether `decision` is meaningful at this event.
    ///
    /// The check is here rather than in the engine so the legality table reads
    /// as one thing: a handler wired to the wrong event fails loudly in tests
    /// instead of silently doing nothing in production.
    public func allows(_ decision: HookDecision) -> Bool {
        switch decision {
        case .proceed:
            return true
        case .emitSystemRow:
            return true
        case .block:
            return self == .willRunTool
        case .restrictTools:
            return self == .toolsWillBeSent
        case .continueTurn:
            return self == .turnWillEnd
        case .injectReminder:
            // turnWillStart only. At turnWillEnd the turn is over unless
            // `.continueTurn` fires — and that case carries its own reminder —
            // so a reminder returned there would have no round to ride on.
            return self == .turnWillStart
        }
    }

    /// A decision that ends the event: later bindings for the same event do not
    /// run. Blocking a tool or refusing to end a turn are both "first one wins"
    /// — running the remaining hooks after that would only produce decisions
    /// about a world that no longer applies.
    public static func isTerminal(_ decision: HookDecision) -> Bool {
        switch decision {
        case .block, .continueTurn: return true
        default: return false
        }
    }
}

// MARK: - Decisions

public enum HookDecision: Sendable, Equatable {
    /// Nothing to say. The overwhelmingly common answer.
    case proceed
    /// Refuse this tool call. `reason` reaches the model as the tool result.
    case block(reason: String)
    /// Narrow the tools exposed for this round to `allow`. Intersected with
    /// what the session actually offers — a hook can take tools away, never
    /// conjure one the toolset does not contain.
    case restrictTools(allow: [String])
    /// Append a `<system-reminder>` to this turn's first request.
    case injectReminder(String)
    /// Refuse to end the turn: inject `reminder` and run one more round.
    case continueTurn(reminder: String)
    /// Write a user-visible system row. Reaches the person, not the model.
    case emitSystemRow(text: String, icon: String)
}

// MARK: - Wake source

/// Who opened this turn.
///
/// The load-bearing distinction for turn-rhythm rules: a turn a person opened
/// owes them an opening line, while an agent- or notice-driven wake does not
/// (it owes only a delivered result, or an explicit pass). Every such rule
/// keys off this, which is why it is derived once, in one place, and tested.
public enum TurnWakeSource: String, Codable, Sendable, CaseIterable {
    /// A person is on the other end right now.
    case human
    /// Another agent — a group member turn, an A2A relay.
    case agent
    /// A background completion woke the loop (subagent, shell, A2A notice).
    case async
    /// A schedule/routine fired.
    case schedule
    case unknown

    /// Derive from what the ViewModel already tracks.
    ///
    /// Order matters: `isNoticeDriven` wins over `sessionSource`, because a
    /// notice-driven revival of a "user" session is still not a turn the user
    /// opened — treating it as human is exactly the mistake that would make a
    /// reply-first rule fire on every background completion.
    public static func derive(
        sessionSource: String?,
        isNoticeDriven: Bool,
        isExecutor: Bool = false
    ) -> TurnWakeSource {
        if isNoticeDriven { return .async }
        switch sessionSource {
        case "group", "a2a": return .agent
        case "schedule", "routine", "cron": return .schedule
        case "user", "hardware", "siri", "shortcut", "cli", "debug", nil: 
            // A subagent's own loop is never a person's turn, whatever session
            // source it inherited from the agent that dispatched it.
            return isExecutor ? .agent : .human
        default:
            return .unknown
        }
    }
}

// MARK: - Context

/// Everything a handler is allowed to look at.
///
/// Deliberately flat and value-typed: a handler cannot reach into the
/// ViewModel, so a bad hook can misjudge but cannot corrupt a running turn.
public struct HookContext: Sendable, Equatable {
    public let event: HookEvent
    public let sessionID: String
    public let agentID: String?
    public let wakeSource: TurnWakeSource
    /// Raw `vm.sessionSource`, kept alongside `wakeSource` so a binding can
    /// match something narrower than the five buckets.
    public let sessionSource: String?
    /// 0-based agent-loop iteration within this turn.
    public let round: Int
    /// Tool names already invoked this turn, in call order. A rule about "the
    /// first tool" or "did it ever publish" reads this rather than needing its
    /// own bespoke counter threaded through the loop.
    public let toolCallsThisTurn: [String]
    /// `willRunTool` / `didRunTool`.
    public let toolName: String?
    /// `willRunTool` / `didRunTool`, JSON object.
    public let toolArgsJSON: String?
    /// `willRunTool` / `didRunTool`: 0-based index of this call within the turn.
    /// Exact for sequential calls. When a model emits several tool calls in one
    /// response the loop runs them concurrently, so within that batch the index
    /// is arrival order, not the order the model wrote them.
    public let toolCallIndexInTurn: Int?
    /// `didRunTool`.
    public let toolDidSucceed: Bool?
    /// `toolsWillBeSent`: names about to be exposed this round.
    public let availableTools: [String]
    /// `turnWillEnd`: the assistant text this turn produced, if any.
    public let assistantText: String?

    public init(
        event: HookEvent,
        sessionID: String,
        agentID: String? = nil,
        wakeSource: TurnWakeSource = .unknown,
        sessionSource: String? = nil,
        round: Int = 0,
        toolCallsThisTurn: [String] = [],
        toolName: String? = nil,
        toolArgsJSON: String? = nil,
        toolCallIndexInTurn: Int? = nil,
        toolDidSucceed: Bool? = nil,
        availableTools: [String] = [],
        assistantText: String? = nil
    ) {
        self.event = event
        self.sessionID = sessionID
        self.agentID = agentID
        self.wakeSource = wakeSource
        self.sessionSource = sessionSource
        self.round = round
        self.toolCallsThisTurn = toolCallsThisTurn
        self.toolName = toolName
        self.toolArgsJSON = toolArgsJSON
        self.toolCallIndexInTurn = toolCallIndexInTurn
        self.toolDidSucceed = toolDidSucceed
        self.availableTools = availableTools
        self.assistantText = assistantText
    }
}

// MARK: - Params

/// A JSON scalar/array/object, so a binding's `params` survive `Codable` and
/// `Sendable` without an `[String: Any]` escape hatch.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// Typed reads over a binding's `params`. Every accessor takes a default: a
/// handler must stay usable when a hand-edited config omits a key.
public struct HookParams: Codable, Sendable, Equatable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) { self.values = values }

    public init(from decoder: Decoder) throws {
        values = try [String: JSONValue](from: decoder)
    }

    public func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }

    public func string(_ key: String, default fallback: String = "") -> String {
        if case .string(let v)? = values[key] { return v }
        return fallback
    }

    public func bool(_ key: String, default fallback: Bool = false) -> Bool {
        if case .bool(let v)? = values[key] { return v }
        return fallback
    }

    public func int(_ key: String, default fallback: Int = 0) -> Int {
        if case .number(let v)? = values[key] { return Int(v) }
        return fallback
    }

    public func stringArray(_ key: String, default fallback: [String] = []) -> [String] {
        guard case .array(let items)? = values[key] else { return fallback }
        return items.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }
}

// MARK: - Binding

/// Conditions under which a binding runs. A nil field means "don't care";
/// a present field must contain the context's value.
public struct HookMatch: Codable, Sendable, Equatable {
    public var wakeSource: [TurnWakeSource]?
    public var agentID: [String]?
    public var toolName: [String]?
    public var sessionSource: [String]?

    public init(
        wakeSource: [TurnWakeSource]? = nil,
        agentID: [String]? = nil,
        toolName: [String]? = nil,
        sessionSource: [String]? = nil
    ) {
        self.wakeSource = wakeSource
        self.agentID = agentID
        self.toolName = toolName
        self.sessionSource = sessionSource
    }

    private enum CodingKeys: String, CodingKey {
        case wakeSource, toolName, sessionSource
        case agentID = "agentId"
    }

    public func matches(_ context: HookContext) -> Bool {
        if let wakeSource, !wakeSource.contains(context.wakeSource) { return false }
        if let agentID {
            guard let id = context.agentID, agentID.contains(id) else { return false }
        }
        if let toolName {
            guard let name = context.toolName, toolName.contains(name) else { return false }
        }
        if let sessionSource {
            guard let source = context.sessionSource, sessionSource.contains(source) else { return false }
        }
        return true
    }
}

/// One declared rule: which handler runs, at which event, under what conditions.
public struct HookBinding: Codable, Sendable, Equatable, Identifiable {
    /// Stable across scopes — a narrower scope reusing an id replaces the
    /// broader one, which is how an agent switches off a global rule.
    public var id: String
    public var handler: String
    public var event: HookEvent
    public var enabled: Bool
    public var match: HookMatch
    public var params: HookParams
    /// Ascending. Ties break on scope, then declaration order.
    public var order: Int
    /// How many times this binding may force an extra round in one turn.
    public var maxContinuesPerTurn: Int

    public init(
        id: String,
        handler: String,
        event: HookEvent,
        enabled: Bool = true,
        match: HookMatch = HookMatch(),
        params: HookParams = HookParams(),
        order: Int = 100,
        maxContinuesPerTurn: Int = 1
    ) {
        self.id = id
        self.handler = handler
        self.event = event
        self.enabled = enabled
        self.match = match
        self.params = params
        self.order = order
        self.maxContinuesPerTurn = maxContinuesPerTurn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        handler = try c.decode(String.self, forKey: .handler)
        event = try c.decode(HookEvent.self, forKey: .event)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        match = try c.decodeIfPresent(HookMatch.self, forKey: .match) ?? HookMatch()
        params = try c.decodeIfPresent(HookParams.self, forKey: .params) ?? HookParams()
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 100
        maxContinuesPerTurn = try c.decodeIfPresent(Int.self, forKey: .maxContinuesPerTurn) ?? 1
    }
}

/// The three layers, narrowest last.
public enum HookScope: String, Codable, Sendable, CaseIterable {
    case global
    case agent
    case session
}

/// One layer's file contents.
public struct HookConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var bindings: [HookBinding]

    public init(version: Int = 1, bindings: [HookBinding] = []) {
        self.version = version
        self.bindings = bindings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        bindings = try c.decodeIfPresent([HookBinding].self, forKey: .bindings) ?? []
    }

    public static let empty = HookConfig()
}

/// A binding paired with the layer it came from — the UI shows this so a user
/// can tell why a rule they cannot find in session settings is still running.
public struct ResolvedHookBinding: Sendable, Equatable, Identifiable {
    public let binding: HookBinding
    public let scope: HookScope

    public var id: String { binding.id }

    public init(binding: HookBinding, scope: HookScope) {
        self.binding = binding
        self.scope = scope
    }
}
