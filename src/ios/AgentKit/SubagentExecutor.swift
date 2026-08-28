//
//  SubagentExecutor.swift
//  Minis
//
//  Where a dispatched task actually runs.
//
//  Today there is exactly one implementation — `LocalSubagentExecutor`, which
//  runs the task on this iPhone in a scratch session backed by the on-device
//  iSH runtime. The protocol exists so a remote executor (running the same
//  task on a TiDB Agent Stack worker, or on the user's Mac through
//  1agents_server) can be added without the coordinator, the tools, or the
//  task-card UI knowing the difference. Nothing remote is implemented yet and
//  the local runtime is the intended default regardless.
//

import Foundation

/// One dispatched unit of work. `id` IS the scratch session's id — the task
/// and its transcript are the same object, so a task card can push straight
/// into the session with no separate mapping table.
struct SubagentTask: Identifiable, Hashable {
    let id: String
    let parentSessionId: String
    let agentId: String
    let title: String
    let prompt: String
    let createdAt: Date
}

/// A snapshot of a task, as the orchestrator sees it.
struct SubagentStatus {
    enum State: String {
        case running, done, failed, stopped, unknown
    }

    let taskId: String
    let title: String
    let state: State
    /// What the subagent is doing right now, e.g. "browser_use 抓取页面".
    let currentActivity: String
    /// Agent-loop iterations burned so far. A number that stops moving across
    /// checks is the signal for a stalled task.
    let iteration: Int
    /// The final answer, once the task reached a terminal state.
    let result: String?

    var isTerminal: Bool { state != .running }
}

@MainActor
protocol SubagentExecutor {
    /// Start the task and return the scratch session's id — which is also
    /// the task id. Returns as soon as it is dispatched, never blocking until
    /// completion.
    @discardableResult
    func spawn(_ task: SubagentTask) async throws -> String
    /// Current snapshot. Cheap; safe to call in a poll loop.
    func status(taskId: String) async -> SubagentStatus
    /// Park until the task reaches a terminal state or `seconds` elapse.
    /// Returns the status either way.
    func wait(taskId: String, seconds: Int) async -> SubagentStatus
    /// Push a new instruction into a running task, keeping its context.
    func message(taskId: String, text: String) async throws
    /// Abort for good.
    func stop(taskId: String) async
}

enum SubagentError: LocalizedError {
    case taskNotFound(String)
    case sessionUnavailable
    case notRunning(String)

    var errorDescription: String? {
        switch self {
        case .taskNotFound(let id): return "No task with id \(id)."
        case .sessionUnavailable: return "Could not create a session for the task."
        case .notRunning(let id): return "Task \(id) is not running any more."
        }
    }
}
