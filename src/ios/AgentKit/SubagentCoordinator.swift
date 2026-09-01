//
//  SubagentCoordinator.swift
//  Minis
//
//  Turns the orchestrator's four dispatch tools into real work.
//
//  The runtime shape is lifted straight from SessionsOffloadBridge.sendPrompt,
//  which has been running headless sessions in this app for a while: create a
//  draft VM, give it a session, set the prompt, call send(), return
//  immediately. The differences are that the scratch session is stamped with
//  its parent and role, that the VM is put in `.executor` mode before it runs
//  (full toolset, executor prompt), and that its terminal state is written
//  back so the parent's task card and `check_subagent` agree on what happened.
//

import Foundation

@MainActor
final class LocalSubagentExecutor: SubagentExecutor {

    private let logger = AppLogger(category: "Subagent")
    private let sessionRunner: any AgentSessionRunning
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var runGenerations: [String: UUID] = [:]
    private var tasks: [String: SubagentTask] = [:]

    /// Dispatch times, used to tell "not started yet" from "finished".
    /// SessionActivityTracker only flips to active once the loop is genuinely
    /// under way, so a status() in the gap right after send() would otherwise
    /// look like an instantly-completed task.
    private var dispatchedAt: [String: Date] = [:]
    private static let startupGrace: TimeInterval = 20

    init(sessionRunner: any AgentSessionRunning = IOSAgentSessionRunner.shared) {
        self.sessionRunner = sessionRunner
    }

    // MARK: - SubagentExecutor

    @discardableResult
    func spawn(_ task: SubagentTask) async throws -> String {
        guard let sid = await sessionRunner.createSession(AgentSessionCreateRequest(
            agentId: task.agentId,
            parentSessionId: task.parentSessionId,
            source: "subagent",
            role: "subagent",
            spawnTitle: task.title,
            toolPolicy: AgentToolPolicy.standalone.rawValue,
            inheritModelFromSessionId: task.parentSessionId
        )), !sid.isEmpty else { throw SubagentError.sessionUnavailable }
        tasks[sid] = SubagentTask(
            id: sid,
            parentSessionId: task.parentSessionId,
            agentId: task.agentId,
            title: task.title,
            prompt: task.prompt,
            createdAt: task.createdAt
        )
        dispatchedAt[sid] = Date()
        startRun(sessionId: sid, prompt: task.prompt)
        logger.info("spawned subagent task=\(sid.prefix(8)) parent=\(task.parentSessionId.prefix(8))")
        return sid
    }

    func status(taskId: String) async -> SubagentStatus {
        guard let session = await ChatStore.shared.getSession(taskId) else {
            return SubagentStatus(taskId: taskId, title: "", state: .unknown,
                                  currentActivity: "", iteration: 0, result: nil)
        }

        let title = session.spawnTitle ?? session.title ?? ""
        let persisted = session.spawnStatus ?? "running"

        // Terminal state already written — nothing to reconcile.
        if persisted != "running" {
            return SubagentStatus(
                taskId: taskId, title: title,
                state: SubagentStatus.State(rawValue: persisted) ?? .unknown,
                currentActivity: "", iteration: 0,
                result: session.spawnResult
            )
        }

        let runtimeStatus = await sessionRunner.status(sessionId: taskId)
        let activity = runtimeStatus.currentActivity
        let iteration = runtimeStatus.iteration

        if runtimeStatus.isRunning {
            return SubagentStatus(taskId: taskId, title: title, state: .running,
                                  currentActivity: activity, iteration: iteration, result: nil)
        }

        // Not active and still marked running: either it finished (the common
        // case — reconcile now, which also covers a finish that happened while
        // the app was backgrounded) or it never got off the ground.
        let answer = runtimeStatus.lastAssistantText ?? session.lastMessage
        if let answer, !answer.isEmpty {
            await ChatStore.shared.updateSpawnOutcome(taskId, status: "done", result: answer)
            dispatchedAt[taskId] = nil
            return SubagentStatus(taskId: taskId, title: title, state: .done,
                                  currentActivity: "", iteration: iteration, result: answer)
        }

        let started = dispatchedAt[taskId] ?? session.createdAt
        if Date().timeIntervalSince(started) > Self.startupGrace {
            let reason = String(localized: "子任务没有产生任何结果就结束了。")
            await ChatStore.shared.updateSpawnOutcome(taskId, status: "failed", result: reason)
            dispatchedAt[taskId] = nil
            return SubagentStatus(taskId: taskId, title: title, state: .failed,
                                  currentActivity: "", iteration: iteration, result: reason)
        }

        // Still inside the startup window — report as running.
        return SubagentStatus(taskId: taskId, title: title, state: .running,
                              currentActivity: activity, iteration: iteration, result: nil)
    }

