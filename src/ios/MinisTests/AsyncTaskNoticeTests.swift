import XCTest
@testable import Minis

final class AsyncTaskNoticeTests: XCTestCase {

    func testAsyncTaskNoticeSerialization() throws {
        let notice = AsyncTaskNotice(
            id: "notice_123",
            sourceSessionId: "session_abc",
            taskType: "shell",
            taskId: "cmd_456",
            agentId: "agent_789",
            title: "ls -la",
            status: "done",
            result: "total 0\n-rw-r--r-- 1 root root 0 test.txt",
            filesPath: "/var/minis/shared/tasks/cmd_456",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            isDelivered: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(notice)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AsyncTaskNotice.self, from: data)

        XCTAssertEqual(decoded.id, "notice_123")
        XCTAssertEqual(decoded.sourceSessionId, "session_abc")
        XCTAssertEqual(decoded.taskType, "shell")
        XCTAssertEqual(decoded.taskId, "cmd_456")
        XCTAssertEqual(decoded.agentId, "agent_789")
        XCTAssertEqual(decoded.title, "ls -la")
        XCTAssertEqual(decoded.status, "done")
        XCTAssertEqual(decoded.result, "total 0\n-rw-r--r-- 1 root root 0 test.txt")
        XCTAssertEqual(decoded.filesPath, "/var/minis/shared/tasks/cmd_456")
        XCTAssertFalse(decoded.isDelivered)
    }

    func testRawMessageIsAsyncTaskNotice() {
        let toolUseRaw = RawMessage(
            id: "raw_1",
            sessionId: "s_1",
            role: .assistant,
            parts: [.toolUse(ToolUse(toolUseId: "async-notice:n1", name: ChatPersistenceSchema.asyncTaskNoticeToolName, input: "{}"))],
            createdAt: Date()
        )
        XCTAssertTrue(toolUseRaw.isAsyncTaskNotice)

        let toolResultRaw = RawMessage(
            id: "raw_2",
            sessionId: "s_1",
            role: .user,
            parts: [.toolResult(ToolResult(toolUseId: "async-notice:n1", output: "done", success: true))],
            createdAt: Date()
        )
        XCTAssertTrue(toolResultRaw.isAsyncTaskNotice)

        let normalAssistantRaw = RawMessage(
            id: "raw_3",
            sessionId: "s_1",
            role: .assistant,
            parts: [.text("Hello world")],
            createdAt: Date()
        )
        XCTAssertFalse(normalAssistantRaw.isAsyncTaskNotice)

        let normalToolResultRaw = RawMessage(
            id: "raw_4",
            sessionId: "s_1",
            role: .user,
            parts: [.toolResult(ToolResult(toolUseId: "ordinary-call", output: "done", success: true))],
            createdAt: Date()
        )
        XCTAssertFalse(normalToolResultRaw.isAsyncTaskNotice)
    }

    func testChatMessageIsAsyncTaskNotice() {
        let msg = ChatMessage(role: .assistant, content: "")
        msg.isSyntheticNotice = true
        XCTAssertTrue(msg.isAsyncTaskNotice)

        let normalMsg = ChatMessage(role: .assistant, content: "Hello")
        XCTAssertFalse(normalMsg.isAsyncTaskNotice)
    }

    func testPassQuiescenceDetection() {
        XCTAssertTrue(GroupMentionRouter.isPass("(pass)"))
        XCTAssertTrue(GroupMentionRouter.isPass("（pass）"))
        XCTAssertTrue(GroupMentionRouter.isPass("pass"))
        XCTAssertTrue(GroupMentionRouter.isPass("PASS"))
        XCTAssertTrue(GroupMentionRouter.isPass("(PASS)"))
        XCTAssertTrue(GroupMentionRouter.isPass("无"))
        XCTAssertTrue(GroupMentionRouter.isPass("(无)"))
        XCTAssertTrue(GroupMentionRouter.isPass("跳过"))
        XCTAssertTrue(GroupMentionRouter.isPass("略过"))

        XCTAssertFalse(GroupMentionRouter.isPass("The command finished with exit code 0."))
        XCTAssertFalse(GroupMentionRouter.isPass("I have verified the file."))
    }

