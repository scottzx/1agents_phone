//
//  RelatedTasksSection.swift
//  Minis
//
//  Reusable task queue row and related-tasks section for Home,
//  Agent Detail, and Group Detail views.
//

import SwiftUI

enum TaskQueueStatus: String, CaseIterable, Identifiable {
    case waiting = "等待"
    case inProgress = "进行中"
    case completed = "已完成"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .waiting: return "clock.fill"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .waiting: return .orange
        case .inProgress: return .accentColor
        case .completed: return .green
        }
    }
}

struct TaskQueueCardMetadata {
    let conversationType: String
    let taskType: String?
    let primaryAgentName: String?
    let groupMemberNames: [String]

    var searchableText: String {
        ([conversationType, taskType, primaryAgentName].compactMap { $0 } + groupMemberNames)
            .joined(separator: " ")
    }
}

enum RelatedTaskFilter: Equatable {
    case all
    case agent(String)
    case group(groupId: String, sessionId: String)
}

struct TaskQueueRow: View {
    let entry: TaskQueueEntry
    let status: TaskQueueStatus
    let queuePosition: Int
    let toolInfo: SessionActivityTracker.SessionToolInfo?
    let metadata: TaskQueueCardMetadata

    private var session: ChatSession { entry.session }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(status.tint.opacity(0.12))
                if status == .inProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(status.tint)
                } else {
                    Image(systemName: status.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(status.tint)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(displayTitle)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ConversationTimestamp(date: entry.lastReplyAt ?? session.updatedAt)
                }

                HStack(spacing: 4) {
                    metadataBadge(metadata.conversationType, tint: .secondary)
                    if let taskType = metadata.taskType {
                        metadataBadge(String(localized: "任务类型：\(taskType)"), tint: .purple)
                    }
                }

                if let primaryAgentName = metadata.primaryAgentName {
                    Text(metadata.taskType == nil
                         ? String(localized: "智能体：\(primaryAgentName)")
                         : String(localized: "主智能体：\(primaryAgentName)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !metadata.groupMemberNames.isEmpty {
                    Text(String(localized: "群成员：\(metadata.groupMemberNames.joined(separator: "、"))"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(detailLine)
                    .font(.system(size: 13))
                    .foregroundStyle(status == .completed ? Color.secondary : status.tint)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var displayTitle: String {
        if let title = session.spawnTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return String(localized: "新会话")
    }

    private func metadataBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
    }

    private var detailLine: String {
        switch status {
        case .waiting:
            if queuePosition < Int.max {
                return String(localized: "等待执行槽 · 队列第 \(queuePosition) 位")
            }
            return String(localized: "等待执行槽")
        case .inProgress:
            let toolName = toolInfo?.toolName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let toolStatus = toolInfo?.toolStatus.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !toolName.isEmpty, !toolStatus.isEmpty { return "\(toolName) · \(toolStatus)" }
            if !toolName.isEmpty { return String(localized: "正在运行 \(toolName)") }
            return String(localized: "正在处理…")
        case .completed:
            if session.spawnStatus == "failed" { return String(localized: "任务失败") }
            if session.spawnStatus == "stopped" { return String(localized: "任务已停止") }
            if let lastMessage = session.lastMessage, !lastMessage.isEmpty { return lastMessage }
            return String(localized: "暂无助手回复")
        }
    }
}

/// A self-contained section that displays related tasks for an Agent or Group.
struct RelatedTasksView: View {
    let filter: RelatedTaskFilter
    var onSelectTask: (TaskQueueEntry) -> Void

    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var groups = GroupStore.shared
    @ObservedObject private var activity = SessionActivityTracker.shared
    @ObservedObject private var concurrency = SessionConcurrencyManager.shared

    @State private var selectedStatus: TaskQueueStatus = .inProgress
    @State private var taskQueueEntries: [TaskQueueEntry] = []
    @State private var groupMembers: [String: [GroupMember]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "相关任务"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            Picker(String(localized: "任务状态"), selection: $selectedStatus) {
                ForEach(TaskQueueStatus.allCases) { status in
                    Text("\(status.rawValue) \(filteredEntries(for: status).count)")
                        .tag(status)
                }
            }
            .pickerStyle(.segmented)

            let entries = filteredEntries(for: selectedStatus)
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(emptyLabel(for: selectedStatus))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        Button {
                            onSelectTask(entry)
                        } label: {
                            TaskQueueRow(
                                entry: entry,
                                status: selectedStatus,
                                queuePosition: queuePosition(for: entry.session.id),
                                toolInfo: activity.sessionToolInfo[entry.session.id],
                                metadata: taskMetadata(for: entry)
                            )
                            .padding(10)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task {
            await loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidCreate)) { _ in
            Task { await loadData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidUpdate)) { _ in
            Task { await loadData() }
        }
    }

    private func loadData() async {
        let entries = await ChatStore.shared.listTaskQueueEntries()
        taskQueueEntries = entries
        var membersDict: [String: [GroupMember]] = [:]
        for group in groups.groups {
            membersDict[group.id] = await groups.members(of: group)
        }
        groupMembers = membersDict
    }

    private var matchingEntries: [TaskQueueEntry] {
        taskQueueEntries.filter { entry in
            let session = entry.session
            let parent = session.parentSessionId.flatMap { pid in
                taskQueueEntries.first(where: { $0.session.id == pid })?.session
            }
            let contextSession = session.isSubagent ? (parent ?? session) : session

            switch filter {
            case .all:
                return true
            case .agent(let agentId):
                if session.agentId == agentId || contextSession.agentId == agentId {
                    return true
                }
                if let mainSessionId = store.agent(agentId)?.mainSessionId,
                   session.id == mainSessionId || session.parentSessionId == mainSessionId {
                    return true
                }
                return false
            case .group(let groupId, let sessionId):
                if session.id == sessionId || session.parentSessionId == sessionId || contextSession.id == sessionId || contextSession.parentSessionId == sessionId {
                    return true
                }
                if let group = groups.groups.first(where: { $0.id == groupId }) {
                    if session.id == group.sessionId || session.parentSessionId == group.sessionId || contextSession.id == group.sessionId {
                        return true
                    }
                }
                return false
            }
        }
    }

    private func filteredEntries(for status: TaskQueueStatus) -> [TaskQueueEntry] {
        matchingEntries
            .filter { taskStatus(for: $0.session.id) == status }
            .sorted { lhs, rhs in
                if status == .waiting {
                    return queuePosition(for: lhs.session.id) < queuePosition(for: rhs.session.id)
                }
                let leftDate = lhs.lastReplyAt ?? lhs.session.updatedAt
                let rightDate = rhs.lastReplyAt ?? rhs.session.updatedAt
                return leftDate > rightDate
            }
    }

    private func taskStatus(for sessionId: String) -> TaskQueueStatus {
        if concurrency.isSuspended(sessionId) { return .waiting }
        if activity.isActive(sessionId) || concurrency.runningSessions.contains(sessionId) {
            return .inProgress
        }
        return .completed
    }

    private func queuePosition(for sessionId: String) -> Int {
        (concurrency.suspendedSessions.firstIndex(of: sessionId) ?? Int.max - 1) + 1
    }

    private func emptyLabel(for status: TaskQueueStatus) -> String {
        switch status {
        case .waiting: return String(localized: "暂无等待中的任务")
        case .inProgress: return String(localized: "暂无进行中的任务")
        case .completed: return String(localized: "暂无已完成的任务")
        }
    }

    private func taskMetadata(for entry: TaskQueueEntry) -> TaskQueueCardMetadata {
        let session = entry.session
        let parent = session.parentSessionId.flatMap { parentId in
            taskQueueEntries.first(where: { $0.session.id == parentId })?.session
        }
        let contextSession = session.isSubagent ? (parent ?? session) : session

        let group = groups.groups.first { candidate in
            candidate.sessionId == contextSession.id
                || candidate.sessionId == contextSession.parentSessionId
        }

        let memberNames: [String]
        if let group {
            let members = groupMembers[group.id] ?? []
            if contextSession.spawnRole == GroupSessionRole.member,
               let memberId = contextSession.agentId,
               let member = members.first(where: { $0.id == memberId }) {
                memberNames = [member.displayName]
            } else {
                memberNames = members.map(\.displayName)
            }
        } else {
            memberNames = []
        }

        let initiatingAgentId: String? = {
            if session.isSubagent {
                return parent?.agentId ?? session.agentId
            }
            guard contextSession.agentId != AgentProfile.defaultAgentId else { return nil }
            return contextSession.agentId
        }()
        let initiatingAgentName = (session.isSubagent || group == nil)
            ? initiatingAgentId.flatMap { store.agent($0)?.name }
            : nil

        let conversationType: String
        if group != nil {
            conversationType = String(localized: "群聊")
        } else if initiatingAgentId != nil {
            conversationType = String(localized: "聊天")
        } else {
            conversationType = String(localized: "对话")
        }

        return TaskQueueCardMetadata(
            conversationType: conversationType,
            taskType: session.isSubagent ? String(localized: "子智能体") : nil,
            primaryAgentName: initiatingAgentName,
            groupMemberNames: memberNames
        )
    }
}
