//
//  SubagentTools.swift
//  Minis
//
//  The orchestrator's dispatch surface: spawn a task, check on it, steer it,
//  stop it. These four replace the heavy tools an orchestrator does not get.
//
//  On `wait_seconds` (check_subagent)
//  ---------------------------------
//  iOS has no scheduler and this build has no revival mechanism — when a turn
//  ends, nothing runs until the user speaks again. So a dispatched task has to
//  be collected inside the same turn that dispatched it. `check_subagent`
//  therefore blocks in the tool layer, exactly like `shell_execute`'s existing
//  `delay` parameter does: it parks the agent loop without occupying the iSH
//  shell, so the subagent keeps running at full speed while its parent waits.
//  The parent chains delay-then-check calls until the task lands, well within
//  the 200-iteration `maxAgentTurns` ceiling.
//

import Foundation

enum SubagentTools {

    static let names: Set<String> = [
        "spawn_subagent", "check_subagent", "message_subagent", "stop_subagent",
    ]

    /// Upper bound on a single `check_subagent` park, in seconds. Kept well
    /// under the provider request timeout so a long wait can never be mistaken
    /// for a hung stream; the parent simply calls check again.
    static let maxWaitSeconds = 240

    static var definitions: [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "spawn_subagent",
                description: "Hand one self-contained chunk of work to a background subagent, and get back a task_id immediately. The subagent has the full execution toolset (shell, file write/edit, browser) that you do not have — this is how anything beyond conversation actually gets done. It starts with NO context from this conversation, so the prompt you write must carry everything it needs. It can read your memory but cannot write to it, and it has no way to talk to the user: it reports its result back to you, and you deliver it (and save anything durable it found). Files it produces go in /var/minis/shared/tasks/<task_id>/, which you can file_read once it is done — its own workspace is private to it. It runs on the same model as this conversation. By default runs in background asynchronously and notifies you via async_task_notice when complete.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Start market research task', 'Kick off log analysis'). Use the same language as the user."),
                    "task_title": AgentToolParam(type: .string, description: "Short label for this task, shown to the user on the task card (e.g. '查上证指数收盘' / 'Analyze crash logs'). Use the same language as the user."),
                    "prompt": AgentToolParam(type: .string, description: "The full instruction for the subagent. MUST be self-contained: the goal, the specifics, any relevant context from this conversation, explicit success criteria, exactly what to report back, and which files (if any) to leave in its task directory. Never write 'tell the user ...' — the subagent cannot reach the user."),
                    "run_in_background": AgentToolParam(type: .boolean, description: "Whether to run the subagent asynchronously in the background. Defaults to true. When true, returns immediately with task_id and notifies you via async_task_notice when complete; when false, waits for completion in the current turn."),
                ],
                required: ["tool_title", "task_title", "prompt"],
                propertyOrdering: ["tool_title", "task_title", "prompt", "run_in_background"]
            ),
            AgentToolDefinition(
                name: "check_subagent",
                description: "Check on a dispatched task without waiting for it to finish. Use this for a quick read-only status inspection. Pass wait_seconds to park and poll if needed. Background tasks notify you automatically upon completion, so manual looping is not required.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                    "task_id": AgentToolParam(type: .string, description: "The task_id returned by spawn_subagent."),
                    "wait_seconds": AgentToolParam(type: .integer, description: "Seconds to wait for completion before returning (default 0 = poll and return immediately, max 240)."),
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
