//
//  SubagentApprovalCardView.swift
//  Minis
//
//  Interactive permission request / approval card for AgentCore Cedar Policy
//  escalations (Human-in-the-Loop).
//

import SwiftUI

struct SubagentApprovalCardView: View {
    let taskId: String
    @ObservedObject private var store = SubagentApprovalStore.shared
    @State private var isSubmitting = false

    private var request: SubagentApprovalRequest? {
        store.request(for: taskId)
    }

    var body: some View {
        if let req = request {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: headerIcon(for: req.status))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(headerTint(for: req.status))

                    Text(String(localized: "权限审批请求 · Cedar 策略拦截"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatColors.primaryText)

                    Spacer(minLength: 0)

                    statusBadge(for: req.status)
                }

                // Policy chip
                if let rule = req.policyRule, !rule.isEmpty {
                    HStack(spacing: 4) {
                        Text(String(localized: "拦截策略:"))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(rule)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                }

                // Summary & Reason
                Text(req.summary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ChatColors.primaryText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = req.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Actions or Status Outcome
                Divider()
                    .padding(.vertical, 2)

                switch req.status {
                case .pending:
                    HStack(spacing: 12) {
                        Button {
                            guard !isSubmitting else { return }
                            isSubmitting = true
                            Task {
                                await store.approve(taskId: taskId)
                                isSubmitting = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Text(String(localized: "批准执行"))
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.green)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            guard !isSubmitting else { return }
                            isSubmitting = true
                            Task {
                                await store.reject(taskId: taskId)
                                isSubmitting = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle")
                                Text(String(localized: "拒绝"))
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                case .approved:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "已授权批准 · 云端已恢复执行并完成登记"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                    }

                case .rejected:
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.seal.fill")
                            .foregroundStyle(.red)
                        Text(String(localized: "已拒绝 · 任务已终止"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(cardBackground(for: req.status))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(cardBorder(for: req.status), lineWidth: 1)
            )
        }
    }

    private func headerIcon(for status: SubagentApprovalStatus) -> String {
        switch status {
        case .pending: return "exclamationmark.shield.fill"
        case .approved: return "checkmark.shield.fill"
        case .rejected: return "xmark.shield.fill"
        }
    }

    private func headerTint(for status: SubagentApprovalStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .approved: return .green
        case .rejected: return .secondary
        }
    }

    @ViewBuilder
    private func statusBadge(for status: SubagentApprovalStatus) -> some View {
        switch status {
        case .pending:
            Text(String(localized: "待审批"))
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        case .approved:
            Text(String(localized: "已批准"))
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        case .rejected:
            Text(String(localized: "已驳回"))
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        }
    }

    private func cardBackground(for status: SubagentApprovalStatus) -> Color {
        switch status {
        case .pending: return Color.orange.opacity(0.06)
        case .approved: return Color.green.opacity(0.05)
        case .rejected: return Color.secondary.opacity(0.05)
        }
    }

    private func cardBorder(for status: SubagentApprovalStatus) -> Color {
        switch status {
        case .pending: return Color.orange.opacity(0.3)
        case .approved: return Color.green.opacity(0.25)
        case .rejected: return Color.secondary.opacity(0.2)
        }
    }
}
