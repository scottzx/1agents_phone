//
//  BackgroundRunOutcome.swift
//  Minis
//
//  How a background run actually ended.
//
//  `AgentSessionRunResult.timedOut` only ever meant "the awaiter stopped
//  waiting". `AgentTurnAwaiter.awaitTurn` returns on its deadline WITHOUT
//  cancelling the session, so a timed-out result covers two very different
//  worlds: the loop is still working, or it finished in the gap the awaiter
//  missed (an app suspend/resume straddling the deadline does exactly that).
//
//  Reading `timedOut` as "the task died" is what marked finished subagents
//  failed while they went on to succeed — and, because the parent was told
//  "failed", made it dispatch a second subagent onto the same files while the
//  first was still writing them. Both background dispatchers (subagent and
//  direct A2A) classify through here instead of re-deriving it.
//

import Foundation

public enum BackgroundRunOutcome: Equatable {
    /// The turn really ended and left an answer.
    case done(String)
    /// The wait ran out while the loop was genuinely still working. The caller
    /// decides whether it may kill it — legitimate for a scratch session it
    /// owns, never for another agent's main session.
    case stillRunning
    /// The wait ran out, the loop is no longer active, and it left nothing.
    case timedOut
    /// The session refused the dispatch; it never got off the ground.
    case notAccepted
    /// It ran to completion but produced no usable text.
    case producedNothing
}

/// Classify a finished `run()` against the session's live state.
///
/// Only a timeout needs reconciling: every other result already says what
/// happened. Deliberately re-reads `runner.status` rather than trusting the
/// result alone — that second look is the whole point.
@MainActor
public func classifyBackgroundRun(
    result: AgentSessionRunResult,
    runner: any AgentSessionRunning,
    sessionId: String
) async -> BackgroundRunOutcome {
    guard result.accepted else { return .notAccepted }

    if !result.timedOut {
        if let text = result.text, !text.isEmpty { return .done(text) }
        return .producedNothing
    }

    let live = await runner.status(sessionId: sessionId)
    if live.isRunning { return .stillRunning }
    // Not running any more: the turn ended between two poll ticks, or while
    // the app was suspended and the wall-clock deadline kept running. Whatever
    // it left behind is this turn's answer, not a failure.
    if let text = live.lastAssistantText, !text.isEmpty { return .done(text) }
    if let text = result.text, !text.isEmpty { return .done(text) }
    return .timedOut
}