    /// Park the caller until the task lands or `seconds` elapse.
    ///
    /// The parent's agent loop is suspended inside its tool call for the whole
    /// wait, which means it keeps its SessionConcurrencyManager slot (5 total).
    /// Parent + subagent is 2 of 5, so a normal dispatch has room; only a user
    /// with several conversations running at once could see a subagent queue
    /// behind a parked parent, and that resolves when the wait expires rather
    /// than deadlocking.
    func wait(taskId: String, seconds: Int) async -> SubagentStatus {
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, seconds)))
        var snapshot = await status(taskId: taskId)
        while !snapshot.isTerminal && Date() < deadline {
            // Cancellation (the user tapping Stop on the parent) must break the
            // park. Task.sleep throws on cancel, and swallowing that with `try?`
            // would spin this loop at full speed until the deadline.
            if Task.isCancelled { break }
            do {
                // 1s granularity: the parent turn is parked here, so a tighter
                // poll buys nothing and a looser one adds latency to short tasks.
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                break
            }
            snapshot = await status(taskId: taskId)
        }
        return snapshot
    }

    func message(taskId: String, text: String) async throws {
        guard let session = await ChatStore.shared.getSession(taskId),
              session.spawnStatus == "running" else {
            throw SubagentError.notRunning(taskId)
        }
        sessionRunner.cancel(sessionId: taskId)
        dispatchedAt[taskId] = Date()
        startRun(sessionId: taskId, prompt: text)
    }

    func stop(taskId: String) async {
        sessionRunner.cancel(sessionId: taskId)
        runTasks.removeValue(forKey: taskId)?.cancel()
        runGenerations.removeValue(forKey: taskId)
        let partial = await sessionRunner.status(sessionId: taskId).lastAssistantText
        await ChatStore.shared.updateSpawnOutcome(taskId, status: "stopped", result: partial)
        if let parentSessionId = tasks[taskId]?.parentSessionId, !parentSessionId.isEmpty {
            await AsyncTaskNoticeManager.shared.postNotice(
                sourceSessionId: parentSessionId,
                taskType: "subagent",
                taskId: taskId,
                title: tasks[taskId]?.title,
                status: "stopped",
                result: partial ?? String(localized: "任务已被终止。"),
                filesPath: OrchestratorPrompt.taskDeliveryDir(taskId: taskId)
            )
        }
        dispatchedAt[taskId] = nil
    }

    private func startRun(sessionId: String, prompt: String) {
        runTasks.removeValue(forKey: sessionId)?.cancel()
        let generation = UUID()
        runGenerations[sessionId] = generation
        runTasks[sessionId] = Task { [weak self] in
            guard let self else { return }
            let result = await sessionRunner.run(AgentSessionRunRequest(
                sessionId: sessionId,
                prompt: prompt,
                source: "subagent",
                role: AgentRunRole.executor.rawValue,
                toolPolicy: AgentToolPolicy.standalone.rawValue,
                timeoutSeconds: TimeInterval(SubagentTools.maxWaitSeconds)
            ))
            guard runGenerations[sessionId] == generation else { return }
            runTasks[sessionId] = nil
            runGenerations[sessionId] = nil
            dispatchedAt[sessionId] = nil
            if result.cancelled { return }

            let taskInfo = tasks[sessionId]
            let parentSessionId = taskInfo?.parentSessionId
            let taskTitle = taskInfo?.title
            let filesDir = OrchestratorPrompt.taskDeliveryDir(taskId: sessionId)

            let statusStr: String
            let resultText: String
            if result.accepted, !result.timedOut, let text = result.text, !text.isEmpty {
                statusStr = "done"
                resultText = text
                await ChatStore.shared.updateSpawnOutcome(sessionId, status: "done", result: text)
            } else {
                statusStr = "failed"
                resultText = result.timedOut
                    ? String(localized: "子任务执行超时。")
                    : String(localized: "子任务没有产生任何结果就结束了。")
                await ChatStore.shared.updateSpawnOutcome(sessionId, status: "failed", result: resultText)
            }

            if let parentSessionId, !parentSessionId.isEmpty {
                await AsyncTaskNoticeManager.shared.postNotice(
                    sourceSessionId: parentSessionId,
                    taskType: "subagent",
                    taskId: sessionId,
                    title: taskTitle,
                    status: statusStr,
                    result: resultText,
                    filesPath: filesDir
                )
            }
        }
    }

}

// MARK: - Coordinator

/// Bridges the four dispatch tools to an executor and formats what the model
/// sees back. Kept separate from the executor so the tool contract does not
/// change when a remote executor is added.
@MainActor
final class SubagentCoordinator {
    static let shared = SubagentCoordinator()

    private let executor: SubagentExecutor = LocalSubagentExecutor()

    private init() {}

    /// Handle one dispatch tool call. Returns the text handed back to the
    /// model as the tool result.
    func handle(
        toolName: String,
        input: [String: Any],
        parentSessionId: String,
        agentId: String?
    ) async -> String {
        switch toolName {
        case "spawn_subagent":
            return await handleSpawn(input: input, parentSessionId: parentSessionId, agentId: agentId)
        case "check_subagent":
            return await handleCheck(input: input)
        case "message_subagent":
            return await handleMessage(input: input)
        case "stop_subagent":
            return await handleStop(input: input)
        default:
            return "Unknown subagent tool: \(toolName)"
        }
    }

