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

    /// Dispatch times, used to tell "not started yet" from "finished".
    /// SessionActivityTracker only flips to active once the loop is genuinely
    /// under way, so a status() in the gap right after send() would otherwise
    /// look like an instantly-completed task.
    private var dispatchedAt: [String: Date] = [:]
    private static let startupGrace: TimeInterval = 20

    // MARK: - SubagentExecutor

    @discardableResult
    func spawn(_ task: SubagentTask) async throws -> String {
        let vm = ViewModelCache.shared.createDraft()
        vm.sessionSource = "subagent"
        vm.agentId = task.agentId
        // Set before the session exists: send() reads these when it assembles
        // the prompt and the tool set, and a draft VM never runs loadSession()
        // (which is the other place they get resolved).
        vm.agentRole = .executor
        vm.resolvedToolPolicy = .standalone

        let sid = await vm.ensureSessionReturningId()
        guard !sid.isEmpty else { throw SubagentError.sessionUnavailable }

        await ChatStore.shared.linkSession(
            sid,
            agentId: task.agentId,
            role: "subagent",
            parentSessionId: task.parentSessionId,
            spawnTitle: task.title
        )

        // Inherit the parent session's model binding so a task runs on the same
        // model the user picked for the agent, rather than the global default.
        if let parentBinding = ProviderConfigStore.shared.binding(for: task.parentSessionId) {
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(sessionId: sid, primarySource: parentBinding.primarySource),
                for: sid
            )
        }

        ViewModelCache.shared.cacheDraft(vm, sessionId: sid)
        dispatchedAt[sid] = Date()

        vm.inputText = task.prompt
        vm.send()
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

        let isActive = SessionActivityTracker.shared.isActive(taskId)
        let vm = ViewModelCache.shared.get(for: taskId)
        let (activity, iteration) = liveProgress(vm: vm, taskId: taskId)

        if isActive {
            return SubagentStatus(taskId: taskId, title: title, state: .running,
                                  currentActivity: activity, iteration: iteration, result: nil)
        }

        // Not active and still marked running: either it finished (the common
        // case — reconcile now, which also covers a finish that happened while
        // the app was backgrounded) or it never got off the ground.
        let answer = finalAnswer(vm: vm, session: session)
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
        let (vm, isFresh) = ViewModelCache.shared.getOrCreate(for: taskId)
        if isFresh { await vm.loadSession() }
        // Interrupt whatever is in flight but keep the transcript: the point of
        // steering is that the subagent does not start over.
        if vm.isProcessing { vm.cancel() }
        vm.agentRole = .executor
        vm.resolvedToolPolicy = .standalone
        vm.inputText = text
        vm.send()
        dispatchedAt[taskId] = Date()
    }

    func stop(taskId: String) async {
        if let vm = ViewModelCache.shared.get(for: taskId), vm.isProcessing {
            vm.cancel()
        }
        let partial = await ChatStore.shared.getSession(taskId).flatMap {
            finalAnswer(vm: ViewModelCache.shared.get(for: taskId), session: $0)
        }
        await ChatStore.shared.updateSpawnOutcome(taskId, status: "stopped", result: partial)
        dispatchedAt[taskId] = nil
    }

    // MARK: - Progress extraction

    /// Live "what is it doing" line. Mirrors the extraction
    /// SessionsOffloadBridge.getSessionStatus already does for `last_tool`.
    private func liveProgress(vm: AIChatViewModel?, taskId: String) -> (String, Int) {
        let iteration = SessionActivityTracker.shared.sessionToolInfo[taskId]?.loopIteration ?? 0
        guard let vm, let lastAssistant = vm.messages.last(where: { $0.role == .assistant }) else {
            return ("", iteration)
        }
        let toolBlock = lastAssistant.blocks.last { block in
            switch block.kind {
            case .text, .thinking, .info: return false
            default: return true
            }
        }
        let activity = toolBlock.map { $0.toolSummary ?? $0.toolDescription } ?? ""
        return (activity, iteration)
    }

    /// The subagent's report: the text of its last assistant turn. Prefers the
    /// live VM (freshest) and falls back to the persisted preview.
    private func finalAnswer(vm: AIChatViewModel?, session: ChatSession) -> String? {
        if let vm, let lastAssistant = vm.messages.last(where: { $0.role == .assistant }) {
            let joined = lastAssistant.blocks
                .filter { $0.kind == .text }
                .map(\.content)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        let fallback = session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (fallback?.isEmpty == false) ? fallback : nil
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

        return """
            Task started.
            task_id: \(taskId)
            title: \(task.title)
            status: running

            It is working in the background now. Call check_subagent with this \
            task_id (use wait_seconds to park until it lands) and deliver the \
            result to the user in this same turn — nothing runs once your turn ends.
            """
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

                Result:
                \(snapshot.result ?? "")

                Deliver this to the user in your own voice now. Summarize it — do \
                not paste raw output — and do not mention subagents or dispatching.
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
