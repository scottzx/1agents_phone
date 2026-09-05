//
//  AgentCoreRoutingTests.swift
//  MinisTests
//

import XCTest
@testable import Minis

@MainActor
final class AgentCoreRoutingTests: XCTestCase {

    private final class MockExecutor: SubagentExecutor {
        var spawnedTasks: [SubagentTask] = []
        var stoppedTaskIds: [String] = []
        var messagedTasks: [(String, String)] = []
        var nextTaskId: String = "mock_task"

        func spawn(_ task: SubagentTask) async throws -> String {
            spawnedTasks.append(task)
            return nextTaskId
        }

        func status(taskId: String) async -> SubagentStatus {
            SubagentStatus(
                taskId: taskId,
                title: "Mock Task",
                state: .done,
                currentActivity: "Finished",
                iteration: 1,
                result: "Mock Success"
            )
        }

        func message(taskId: String, text: String) async throws {
            messagedTasks.append((taskId, text))
        }

        func stop(taskId: String) async -> Bool {
            stoppedTaskIds.append(taskId)
            return true
        }
    }

    func testExplicitRoutingTargets() async throws {
        let localMock = MockExecutor()
        localMock.nextTaskId = "local_1"
        let cloudMock = MockExecutor()
        cloudMock.nextTaskId = "cloud_1"

        let router = RoutingSubagentExecutor(localExecutor: localMock, cloudExecutor: cloudMock)

        // 1. Explicit local target
        let localTask = SubagentTask(
            id: "",
            parentSessionId: "s1",
            agentId: "a1",
            title: "Local Shell",
            prompt: "ls -la",
            target: .local
        )
        let id1 = try await router.spawn(localTask)
        XCTAssertEqual(id1, "local_1")
        XCTAssertEqual(localMock.spawnedTasks.count, 1)
        XCTAssertEqual(cloudMock.spawnedTasks.count, 0)

        // 2. Explicit cloud target
        let cloudTask = SubagentTask(
            id: "",
            parentSessionId: "s1",
            agentId: "a1",
            title: "Cloud Contract",
            prompt: "检查供应商合同费率",
            target: .cloud,
            actorId: "SUPPLIER-1"
        )
        let id2 = try await router.spawn(cloudTask)
        XCTAssertEqual(id2, "cloud_1")
        XCTAssertEqual(cloudMock.spawnedTasks.count, 1)
        XCTAssertEqual(cloudMock.spawnedTasks.first?.actorId, "SUPPLIER-1")

        // 3. Forwarded status and message
        let status = await router.status(taskId: "cloud_1")
        XCTAssertEqual(status.state, .done)

        try await router.message(taskId: "cloud_1", text: "批准该特批")
        XCTAssertEqual(cloudMock.messagedTasks.count, 1)
        XCTAssertEqual(cloudMock.messagedTasks.first?.1, "批准该特批")

        let stopped = await router.stop(taskId: "cloud_1")
        XCTAssertTrue(stopped)
        XCTAssertEqual(cloudMock.stoppedTaskIds, ["cloud_1"])
    }

    func testAutoRoutingByKeywordDetection() async throws {
        let localMock = MockExecutor()
        localMock.nextTaskId = "local_auto"
        let cloudMock = MockExecutor()
        cloudMock.nextTaskId = "cloud_auto"

        let router = RoutingSubagentExecutor(localExecutor: localMock, cloudExecutor: cloudMock)

        // Auto task with business keyword -> routed to cloud
        let businessTask = SubagentTask(
            id: "",
            parentSessionId: "s1",
            agentId: "a1",
            title: "续约核算",
            prompt: "请帮我核对老客户续约报价是否在折扣上限内",
            target: .auto
        )
        let busId = try await router.spawn(businessTask)
        XCTAssertEqual(busId, "cloud_auto")
        XCTAssertEqual(cloudMock.spawnedTasks.count, 1)

        // Auto task without business keyword -> routed to local
        let shellTask = SubagentTask(
            id: "",
            parentSessionId: "s1",
            agentId: "a1",
            title: "目录搜索",
            prompt: "搜索当前工作区所有的 .swift 文件",
            target: .auto
        )
        let shellId = try await router.spawn(shellTask)
        XCTAssertEqual(shellId, "local_auto")
        XCTAssertEqual(localMock.spawnedTasks.count, 1)
    }

    func testCoordinatorDispatchesSpawnCloudSubagentTool() async throws {
        let localMock = MockExecutor()
        localMock.nextTaskId = "local_cmd"
        let cloudMock = MockExecutor()
        cloudMock.nextTaskId = "cloud_cmd"

        let router = RoutingSubagentExecutor(localExecutor: localMock, cloudExecutor: cloudMock)
        let coordinator = SubagentCoordinator(executor: router)

        // 1. Dispatching spawn_cloud_subagent tool
        let reply = await coordinator.handle(
            toolName: "spawn_cloud_subagent",
            input: [
                "task_title": "供应商核算",
                "prompt": "查询该供应商所有历史订单与对账差异",
                "actor_id": "SUPPLIER-ABC",
                "skill": "reconciliation"
            ],
            parentSessionId: "session_parent_1",
            agentId: "agent_main"
        )

        XCTAssertTrue(reply.contains("Task started."))
        XCTAssertTrue(reply.contains("task_id: cloud_cmd"))
        XCTAssertTrue(reply.contains("target: cloud"))
        XCTAssertEqual(cloudMock.spawnedTasks.count, 1)
        XCTAssertEqual(localMock.spawnedTasks.count, 0)
        XCTAssertEqual(cloudMock.spawnedTasks.first?.actorId, "SUPPLIER-ABC")
        XCTAssertEqual(cloudMock.spawnedTasks.first?.target, .cloud)

        // 2. Dispatching regular spawn_subagent tool
        let replyLocal = await coordinator.handle(
            toolName: "spawn_subagent",
            input: [
                "task_title": "本地解压",
                "prompt": "解压 /var/minis/shared/data.zip 并查看内容"
            ],
            parentSessionId: "session_parent_1",
            agentId: "agent_main"
        )

        XCTAssertTrue(replyLocal.contains("Task started."))
        XCTAssertTrue(replyLocal.contains("task_id: local_cmd"))
        XCTAssertTrue(replyLocal.contains("target: local"))
        XCTAssertEqual(localMock.spawnedTasks.count, 1)
    }

    func testApprovalStoreFlow() async throws {
        let store = SubagentApprovalStore.shared
        let taskId = "ac_test_approval_999"

        let req = SubagentApprovalRequest(
            taskId: taskId,
            title: "大额特批",
            summary: "金额超 20 万元，需要特批",
            policyRule: "forbid_large_amount",
            reason: "合同额 250,000 元",
            status: .pending
        )

        store.register(req)
        XCTAssertTrue(store.hasPendingRequest(for: taskId))
        XCTAssertEqual(store.request(for: taskId)?.status, .pending)

        await store.approve(taskId: taskId, feedback: "同意按 25 万签约")
        XCTAssertFalse(store.hasPendingRequest(for: taskId))
        XCTAssertEqual(store.request(for: taskId)?.status, .approved)
        XCTAssertEqual(store.request(for: taskId)?.feedback, "同意按 25 万签约")
    }
}
