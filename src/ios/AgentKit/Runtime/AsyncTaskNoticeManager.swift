//
//  AsyncTaskNoticeManager.swift
//  Minis
//
//  Central asynchronous task notice bus.
//  Coordinates background task completion notices (shell commands, subagents,
//  direct A2A, group A2A), manages pending queues in SQLite, injects paired
//  synthetic tool_use / tool_result messages, and reactively revives the agent loop.
//

import Foundation

private let logger = AppLogger(category: "AsyncTaskNotice")

@MainActor
public final class AsyncTaskNoticeManager {

    public static let shared = AsyncTaskNoticeManager()

    public var sessionRunner: any AgentSessionRunning = IOSAgentSessionRunner.shared

    private var loopEndObserver: NSObjectProtocol?
    private var isDraining: Set<String> = []

    public init() {
        setupLoopEndObserver()
    }

    deinit {
        if let observer = loopEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupLoopEndObserver() {
        loopEndObserver = NotificationCenter.default.addObserver(
            forName: .sessionAgentLoopDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let sid = (notification.object as? String)
            Task { @MainActor in
                if let sid {
                    await self.checkAndDrain(sessionId: sid)
                } else if let activeSid = AIChatViewModel.activeSessionId {
                    await self.checkAndDrain(sessionId: activeSid)
                }
            }
        }
    }

    /// Post a completion notice for a background task.
    /// Saves to SQLite queue and attempts to drain immediately if the target session is idle.
    @discardableResult
    public func postNotice(
        sourceSessionId: String,
        taskType: String,
        taskId: String,
        title: String? = nil,
        status: String = "done",
        result: String,
        filesPath: String? = nil,
        noticeId: String? = nil
    ) async -> String {
        let nid = noticeId ?? "notice_\(taskType)_\(taskId)_\(UUID().uuidString.prefix(8))"

        guard await !ChatStore.shared.hasDeliveredNotice(id: nid) else {
            logger.info("[Notice] Notice \(nid) already delivered, skipping duplicate post.")
            return nid
        }

        let notice = AsyncTaskNotice(
            id: nid,
            sourceSessionId: sourceSessionId,
            taskType: taskType,
            taskId: taskId,
            title: title,
            status: status,
            result: result,
            filesPath: filesPath,
            createdAt: Date(),
            isDelivered: false
        )

        await ChatStore.shared.saveAsyncTaskNotice(notice)
        logger.info("[Notice] Saved pending notice \(nid) (type=\(taskType), taskId=\(taskId)) for session \(sourceSessionId)")

        // Trigger drain if session is available
        await checkAndDrain(sessionId: sourceSessionId)
        return nid
    }

    /// Check if the given session is idle and has pending notices, and inject them atomically.
    public func checkAndDrain(sessionId: String) async {
        guard !sessionId.isEmpty else { return }
        guard !isDraining.contains(sessionId) else { return }

        // If the session is currently active or processing, do not inject — wait for loop end
        if SessionActivityTracker.shared.isActive(sessionId) {
            logger.debug("[Notice] Session \(sessionId) is currently active, deferring notice drain.")
            return
        }

        if let vm = ViewModelCache.shared.get(for: sessionId) {
            if vm.isProcessing {
                logger.debug("[Notice] VM for \(sessionId) isProcessing, deferring notice drain.")
                return
            }
            // User queued message has higher priority
            if !vm.promptQueue.isEmpty || !vm.inputText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                logger.debug("[Notice] Session \(sessionId) has pending user input, yielding priority to user.")
                return
            }
        }

        let pending = await ChatStore.shared.pendingAsyncTaskNotices(for: sessionId)
        guard !pending.isEmpty else { return }

        isDraining.insert(sessionId)
        defer { isDraining.remove(sessionId) }

        logger.info("[Notice] Draining \(pending.count) pending notice(s) for session \(sessionId)")

        var toolUses: [ContentPart] = []
        var toolResults: [ContentPart] = []

        for notice in pending {
            let toolUseId = "notice_\(notice.id)"

            var inputDict: [String: Any] = [
                "notice_id": notice.id,
                "task_type": notice.taskType,
                "task_id": notice.taskId,
                "status": notice.status
            ]
            if let title = notice.title, !title.isEmpty { inputDict["title"] = title }
            if let filesPath = notice.filesPath, !filesPath.isEmpty { inputDict["files_path"] = filesPath }

            let inputJSON = (try? JSONSerialization.data(withJSONObject: inputDict))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            toolUses.append(.toolUse(ToolUse(
                toolUseId: toolUseId,
                name: ChatPersistenceSchema.asyncTaskNoticeToolName,
                input: inputJSON,
                description: notice.title ?? "\(notice.taskType) completed"
            )))

            let outputText = formatNoticeResultOutput(notice)
            toolResults.append(.toolResult(ToolResult(
                toolUseId: toolUseId,
                output: outputText,
                success: notice.status == "done",
                status: notice.status
            )))
        }

        let batchKey = pending.map(\.id).joined(separator: "_")
        let assistantMsgId = "msg_async_use_\(batchKey)"
        let userMsgId = "msg_async_res_\(batchKey)"
        let now = Date()

        let assistantMsg = RawMessage(
            id: assistantMsgId,
            sessionId: sessionId,
            role: .assistant,
            parts: toolUses,
            createdAt: now
        )
        let userMsg = RawMessage(
            id: userMsgId,
            sessionId: sessionId,
            role: .user,
            parts: toolResults,
            createdAt: now.addingTimeInterval(0.001)
        )

        // Atomically append messages and mark delivered
        _ = await ChatStore.shared.appendMessages([assistantMsg, userMsg])
        await ChatStore.shared.markAsyncTaskNoticesDelivered(ids: pending.map(\.id))

        logger.info("[Notice] Atomically injected \(toolUses.count) notice tool parts into session \(sessionId), resuming agent loop...")

        // Revive the agent loop
        _ = await sessionRunner.resumeAfterAsyncToolResults(sessionId: sessionId)
    }

