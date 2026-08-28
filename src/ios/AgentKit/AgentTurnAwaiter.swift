//
//  AgentTurnAwaiter.swift
//  Minis
//
//  Park until another session's turn lands, then read what it said.
//
//  Both of these started life as private helpers inside
//  AgentDirectoryCoordinator, where they backed `send_agent_message`'s
//  `wait_seconds`. Group chat needs exactly the same two operations for every
//  member turn, and a second copy of "poll isProcessing, then join the text
//  blocks of the last assistant message" is the kind of duplication that drifts
//  — so they live here and both callers share them.
//

import Foundation

@MainActor
enum AgentTurnAwaiter {

    /// Park until `vm` finishes its turn or `seconds` elapse.
    /// Returns false when the wait ran out with the turn still going.
    ///
    /// One-second granularity on purpose: the caller is suspended inside a tool
    /// call or an orchestration step for the whole wait, so a tighter poll buys
    /// nothing and a looser one adds latency to short turns.
    static func awaitTurn(vm: AIChatViewModel, seconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, seconds)))
        while vm.isProcessing && Date() < deadline {
            if Task.isCancelled { return false }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return false }
        }
        return !vm.isProcessing
    }

    /// The text of the assistant turn that followed message index `after`.
    ///
    /// Bounded by `after` so a stalled turn cannot hand back the answer to
    /// whatever was asked previously — the failure mode that makes a silent
    /// timeout look like a real reply.
    static func lastAssistantText(vm: AIChatViewModel, after index: Int) -> String? {
        guard index <= vm.messages.count else { return nil }
        let fresh = vm.messages.suffix(from: min(index, vm.messages.count))
        guard let last = fresh.last(where: { $0.role == .assistant }) else { return nil }
        let joined = last.blocks
            .filter { $0.kind == .text }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
