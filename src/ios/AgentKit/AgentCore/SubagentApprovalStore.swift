//
//  SubagentApprovalStore.swift
//  Minis
//
//  Maintains pending human-in-the-loop permission and approval requests
//  triggered by AgentCore Cedar Policy escalations.
//

import Combine
import Foundation

@MainActor
final class SubagentApprovalStore: ObservableObject {
    static let shared = SubagentApprovalStore()

    @Published private(set) var requests: [String: SubagentApprovalRequest] = [:]

    private init() {}

    func register(_ request: SubagentApprovalRequest) {
        requests[request.taskId] = request
    }

    func request(for taskId: String) -> SubagentApprovalRequest? {
        requests[taskId]
    }

    func hasPendingRequest(for taskId: String) -> Bool {
        requests[taskId]?.status == .pending
    }

    var pendingRequests: [SubagentApprovalRequest] {
        requests.values
            .filter { $0.status == .pending }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func approve(taskId: String, feedback: String? = nil) async {
        guard var req = requests[taskId] else { return }
        req.status = .approved
        req.feedback = feedback
        req.resolvedAt = Date()
        requests[taskId] = req

        let feedbackText = feedback?.isEmpty == false ? " 附言: \(feedback!)" : ""
        let instruction = "【创始人权限审批结果: 已批准】同意本次特批申请，请继续执行并完成 record_decision 登记。\(feedbackText)"

        _ = await SubagentCoordinator.shared.handle(
            toolName: "message_subagent",
            input: [
                "task_id": taskId,
                "message": instruction
            ],
            parentSessionId: "",
            agentId: nil
        )
    }

    func reject(taskId: String, reason: String? = nil) async {
        guard var req = requests[taskId] else { return }
        req.status = .rejected
        req.feedback = reason
        req.resolvedAt = Date()
        requests[taskId] = req

        let reasonText = reason?.isEmpty == false ? " 理由: \(reason!)" : ""
        let instruction = "【创始人权限审批结果: 已拒绝】已驳回本次特批申请，请终止并归档。\(reasonText)"

        _ = await SubagentCoordinator.shared.handle(
            toolName: "message_subagent",
            input: [
                "task_id": taskId,
                "message": instruction
            ],
            parentSessionId: "",
            agentId: nil
        )
    }
}