    private func formatNoticeResultOutput(_ notice: AsyncTaskNotice) -> String {
        switch notice.taskType {
        case "subagent":
            var lines: [String] = [
                "[Background Subagent Finished]",
                "task_id: \(notice.taskId)",
                "title: \(notice.title ?? "")",
                "status: \(notice.status)"
            ]
            if let files = notice.filesPath, !files.isEmpty {
                lines.append("files: \(files)")
            }
            lines.append("")
            lines.append("Result:")
            lines.append(notice.result)
            lines.append("")
            lines.append("This background subagent has finished. Review the result above. If you need to update the user with new information, answer them in your own voice. If no user update is required, respond with (pass).")
            return lines.joined(separator: "\n")

        case "shell", "command":
            var lines: [String] = [
                "[Background Command Finished]",
                "task_id: \(notice.taskId)",
                "command: \(notice.title ?? "")",
                "status: \(notice.status)",
                "",
                "Output:",
                notice.result,
                "",
                "This background command has finished. Review the output above. If you need to update the user, answer them in your own voice. If no user update is required, respond with (pass)."
            ]
            return lines.joined(separator: "\n")

        case "a2a":
            var lines: [String] = [
                "[Colleague Assistant Replied]",
                "agent_id: \(notice.taskId)",
                "sender: \(notice.title ?? "")",
                "status: \(notice.status)",
                "",
                "Reply:",
                notice.result,
                "",
                "The colleague assistant has finished replying. Review the reply above. If you need to update the user, answer them in your own voice. If no user update is required, respond with (pass)."
            ]
            return lines.joined(separator: "\n")

        case "group":
            var lines: [String] = [
                "[Group Discussion Finished]",
                "group_id: \(notice.taskId)",
                "title: \(notice.title ?? "")",
                "status: \(notice.status)",
                "",
                "Summary:",
                notice.result,
                "",
                "The background group discussion round has finished. Review the summary above. If you need to update the user, answer them in your own voice. If no user update is required, respond with (pass)."
            ]
            return lines.joined(separator: "\n")

        default:
            return """
            [Background Task Finished]
            task_type: \(notice.taskType)
            task_id: \(notice.taskId)
            status: \(notice.status)

            Result:
            \(notice.result)

            Review the result above. If you need to update the user, answer them in your own voice. If no user update is required, respond with (pass).
            """
        }
    }
}
