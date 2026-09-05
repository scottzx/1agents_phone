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
        localExecutor: SubagentExecutor = LocalSubagentExecutor(),
        cloudExecutor: SubagentExecutor = AgentCoreSubagentExecutor()
    ) {
        self.localExecutor = localExecutor
        self.cloudExecutor = cloudExecutor
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
        return await localExecutor.status(taskId: taskId)
    }

    func message(taskId: String, text: String) async throws {
        if taskRouting[taskId] == .cloud {
            try await cloudExecutor.message(taskId: taskId, text: text)
        } else {
            try await localExecutor.message(taskId: taskId, text: text)
        }
    }

    @discardableResult
    func stop(taskId: String) async -> Bool {
        if taskRouting[taskId] == .cloud {
            return await cloudExecutor.stop(taskId: taskId)
        }
        return await localExecutor.stop(taskId: taskId)
    }
}
