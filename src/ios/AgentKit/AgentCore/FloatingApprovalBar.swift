//
//  FloatingApprovalBar.swift
//  Minis
//
//  Interactive floating approval banner docked right above the chat input box,
//  with an upward-sliding approval detail sheet.
//

import SwiftUI

// MARK: - Floating Approval Bar (Above Input Box)

struct FloatingApprovalBar: View {
    @ObservedObject var store: SubagentApprovalStore = .shared
    @Binding var showSheet: Bool
    @State private var selectedIndex: Int = 0

    private var pendingRequests: [SubagentApprovalRequest] {
        store.pendingRequests
    }

    private var currentRequest: SubagentApprovalRequest? {
        guard !pendingRequests.isEmpty else { return nil }
        let idx = min(max(selectedIndex, 0), pendingRequests.count - 1)
        return pendingRequests[idx]
    }

    var body: some View {
        if let req = currentRequest {
            Button {
                showSheet = true
            } label: {
                HStack(spacing: 8) {
                    // Shield Icon with pulsing orange accent
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.18))
                            .frame(width: 28, height: 28)
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.orange)
                    }

                    // Main info
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(String(localized: "权限审批请求"))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ChatColors.primaryText)

                            if let rule = req.policyRule {
                                Text(rule)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.orange.opacity(0.12))
                                    .foregroundStyle(.orange)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }

                        Text("\(req.title): \(req.summary)")
                            .font(.system(size: 11))
                            .foregroundStyle(ChatColors.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 4)

                    // Multi-request pager or badge
                    if pendingRequests.count > 1 {
                        HStack(spacing: 2) {
                            Button {
                                if selectedIndex > 0 { selectedIndex -= 1 }
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 9, weight: .bold))
                                    .frame(width: 18, height: 18)
                            }
                            .disabled(selectedIndex <= 0)

                            Text("\(selectedIndex + 1)/\(pendingRequests.count)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ChatColors.secondaryText)

                            Button {
                                if selectedIndex < pendingRequests.count - 1 { selectedIndex += 1 }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .frame(width: 18, height: 18)
                            }
                            .disabled(selectedIndex >= pendingRequests.count - 1)
                        }
                        .padding(.horizontal, 4)
                    }

                    // Action pill
                    HStack(spacing: 3) {
                        Text(String(localized: "审批"))
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 0.95) : UIColor.systemBackground.withAlphaComponent(0.95) }))
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pendingRequests.count)
        }
    }
}

// MARK: - Upward Approval Sheet View

struct SubagentApprovalSheetView: View {
    @ObservedObject var store: SubagentApprovalStore = .shared
    @Binding var isPresented: Bool

    @State private var feedbackText: String = ""
    @State private var isProcessing: Bool = false
    @State private var selectedIndex: Int = 0

    private var pendingRequests: [SubagentApprovalRequest] {
        store.pendingRequests
    }

    private var activeRequest: SubagentApprovalRequest? {
        guard !pendingRequests.isEmpty else { return nil }
        let idx = min(max(selectedIndex, 0), pendingRequests.count - 1)
        return pendingRequests[idx]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let req = activeRequest {
                        // Header Banner
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(Color.orange.opacity(0.15))
                                    .frame(width: 42, height: 42)
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.orange)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(String(localized: "云端策略拦截待审批"))
                                        .font(.headline)
                                    Spacer()
                                    Text(String(localized: "AgentCore Cedar"))
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.indigo.opacity(0.12))
                                        .foregroundStyle(.indigo)
                                        .clipShape(Capsule())
                                }

                                Text(String(localized: "触及企业合规或大额特批门槛，需创始人授权"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        // Task Details Card
                        VStack(alignment: .leading, spacing: 12) {
                            Label(String(localized: "任务详情"), systemImage: "doc.text.magnifyingglass")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(String(localized: "任务名称:"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(req.title)
                                        .font(.subheadline.weight(.medium))
                                }

                                HStack {
                                    Text(String(localized: "任务编号:"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(req.taskId)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                if let rule = req.policyRule {
                                    HStack {
                                        Text(String(localized: "触发策略:"))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Text(rule)
                                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.tertiarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        // Decision Reason Card
                        VStack(alignment: .leading, spacing: 8) {
                            Label(String(localized: "风控与策略依据"), systemImage: "exclamationmark.bubble")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(req.summary)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(ChatColors.primaryText)

                                if let reason = req.reason {
                                    Text(reason)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        // Optional Feedback Input
                        VStack(alignment: .leading, spacing: 6) {
                            Label(String(localized: "创始人批示/附言 (可选)"), systemImage: "pencil.line")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            TextField(String(localized: "输入特批指示或驳回理由..."), text: $feedbackText)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        // Action Buttons
                        HStack(spacing: 14) {
                            // Reject Button
                            Button(role: .destructive) {
                                handleDecision(taskId: req.taskId, approve: false)
                            } label: {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                    Text(String(localized: "拒绝驳回"))
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(isProcessing)

                            // Approve Button
                            Button {
                                handleDecision(taskId: req.taskId, approve: true)
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.shield.fill")
                                    Text(String(localized: "批准执行"))
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(isProcessing)
                        }
                        .padding(.top, 8)

                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.green)
                            Text(String(localized: "所有权限审批均已完成"))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
                .padding()
            }
            .navigationTitle(String(localized: "权限审批"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) {
                        isPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func handleDecision(taskId: String, approve: Bool) {
        isProcessing = true
        let feedback = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if approve {
                await store.approve(taskId: taskId, feedback: feedback.isEmpty ? nil : feedback)
            } else {
                await store.reject(taskId: taskId, reason: feedback.isEmpty ? nil : feedback)
            }
            isProcessing = false
            feedbackText = ""
            if store.pendingRequests.isEmpty {
                isPresented = false
            }
        }
    }
}
