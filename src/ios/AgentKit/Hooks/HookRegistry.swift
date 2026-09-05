//
//  HookRegistry.swift
//  Minis
//
//  handlerID → handler. Config decides which of these run and when.
//
//  This phase registers exactly one handler, and it is deliberately inert:
//  `trace` records that an event fired and returns `.proceed`. It exists so the
//  wiring can be proven end-to-end — every event point reached, in the right
//  order, with the right context — without any rule being in force yet. The
//  rules themselves (reply-first, close-the-loop) are the next change: each is
//  a handler added here plus a binding in config, with no engine edit.
//

import Foundation

private let logger = AppLogger(category: "Hooks")

enum HookRegistry {

    /// Every handler the app knows how to run.
    static let handlers: [any HookHandler] = [
        TraceHookHandler()
    ]

    static func handler(id: String) -> (any HookHandler)? {
        handlers.first { $0.handlerID == id }
    }
}

/// Records that an event fired. Changes nothing.
///
/// Params:
///   - `label` (string): prefix for the log line, so several trace bindings
///     stay distinguishable.
struct TraceHookHandler: HookHandler {
    let handlerID = "trace"
    let events: Set<HookEvent> = Set(HookEvent.allCases)

    func run(_ context: HookContext, params: HookParams) throws -> HookDecision {
        let label = params.string("label", default: "trace")
        var detail = "event=\(context.event.rawValue) wake=\(context.wakeSource.rawValue) round=\(context.round)"
        if let tool = context.toolName {
            detail += " tool=\(tool) index=\(context.toolCallIndexInTurn.map(String.init) ?? "-")"
        }
        if context.event == .toolsWillBeSent {
            detail += " offering=\(context.availableTools.count)"
        }
        if context.event == .turnWillEnd {
            detail += " calls=[\(context.toolCallsThisTurn.joined(separator: ","))]"
        }
        logger.info("[Hooks/\(label)] \(detail)")
        return .proceed
    }
}