    func testChatStoreNoticeLifecycle() async {
        let store = ChatStore.shared
        let testSession = "test_notice_session_\(UUID().uuidString)"

        let notice1 = AsyncTaskNotice(
            id: "n1_\(UUID().uuidString)",
            sourceSessionId: testSession,
            taskType: "shell",
            taskId: "cmd_1",
            title: "build project",
            status: "done",
            result: "Build succeeded",
            filesPath: nil,
            createdAt: Date(),
            isDelivered: false
        )

        let notice2 = AsyncTaskNotice(
            id: "n2_\(UUID().uuidString)",
            sourceSessionId: testSession,
            taskType: "subagent",
            taskId: "task_2",
            agentId: "agent_2",
            title: "research competitors",
            status: "done",
            result: "Found 3 competitors",
            filesPath: "/var/minis/shared/tasks/task_2",
            createdAt: Date(),
            isDelivered: false
        )

        await store.saveAsyncTaskNotice(notice1)
        await store.saveAsyncTaskNotice(notice2)

        var pending = await store.pendingAsyncTaskNotices(for: testSession)
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.contains(where: { $0.id == notice1.id }))
        XCTAssertTrue(pending.contains(where: { $0.id == notice2.id }))

        await store.markAsyncTaskNoticesDelivered(ids: [notice1.id])

        let hasDelivered1 = await store.hasDeliveredNotice(id: notice1.id)
        XCTAssertTrue(hasDelivered1)

        pending = await store.pendingAsyncTaskNotices(for: testSession)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, notice2.id)
        XCTAssertEqual(pending.first?.agentId, "agent_2")

        await store.deleteAsyncTaskNotice(id: notice1.id)
        await store.deleteAsyncTaskNotice(id: notice2.id)

        pending = await store.pendingAsyncTaskNotices(for: testSession)
        XCTAssertEqual(pending.count, 0)
    }

    func testAtomicNoticeInjectionIsPairedAndIdempotent() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsyncTaskNoticeTests-\(UUID().uuidString)", isDirectory: true)
        let store = ChatStore(baseURL: baseURL)
        let session = await store.createSession(modelId: "test-model", title: "notice test")
        let noticeId = "async:a2a:delivery-1"
        let toolUseId = ChatPersistenceSchema.asyncTaskNoticeToolUseIdPrefix + noticeId
        let notice = AsyncTaskNotice(
            id: noticeId,
            sourceSessionId: session.id,
            taskType: "a2a",
            taskId: "delivery-1",
            agentId: "agent-target",
            status: "done",
            result: "reply",
            isDelivered: false
        )
        await store.saveAsyncTaskNotice(notice)

        let messages = [
            RawMessage(
                id: "async-notice-use:\(noticeId)",
                sessionId: session.id,
                role: .assistant,
                parts: [.toolUse(ToolUse(
                    toolUseId: toolUseId,
                    name: ChatPersistenceSchema.asyncTaskNoticeToolName,
                    input: "{}"
                ))],
                createdAt: Date()
            ),
            RawMessage(
                id: "async-notice-result:\(noticeId)",
                sessionId: session.id,
                role: .user,
                parts: [.toolResult(ToolResult(
                    toolUseId: toolUseId,
                    output: "reply",
                    success: true
                ))],
                createdAt: Date().addingTimeInterval(0.001)
            ),
        ]

        let firstInjection = await store.injectAsyncTaskNoticeMessages(messages, noticeIds: [noticeId])
        let firstPending = await store.pendingAsyncTaskNotices(for: session.id)
        let firstMessages = await store.loadMessages(sessionId: session.id)
        XCTAssertTrue(firstInjection)
        XCTAssertTrue(firstPending.isEmpty)
        XCTAssertEqual(firstMessages.count, 2)

        // A crash retry uses the same ids and must not duplicate either half.
        await store.markAsyncTaskNoticesPending(ids: [noticeId])
        let retryInjection = await store.injectAsyncTaskNoticeMessages(messages, noticeIds: [noticeId])
        let retryMessages = await store.loadMessages(sessionId: session.id)
        let retryPending = await store.pendingAsyncTaskNotices(for: session.id)
        XCTAssertTrue(retryInjection)
        XCTAssertEqual(retryMessages.count, 2)
        XCTAssertTrue(retryPending.isEmpty)

        await store.closeDatabase()
        try? FileManager.default.removeItem(at: baseURL)
    }
}
