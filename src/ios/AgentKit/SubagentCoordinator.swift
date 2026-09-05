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

        // A terminal state is a claim, not proof. A run whose wait ran out was
        // written `failed` while its loop went right on working, and the old
        // short-circuit here made that verdict permanent — every later check
        // parroted "failed" past a session that had long since delivered. Look
        // at the runtime before believing it. `stopped` is the exception: the
        // user asked for it, so it stands.
        if persisted != "running" {
            if persisted != "stopped" {
                let live = await sessionRunner.status(sessionId: taskId)
                if live.isRunning {
                    // `updateSpawnOutcome` COALESCEs its result argument, so ""
                    // — not nil — is what clears the stale timeout text.
                    await ChatStore.shared.updateSpawnOutcome(taskId, status: "running", result: "")
                    logger.info("reopened task=\(taskId.prefix(8)): marked \(persisted) but its loop is still running")
                    return SubagentStatus(taskId: taskId, title: title, state: .running,
                                          currentActivity: live.currentActivity,
                                          iteration: live.iteration, result: nil)
                }
            }
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
            // The run Task that would normally announce this is gone — the
            // process was killed mid-task, or the finish landed with nobody
            // listening. Reconciling here without posting left tasks that had
            // completed perfectly well never mentioned to their parent at all.
            await postTerminalNotice(taskId: taskId, session: session,
                                     generation: runGenerations[taskId],
                                     status: "done", result: answer)
            return SubagentStatus(taskId: taskId, title: title, state: .done,
                                  currentActivity: "", iteration: iteration, result: answer)
        }

        let started = dispatchedAt[taskId] ?? session.createdAt
        if Date().timeIntervalSince(started) > Self.startupGrace {
            let reason = String(localized: "子任务没有产生任何结果就结束了。")
            await ChatStore.shared.updateSpawnOutcome(taskId, status: "failed", result: reason)
            dispatchedAt[taskId] = nil
            await postTerminalNotice(taskId: taskId, session: session,
                                     generation: runGenerations[taskId],
                                     status: "failed", result: reason)
            return SubagentStatus(taskId: taskId, title: title, state: .failed,
                                  currentActivity: "", iteration: iteration, result: reason)
        }

        // Still inside the startup window — report as running.
        return SubagentStatus(taskId: taskId, title: title, state: .running,
                              currentActivity: activity, iteration: iteration, result: nil)
    }

    func message(taskId: String, text: String) async throws {
        guard let session = await ChatStore.shared.getSession(taskId) else {
            throw SubagentError.taskNotFound(taskId)
        }
        // Deliberately NOT gated on `spawn_status == "running"`. A task wrongly
        // marked failed is exactly the one an orchestrator wants to steer back
        // on track, and the old guard made it unreachable — the only recovery
        // left was spawning a second subagent onto the same files. Only an
        // explicit stop is final.
        guard session.spawnStatus != "stopped" else {
            throw SubagentError.notRunning(taskId)
        }
        sessionRunner.cancel(sessionId: taskId)
        await ChatStore.shared.updateSpawnOutcome(taskId, status: "running", result: "")
        dispatchedAt[taskId] = Date()
        startRun(sessionId: taskId, prompt: text)
    }

    @discardableResult
    func stop(taskId: String) async -> Bool {
        guard let session = await ChatStore.shared.getSession(taskId) else { return false }
        let persisted = session.spawnStatus ?? "running"
        let live = await sessionRunner.status(sessionId: taskId)
        // The old guard was `spawn_status == "running"`, which made a task that
        // had been wrongly written off unkillable — the one case where stopping
        // matters most, since it is still burning tokens and touching files.
        // Stop anything the runtime says is alive, whatever the row claims. A
        // task that is genuinely over keeps the outcome it earned.
        guard persisted == "running" || live.isRunning else { return false }

        let generation = runGenerations[taskId]
        sessionRunner.cancel(sessionId: taskId)
        runTasks.removeValue(forKey: taskId)?.cancel()
        runGenerations.removeValue(forKey: taskId)
        let partial = live.lastAssistantText
        await ChatStore.shared.updateSpawnOutcome(taskId, status: "stopped", result: partial)
        await postTerminalNotice(taskId: taskId, session: session, generation: generation,
                                 status: "stopped",
                                 result: partial ?? String(localized: "任务已被终止。"))
        dispatchedAt[taskId] = nil
        return true
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
                timeoutSeconds: TimeInterval(SubagentTools.maxRunSeconds)
            ))
            guard runGenerations[sessionId] == generation else { return }
            runTasks[sessionId] = nil
            runGenerations[sessionId] = nil
            dispatchedAt[sessionId] = nil
            if result.cancelled { return }

            // `result.timedOut` says the awaiter stopped waiting, nothing more.
            // Taking it for death is what buried finished tasks under "failed".
            let session = await ChatStore.shared.getSession(sessionId)
            let persistedStatus: String
            let noticeStatus: String
            let resultText: String

            switch await classifyBackgroundRun(result: result, runner: sessionRunner, sessionId: sessionId) {
            case .done(let text):
                persistedStatus = "done"
                noticeStatus = "done"
                resultText = text
            case .stillRunning:
                // Now the bound means something: still going after
                // `maxRunSeconds`, which at that length reads as stuck rather
                // than busy. Cancel it for real so the state we report is true,
                // and keep whatever it managed to produce.
                sessionRunner.cancel(sessionId: sessionId)
                let partial = await sessionRunner.status(sessionId: sessionId).lastAssistantText
                persistedStatus = "failed"
                noticeStatus = "timed_out"
                resultText = partial ?? String(localized: "子任务执行超时。")
            case .timedOut:
                persistedStatus = "failed"
                noticeStatus = "timed_out"
                resultText = String(localized: "子任务执行超时。")
            case .notAccepted, .producedNothing:
                persistedStatus = "failed"
                noticeStatus = "failed"
                resultText = String(localized: "子任务没有产生任何结果就结束了。")
            }

            await ChatStore.shared.updateSpawnOutcome(sessionId, status: persistedStatus, result: resultText)
            await postTerminalNotice(taskId: sessionId, session: session, generation: generation,
                                     status: noticeStatus, result: resultText)
        }
    }

    /// Announce a task's terminal state to its parent.
    ///
    /// The parent, agent and title come from the in-memory dispatch record
    /// first and the session row second. That fallback is what makes this
    /// survive a relaunch: `tasks` is memory-only, so anything reconciled after
    /// a restart used to find no parent and post nothing at all — the task
    /// finished, and nobody was ever told.
    ///
    /// Re-posting is safe: `AsyncTaskNoticeManager` drops a notice id it has
    /// already delivered, so whichever path gets there first wins and the
    /// others are no-ops.
    private func postTerminalNotice(
        taskId: String,
        session: ChatSession?,
        generation: UUID?,
        status: String,
        result: String
    ) async {
        let info = tasks[taskId]
        let parentSessionId = info?.parentSessionId ?? session?.parentSessionId ?? ""
        guard !parentSessionId.isEmpty else {
            logger.warning("task=\(taskId.prefix(8)) has no parent session; terminal notice dropped")
            return
        }
        await AsyncTaskNoticeManager.shared.postNotice(
            sourceSessionId: parentSessionId,
            taskType: "subagent",
            taskId: taskId,
            agentId: info?.agentId ?? session?.agentId,
            title: info?.title ?? session?.spawnTitle,
            status: status,
            result: result,
            filesPath: OrchestratorPrompt.taskDeliveryDir(taskId: taskId),
            noticeId: Self.noticeId(taskId: taskId, generation: generation)
        )
    }

    private static func noticeId(taskId: String, generation: UUID?) -> String {
        "async:subagent:\(taskId):\(generation?.uuidString ?? "terminal")"
    }

}