    private func handleSpawn(input: [String: Any], parentSessionId: String, agentId: String?) async -> String {
        let title = (input["task_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = (input["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let runInBackground = (input["run_in_background"] as? Bool) ?? true
        guard !prompt.isEmpty else {
            return "Error: `prompt` is required and must describe the task in full. The subagent starts with no context."
        }

        let task = SubagentTask(
            id: "",
            parentSessionId: parentSessionId,
            agentId: agentId ?? AgentProfile.defaultAgentId,
            title: title.isEmpty ? String(localized: "后台任务") : title,
            prompt: prompt,
            createdAt: Date()
        )

        let taskId: String
        do {
            taskId = try await executor.spawn(task)
        } catch {
            return "Failed to start the task: \(error.localizedDescription)"
        }

        if runInBackground {
            return """
                Task started.
                task_id: \(taskId)
                title: \(task.title)
                status: running
                files: \(OrchestratorPrompt.taskDeliveryDir(taskId: taskId))/

                It is working in the background now. You will be automatically notified via async_task_notice when it finishes. Any files it produces land in the directory above, which you can file_read. You may end your turn now.
                """
        } else {
            let snapshot = await executor.wait(taskId: taskId, seconds: 30)
            if snapshot.isTerminal {
                return """
                    task_id: \(taskId)
                    title: \(task.title)
                    status: \(snapshot.state.rawValue)
                    files: \(OrchestratorPrompt.taskDeliveryDir(taskId: taskId))/

                    Result:
                    \(snapshot.result ?? "")
                    """
            } else {
                return """
                    Task started.
                    task_id: \(taskId)
                    title: \(task.title)
                    status: running
                    files: \(OrchestratorPrompt.taskDeliveryDir(taskId: taskId))/

                    The task is still running after 30 seconds and has been moved to the background. You will be automatically notified via async_task_notice when it finishes.
                    """
            }
        }
    }

    private func handleCheck(input: [String: Any]) async -> String {
        guard let taskId = input["task_id"] as? String, !taskId.isEmpty else {
            return "Error: `task_id` is required."
        }
        let waitSeconds = min(
            max((input["wait_seconds"] as? Int) ?? 0, 0),
            SubagentTools.maxWaitSeconds
        )

        let snapshot = waitSeconds > 0
            ? await executor.wait(taskId: taskId, seconds: waitSeconds)
            : await executor.status(taskId: taskId)

        switch snapshot.state {
        case .unknown:
            return "No task with id \(taskId). Check the task_id returned by spawn_subagent."
        case .running:
            var lines = ["task_id: \(taskId)", "title: \(snapshot.title)", "status: running"]
            if !snapshot.currentActivity.isEmpty { lines.append("currently: \(snapshot.currentActivity)") }
            if snapshot.iteration > 0 { lines.append("steps so far: \(snapshot.iteration)") }
            lines.append("")
            lines.append("Still working. Call check_subagent again with a wait_seconds long enough for the remaining work. If the activity and step count have not moved across several checks, it is stuck — stop_subagent and either retry or tell the user plainly.")
            return lines.joined(separator: "\n")
        case .done:
            return """
                task_id: \(taskId)
                title: \(snapshot.title)
                status: done
                files: \(OrchestratorPrompt.taskDeliveryDir(taskId: taskId))/

                Result:
                \(snapshot.result ?? "")

                Deliver this to the user in your own voice now. Summarize it — do \
                not paste raw output — and do not mention subagents or dispatching. \
                Any files it named are in the directory above; link them for the \
                user with minis:// URLs. If it turned up something durable — a \
                preference, a convention, a fact worth having next week — save it \
                with memory_write yourself: the task could not.
                """
        case .failed, .stopped:
            return """
                task_id: \(taskId)
                title: \(snapshot.title)
                status: \(snapshot.state.rawValue)

                \(snapshot.result ?? "")

                Tell the user the real state rather than reporting success, and \
                either retry with a clearer task or explain what is blocked.
                """
        }
    }

    private func handleMessage(input: [String: Any]) async -> String {
        guard let taskId = input["task_id"] as? String, !taskId.isEmpty else {
            return "Error: `task_id` is required."
        }
        guard let text = (input["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return "Error: `message` is required."
        }
        do {
            try await executor.message(taskId: taskId, text: text)
            return "Instruction delivered to task \(taskId); it kept its context and is working on it. Check back with check_subagent."
        } catch {
            return "Could not steer task \(taskId): \(error.localizedDescription)"
        }
    }

    private func handleStop(input: [String: Any]) async -> String {
        guard let taskId = input["task_id"] as? String, !taskId.isEmpty else {
            return "Error: `task_id` is required."
        }
        await executor.stop(taskId: taskId)
        return "Task \(taskId) stopped. Whatever it produced is kept, but it will not continue."
    }
}
