//
//  RoutingSubagentExecutor.swift
//  Minis
//
//  Dispatches subagent tasks to either the local on-device iSH executor or
//  the remote Amazon Bedrock AgentCore cloud executor.
//

import Foundation

@MainActor
final class RoutingSubagentExecutor: SubagentExecutor {

    private let localExecutor: SubagentExecutor
    private let cloudExecutor: SubagentExecutor
    private var taskRouting: [String: SubagentTask.Target] = [:]

    init(
        localExecutor: SubagentExecutor,
        cloudExecutor: SubagentExecutor
    ) {
        self.localExecutor = localExecutor
        self.cloudExecutor = cloudExecutor
    }

    convenience init() {
        self.init(
            localExecutor: LocalSubagentExecutor(),
            cloudExecutor: AgentCoreSubagentExecutor()
        )
    }

    /// Resolve the target executor based on task intent and configuration.
    func resolveTarget(for task: SubagentTask) -> SubagentTask.Target {
        switch task.target {
        case .local:
            return .local
        case .cloud:
            return .cloud
        case .auto:
            return AgentCoreTaskRouting.isCloudTask(task.prompt) ? .cloud : .local
        }
    }

    // MARK: - SubagentExecutor

    @discardableResult
    func spawn(_ task: SubagentTask) async throws -> String {
        let effectiveTarget = resolveTarget(for: task)
        let taskId: String

        switch effectiveTarget {
        case .cloud:
            taskId = try await cloudExecutor.spawn(task)
        case .local, .auto:
            taskId = try await localExecutor.spawn(task)
        }

        taskRouting[taskId] = effectiveTarget
        return taskId
    }

    func status(taskId: String) async -> SubagentStatus {
        if taskRouting[taskId] == .cloud {
            return await cloudExecutor.status(taskId: taskId)
        }
        let localStatus = await localExecutor.status(taskId: taskId)
        if localStatus.state != .unknown {
            return localStatus
        }
        let cloudStatus = await cloudExecutor.status(taskId: taskId)
        if cloudStatus.state != .unknown {
            return cloudStatus
        }
        return localStatus
    }

    func message(taskId: String, text: String) async throws {
        if taskRouting[taskId] == .cloud {
            try await cloudExecutor.message(taskId: taskId, text: text)
            return
        }
        do {
            try await localExecutor.message(taskId: taskId, text: text)
        } catch {
            try await cloudExecutor.message(taskId: taskId, text: text)
        }
    }

    @discardableResult
    func stop(taskId: String) async -> Bool {
        if taskRouting[taskId] == .cloud {
            return await cloudExecutor.stop(taskId: taskId)
        }
        let stopped = await localExecutor.stop(taskId: taskId)
        if stopped { return true }
        return await cloudExecutor.stop(taskId: taskId)
    }
}