// MARK: - Coordinator

/// Bridges the four dispatch tools to an executor and formats what the model
/// sees back. Kept separate from the executor so the tool contract does not
/// change when a remote executor is added.
@MainActor
final class SubagentCoordinator {
    static let shared = SubagentCoordinator()

    private let executor: SubagentExecutor

    init(executor: SubagentExecutor) {
        self.executor = executor
    }

    convenience init() {
        self.init(executor: RoutingSubagentExecutor())
    }

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
            return await handleSpawn(input: input, parentSessionId: parentSessionId, agentId: agentId, forceTarget: .local)
        case "spawn_cloud_subagent":
            return await handleSpawn(input: input, parentSessionId: parentSessionId, agentId: agentId, forceTarget: .cloud)
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

    private func handleSpawn(
        input: [String: Any],
        parentSessionId: String,
        agentId: String?,
        forceTarget: SubagentTask.Target? = nil
    ) async -> String {
        let title = (input["task_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = (input["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            return "Error: `prompt` is required and must describe the task in full. The subagent starts with no context."
        }

        let target: SubagentTask.Target
        if let forceTarget {
            target = forceTarget
        } else {
            let targetRaw = (input["target"] as? String)?.lowercased() ?? "auto"
            target = SubagentTask.Target(rawValue: targetRaw) ?? .auto
        }
        let actorId = (input["actor_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let task = SubagentTask(
            id: "",
            parentSessionId: parentSessionId,
            agentId: agentId ?? AgentProfile.defaultAgentId,
            title: title.isEmpty ? String(localized: "后台任务") : title,
            prompt: prompt,
            createdAt: Date(),
            target: target,
            actorId: (actorId?.isEmpty == false) ? actorId : nil
        )

        let taskId: String
        do {
            taskId = try await executor.spawn(task)
        } catch {
            return "Failed to start the task: \(error.localizedDescription)"
        }

        return """
            Task started.
            task_id: \(taskId)
            agent_id: \(task.agentId)
            title: \(task.title)
            target: \(task.target.rawValue)
            status: running
            files: \(OrchestratorPrompt.taskDeliveryDir(taskId: taskId))/

            It is working in the background now. You will be automatically notified via async_task_notice when it finishes. Any files it produces land in the directory above, which you can file_read. You may end your turn now.
            """
    }

    private func handleCheck(input: [String: Any]) async -> String {
        guard let taskId = input["task_id"] as? String, !taskId.isEmpty else {
            return "Error: `task_id` is required."
        }
        // Legacy callers may still send wait_seconds. It is accepted and
        // ignored so this manual status query never parks the parent turn.
        let snapshot = await executor.status(taskId: taskId)

        switch snapshot.state {
        case .unknown:
            return "No task with id \(taskId). Check the task_id returned by spawn_subagent."
        case .running:
            var lines = ["task_id: \(taskId)", "title: \(snapshot.title)", "status: running"]
            if !snapshot.currentActivity.isEmpty { lines.append("currently: \(snapshot.currentActivity)") }
            if snapshot.iteration > 0 { lines.append("steps so far: \(snapshot.iteration)") }
            lines.append("")
            lines.append("Still working. Completion will arrive automatically through async_task_notice; no polling loop is required.")
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
            return "Instruction delivered to task \(taskId); it kept its context and is working on it. Completion will be reported automatically."
        } catch {
            return "Could not steer task \(taskId): \(error.localizedDescription)"
        }
    }

    private func handleStop(input: [String: Any]) async -> String {
        guard let taskId = input["task_id"] as? String, !taskId.isEmpty else {
            return "Error: `task_id` is required."
        }
        guard await executor.stop(taskId: taskId) else {
            let snapshot = await executor.status(taskId: taskId)
            if snapshot.state == .unknown {
                return "No task with id \(taskId). Check the task_id returned by spawn_subagent."
            }
            return """
                Task \(taskId) was already \(snapshot.state.rawValue) — there was nothing \
                left to stop. Its result stands as it is; do not report it as cancelled.
                """
        }
        return "Task \(taskId) stopped. Whatever it produced is kept, but it will not continue."
    }

    /// Reconcile subagent sessions still marked `running` with no live run
    /// behind them — the residue of a process killed mid-task.
    ///
    /// `status(taskId:)` does the work: it writes the real outcome and posts the
    /// notice the dead run never got to post. Without this, a task that finished
    /// while the app was gone stayed `running` forever and its parent was never
    /// told, unless the orchestrator happened to check on it by hand.
    func recoverOrphanedTasks() async {
        let orphans = await ChatStore.shared.runningSubagentSessions()
        for session in orphans {
            _ = await executor.status(taskId: session.id)
        }
    }
}
