//
//  SubagentTools.swift
//  Minis
//
//  The orchestrator's dispatch surface: spawn a task, check on it, steer it,
//  stop it. These four replace the heavy tools an orchestrator does not get.
//
//  `check_subagent` is a cheap manual status query. Legacy callers may still
//  include `wait_seconds`, but the coordinator ignores it so normal result
//  collection is always driven by async_task_notice.
//

import Foundation

enum SubagentTools {

    static let names: Set<String> = [
        "spawn_subagent", "check_subagent", "message_subagent", "stop_subagent",
    ]

    /// Upper bound on how long the dispatcher keeps waiting for one subagent
    /// turn. NOT a deadline for the work: a subagent writing code and driving a
    /// browser routinely runs many minutes, so reaching this bound is treated
    /// as "still working" unless the runtime agrees the loop has stopped — see
    /// `classifyBackgroundRun`. It does not control check_subagent either;
    /// checks always return immediately.
    static let maxRunSeconds = 1800

    static var definitions: [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "spawn_subagent",
                description: "Hand one self-contained chunk of work to a background subagent, and get back a task_id immediately. The subagent has the full execution toolset (shell, file write/edit, browser) that you do not have — this is how anything beyond conversation actually gets done. It starts with NO context from this conversation, so the prompt you write must carry everything it needs. It can read your memory but cannot write to it, and it has no way to talk to the user: it reports its result back to you, and you deliver it (and save anything durable it found). Files it produces go in /var/minis/shared/tasks/<task_id>/, which you can file_read once it is done — its own workspace is private to it. It runs on the same model as this conversation. It always runs asynchronously and notifies you via async_task_notice when complete.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Start market research task', 'Kick off log analysis'). Use the same language as the user."),
                    "task_title": AgentToolParam(type: .string, description: "Short label for this task, shown to the user on the task card (e.g. '查上证指数收盘' / 'Analyze crash logs'). Use the same language as the user."),
                    "prompt": AgentToolParam(type: .string, description: "The full instruction for the subagent. MUST be self-contained: the goal, the specifics, any relevant context from this conversation, explicit success criteria, exactly what to report back, and which files (if any) to leave in its task directory. Never write 'tell the user ...' — the subagent cannot reach the user."),
                ],
                required: ["tool_title", "task_title", "prompt"],
                propertyOrdering: ["tool_title", "task_title", "prompt"]
            ),
            AgentToolDefinition(
                name: "check_subagent",
                description: "Check on a dispatched task without waiting for it to finish. Use this only for a manual read-only status inspection; completion is reported automatically through async_task_notice.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                    "task_id": AgentToolParam(type: .string, description: "The task_id returned by spawn_subagent."),
                    "wait_seconds": AgentToolParam(type: .integer, description: "Deprecated compatibility field. Accepted but ignored; this tool always returns the current status immediately."),
                ],
                required: ["tool_title", "task_id"],
                propertyOrdering: ["tool_title", "task_id", "wait_seconds"]
            ),
            AgentToolDefinition(
                name: "message_subagent",
                description: "Push a new instruction into a task that is already running, keeping everything it has done so far. Use this to steer, correct or add to work in flight — a follow-up is NOT a reason to spawn a second subagent for the same stream of work.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                    "task_id": AgentToolParam(type: .string, description: "The task_id returned by spawn_subagent."),
                    "message": AgentToolParam(type: .string, description: "The additional instruction. Self-contained, like the original dispatch prompt."),
                ],
                required: ["tool_title", "task_id", "message"],
                propertyOrdering: ["tool_title", "task_id", "message"]
            ),
            AgentToolDefinition(
                name: "stop_subagent",
                description: "Abort a running task for good. Use it when the work is no longer wanted or the task is clearly stuck (same tool repeating, no progress across several checks). Whatever it produced so far is kept and readable, but it will not continue.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                    "task_id": AgentToolParam(type: .string, description: "The task_id returned by spawn_subagent."),
                ],
                required: ["tool_title", "task_id"],
                propertyOrdering: ["tool_title", "task_id"]
            ),
        ]
    }
}
