//
//  GroupMessageDebugView.swift
//  Minis
//
//  Group Message Consumption & Routing Debugger:
//  Inspects the round-by-round FIFO message sequence, sender, mentions (@),
//  mode-aware routing dispatch decisions, and causal responder attribution.
//

import SwiftUI
import UIKit

/// Represents the causal role of a group message in the conversation flow.
enum GroupMessageRoleType {
    case userTrigger          // User initiated a new question/command
    case agentReply           // Agent responded to a prior trigger without chaining
    case agentChainedTrigger   // Agent responded and explicitly @mentioned next agent(s)
}

struct GroupDebugTurn: Identifiable {
    let id: String
    let roundNumber: Int
    let timestamp: Date
    let senderName: String
    let senderEmoji: String
    let senderAgentId: String?
    let isUser: Bool
    let isOwner: Bool
    let roleType: GroupMessageRoleType
    let mentionsEveryone: Bool
    let isEveryoneDowngraded: Bool
    let mentionedMemberNames: [String]
    let hasNoExplicitMentions: Bool
    let routingReason: String
    let routedResponderNames: [String]
    let actualResponders: [String]
    let potentialMissingResponders: [String]
    let rawText: String
    let exchangeId: Int
}

struct GroupMessageDebugView: View {
    let groupId: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var groups = GroupStore.shared

    @State private var group: GroupProfile?
    @State private var members: [GroupMember] = []
    @State private var turns: [GroupDebugTurn] = []
    @State private var isRunning = false
    @State private var isLoading = true
    @State private var filterOnlyTriggers = false
    @State private var expandedTurnIds: Set<String> = []
    @State private var showingCopiedAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isLoading {
                        ProgressView(String(localized: "正在分析群消息消费流水与因果归因…"))
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let group {
                        // Overview Card
                        overviewCard(group)

                        // Logic Explanation Banner
                        logicExplanationBanner(group)

                        // Diagnostic Banner
                        diagnosticBanner

                        // Filter & Export Bar
                        actionAndFilterBar

                        // Turns Timeline List
                        turnsTimelineSection
                    } else {
                        Text(String(localized: "未找到群聊信息"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 32)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle(String(localized: "群消息消费顺序 (Debug)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        Button {
                            copyDiagnosticReport()
                        } label: {
                            Label(String(localized: "复制诊断日志"), systemImage: "doc.on.doc")
                        }

                        Button {
                            Task { await analyzeTranscript() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .alert(String(localized: "已复制诊断报告"), isPresented: $showingCopiedAlert) {
                Button(String(localized: "好"), role: .cancel) {}
            } message: {
                Text(String(localized: "完整的群消息流转与因果分析 JSON 已复制到剪贴板，您可以直接粘贴发送给开发人员排查。"))
            }
        }
        .task {
            await analyzeTranscript()
        }
    }

    // MARK: - Subviews

    private func overviewCard(_ group: GroupProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(group.emoji.isEmpty ? "👥" : group.emoji)
                    .font(.system(size: 22))
                Text(group.title)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                Spacer()
                if isRunning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(String(localized: "正在消费处理"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                } else {
                    Text(String(localized: "当前空闲"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(UIColor.tertiarySystemGroupedBackground), in: Capsule())
                }
            }

            Divider()

            HStack(spacing: 16) {
                statItem(title: String(localized: "讨论模式"), value: group.mode.displayName)
                statItem(title: String(localized: "群成员总数"), value: "\(members.count) 人")
                statItem(title: String(localized: "历史消息总数"), value: "\(turns.count) 条")
            }

            Divider()

            HStack {
                Text(String(localized: "群 ID: \(group.id)"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button {
                    copyDiagnosticReport()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 11))
                        Text(String(localized: "一键复制完整诊断 JSON"))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    private func logicExplanationBanner(_ group: GroupProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Text(String(localized: "当前模式消费规则：\(group.mode.displayName)"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            if group.mode == .roundtable {
                Text(String(localized: "• 【圆桌讨论模式】：用户每次发言无需 @ 任何人，系统均会自动唤醒全部专家成员依次发言，最后由主持人总结。因此无论消息是否显式带 @，全员都会应答。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "• 【自由讨论模式】：\n  1. 用户 @所有人 -> 唤醒全员；\n  2. 用户 @指定智能体 -> 仅唤醒被 @ 的成员；\n  3. 用户未 @ 任何人 -> 延续上一发言人（或首位成员）；\n  4. 智能体回复 -> 纯回复不唤醒任何人；若智能体主动 @ 其他成员，则产生二次接力消费。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var diagnosticBanner: some View {
        let downgradedCount = turns.filter { $0.isEveryoneDowngraded }.count
        let missingCount = turns.reduce(0) { $0 + $1.potentialMissingResponders.count }

        return HStack(spacing: 10) {
            Image(systemName: (downgradedCount > 0 || missingCount > 0) ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.system(size: 20))
                .foregroundStyle((downgradedCount > 0 || missingCount > 0) ? Color.orange : Color.green)

            VStack(alignment: .leading, spacing: 2) {
                if downgradedCount == 0 && missingCount == 0 {
                    Text(String(localized: "群消息流转与因果消费判定正常"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(String(localized: "各触发轮次的消费队列与应答结果一致，未发现异常中断。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "检测到 \(downgradedCount + missingCount) 处需要注意的事项"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(diagnosticDetails(downgraded: downgradedCount, missing: missingCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background((downgradedCount > 0 || missingCount > 0) ? Color.orange.opacity(0.1) : Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func diagnosticDetails(downgraded: Int, missing: Int) -> String {
        var items: [String] = []
        if downgraded > 0 {
            items.append(String(localized: "\(downgraded) 处非群主@所有人被安全降级"))
        }
        if missing > 0 {
            items.append(String(localized: "\(missing) 处预期消费但未见回复(可能回复了Pass或在排队)"))
        }
        return items.joined(separator: "，")
    }

    private var actionAndFilterBar: some View {
        HStack {
            Toggle(String(localized: "仅看触发源消息 (发起提问/@接力)"), isOn: $filterOnlyTriggers)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 4)
    }

    private var displayedTurns: [GroupDebugTurn] {
        if filterOnlyTriggers {
            return turns.filter { $0.roleType != .agentReply }
        }
        return turns
    }

    private var turnsTimelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "消息流转时序流水 (共 \(displayedTurns.count) 条)"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            if displayedTurns.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "暂无历史记录"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 12) {
                    ForEach(displayedTurns) { turn in
                        turnCard(turn)
                    }
                }
            }
        }
    }

    private func turnCard(_ turn: GroupDebugTurn) -> some View {
        let isExpanded = expandedTurnIds.contains(turn.id)

        return VStack(alignment: .leading, spacing: 10) {
            // Header: Round Number, Role Badge, Timestamp
            HStack(spacing: 8) {
                Text("#\(turn.roundNumber)")
                    .font(.caption.monospaced().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)

                roleBadge(for: turn.roleType)

                Spacer()

                Text(timeString(from: turn.timestamp))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            // Sender Row
            HStack(spacing: 8) {
                Text(turn.senderEmoji)
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Circle())

                Text(String(localized: "发出人:"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(turn.senderName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                if turn.isOwner {
                    HStack(spacing: 2) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9))
                        Text(String(localized: "群主"))
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                }

                if turn.isUser {
                    Text(String(localized: "用户"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(UIColor.tertiarySystemGroupedBackground), in: Capsule())
                }
            }

            // Mentions Target Row (@了谁)
            HStack(alignment: .top, spacing: 8) {
                Text(String(localized: "@ 目标:"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                FlowLayout(spacing: 6) {
                    if turn.mentionsEveryone {
                        HStack(spacing: 3) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 9))
                            Text(String(localized: "@所有人"))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(turn.isEveryoneDowngraded ? Color.orange : Color.purple)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((turn.isEveryoneDowngraded ? Color.orange : Color.purple).opacity(0.12), in: Capsule())
                    }

                    ForEach(turn.mentionedMemberNames, id: \.self) { name in
                        HStack(spacing: 3) {
                            Text("@")
                            Text(name)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }

                    if turn.hasNoExplicitMentions && !turn.mentionsEveryone {
                        Text(String(localized: "无显式 @"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(UIColor.tertiarySystemGroupedBackground), in: Capsule())
                    }
                }
            }

            // Downgrade Notice if any
            if turn.isEveryoneDowngraded {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(String(localized: "非群主尝试 @所有人，系统已自动降级为普通发言"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Divider()

            // Routing Decision & Consumer Row (消费分发与因果)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    Text(String(localized: "路由规则: \(turn.routingReason)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if turn.roleType == .agentReply && turn.routedResponderNames.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)

                        Text(String(localized: "消费分发: 纯回复输出（未发起接力，本分支交互正常结束）"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(turn.routedResponderNames.isEmpty ? .secondary : Color.accentColor)
                            .padding(.top, 2)

                        if turn.routedResponderNames.isEmpty {
                            Text(String(localized: "消费分发: 无后续消费 (本轮结束/等待输入)"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                Text(String(localized: "预期消费分发:"))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)

                                Text(turn.routedResponderNames.joined(separator: "、"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    if !turn.actualResponders.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark.bubble.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                                .padding(.top, 2)

                            Text(String(localized: "实际完成应答: \(turn.actualResponders.joined(separator: "、"))"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                    }

                    if !turn.potentialMissingResponders.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "questionmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .padding(.top, 2)

                            Text(String(localized: "预期分发但未见直接回复: \(turn.potentialMissingResponders.joined(separator: "、")) (可能回复了Pass或在排队)"))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // Expandable Raw Inspector
            Divider()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedTurnIds.remove(turn.id)
                    } else {
                        expandedTurnIds.insert(turn.id)
                    }
                }
            } label: {
                HStack {
                    Text(isExpanded ? String(localized: "收起原始文本与底层数据") : String(localized: "展开原始文本与底层数据"))
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "【原始消息内容】（字数：\(turn.rawText.count)）:"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(turn.rawText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(UIColor.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    HStack {
                        Text("MessageID: \(turn.id)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if let aid = turn.senderAgentId {
                            Text("AgentID: \(aid)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func roleBadge(for role: GroupMessageRoleType) -> some View {
        switch role {
        case .userTrigger:
            Text(String(localized: "用户提问/指令"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1), in: Capsule())
        case .agentReply:
            Text(String(localized: "智能体回复"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(UIColor.tertiarySystemGroupedBackground), in: Capsule())
        case .agentChainedTrigger:
            Text(String(localized: "智能体接力 @"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.12), in: Capsule())
        }
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func copyDiagnosticReport() {
        guard let group else { return }
        let report: [String: Any] = [
            "group": [
                "id": group.id,
                "title": group.title,
                "mode": group.mode.rawValue,
                "ownerAgentId": group.ownerAgentId ?? "none",
                "sessionId": group.sessionId,
                "members": members.map { ["id": $0.id, "name": $0.name, "title": $0.title, "slot": $0.slot] }
            ],
            "totalTurns": turns.count,
            "turns": turns.map { turn -> [String: Any] in
                [
                    "round": turn.roundNumber,
                    "exchangeId": turn.exchangeId,
                    "timestamp": ISO8601DateFormatter().string(from: turn.timestamp),
                    "sender": turn.senderName,
                    "senderAgentId": turn.senderAgentId ?? "user",
                    "isUser": turn.isUser,
                    "isOwner": turn.isOwner,
                    "roleType": "\(turn.roleType)",
                    "mentionsEveryone": turn.mentionsEveryone,
                    "isEveryoneDowngraded": turn.isEveryoneDowngraded,
                    "mentionedMemberNames": turn.mentionedMemberNames,
                    "routingReason": turn.routingReason,
                    "routedExpectedResponders": turn.routedResponderNames,
                    "actualCompletedResponders": turn.actualResponders,
                    "potentialMissing": turn.potentialMissingResponders,
                    "rawText": turn.rawText
                ]
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let jsonStr = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = jsonStr
            showingCopiedAlert = true
        }
    }

    // MARK: - Analysis Logic

    private func analyzeTranscript() async {
        isLoading = true
        defer { isLoading = false }

        guard let g = await groups.loadGroup(groupId) else { return }
        group = g
        let membersList = await groups.members(of: g)
        members = membersList
        isRunning = GroupChatOrchestrator.shared.isRunning(groupId: g.id)

        // Load RawMessages from ChatStore for this group session
        let rawMessages = await ChatStore.shared.loadMessages(sessionId: g.sessionId)

        // Build valid text messages in chronological order
        struct MessageRecord {
            let id: String
            let timestamp: Date
            let isUser: Bool
            let senderId: String?
            let rawText: String
            let groupMessage: GroupMessage
        }

        var records: [MessageRecord] = []
        for raw in rawMessages {
            let text = raw.parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }
            if raw.role == .user {
                if !raw.isToolResultOnly {
                    records.append(MessageRecord(
                        id: raw.id,
                        timestamp: raw.createdAt,
                        isUser: true,
                        senderId: nil,
                        rawText: text,
                        groupMessage: .user(text)
                    ))
                }
            } else if raw.role == .assistant {
                if let senderId = raw.senderAgentId {
                    records.append(MessageRecord(
                        id: raw.id,
                        timestamp: raw.createdAt,
                        isUser: false,
                        senderId: senderId,
                        rawText: text,
                        groupMessage: .member(senderId, text)
                    ))
                }
            }
        }

        var analyzedTurns: [GroupDebugTurn] = []
        var groupHistory: [GroupMessage] = []
        var currentExchangeId = 0

        for (index, record) in records.enumerated() {
            let currentMsg = record.groupMessage
            let scan = GroupMentionRouter.parseMentions(in: record.rawText, members: membersList)

            if record.isUser {
                currentExchangeId += 1
            }

            // Sender Info
            let senderName: String
            let senderEmoji: String
            let isOwner: Bool

            if record.isUser {
                senderName = String(localized: "用户")
                senderEmoji = "👤"
                isOwner = false
            } else if let sId = record.senderId, let m = membersList.first(where: { $0.id == sId }) {
                senderName = m.name
                senderEmoji = m.emoji.isEmpty ? "🤖" : m.emoji
                isOwner = (sId == g.ownerAgentId)
            } else {
                senderName = String(localized: "智能体")
                senderEmoji = "🤖"
                isOwner = false
            }

            // Resolve mentions names
            let mentionedNames = scan.memberIds.compactMap { id in
                membersList.first { $0.id == id }?.name
            }

            // Determine Role Type
            let roleType: GroupMessageRoleType
            if record.isUser {
                roleType = .userTrigger
            } else if scan.isEveryone || !scan.memberIds.isEmpty {
                roleType = .agentChainedTrigger
            } else {
                roleType = .agentReply
            }

            // Routing Determination based on Mode
            let routedResponderNames: [String]
            let reasonDescription: String
            let isEveryoneDowngraded: Bool

            if g.mode == .roundtable {
                if record.isUser {
                    // In roundtable, user message dispatches to all experts + owner
                    let expertMembers = membersList.filter { $0.id != g.ownerAgentId }
                    let ownerMember = membersList.first { $0.id == g.ownerAgentId }
                    let allExpected = expertMembers + (ownerMember.map { [$0] } ?? [])
                    routedResponderNames = allExpected.map(\.name)
                    reasonDescription = String(localized: "【圆桌模式】全员研讨（专家发言 + 主持人总结）")
                    isEveryoneDowngraded = false
                } else {
                    // Agent turn in roundtable does not dispatch further
                    routedResponderNames = []
                    reasonDescription = String(localized: "【圆桌模式】环节发言")
                    isEveryoneDowngraded = false
                }
            } else {
                // Freeform mode
                let resolution = GroupMentionRouter.resolveResponders(
                    members: membersList,
                    newMessages: [currentMsg],
                    history: groupHistory + [currentMsg],
                    ownerAgentId: g.ownerAgentId
                )
                isEveryoneDowngraded = !resolution.downgradedEveryoneBy.isEmpty
                routedResponderNames = resolution.responderIds.compactMap { id in
                    membersList.first { $0.id == id }?.name
                }

                switch resolution.reason {
                case .everyone:
                    reasonDescription = String(localized: "@所有人 广播唤醒全员")
                case .mentioned:
                    reasonDescription = String(localized: "定向 @ 显式唤醒")
                case .lastSpeaker:
                    reasonDescription = String(localized: "未指定@，延续上一发言人")
                case .owner:
                    reasonDescription = String(localized: "未指定@，默认分配给群主")
                case .firstMember:
                    reasonDescription = String(localized: "未指定@，默认分配给首位成员")
                case .none:
                    reasonDescription = record.isUser
                        ? String(localized: "无明确目标")
                        : String(localized: "纯回复输出，本分支对齐静默/结束")
                }
            }

            // Attribution of Actual Responders:
            // ONLY triggers (user message or agent chained mention) look for causal responses!
            var actualResponders: [String] = []
            var potentialMissing: [String] = []

            if roleType == .userTrigger || roleType == .agentChainedTrigger {
                // Collect replies in this exchange until the next trigger (User message or Chained Agent)
                var checkIdx = index + 1
                while checkIdx < records.count {
                    let nextRec = records[checkIdx]
                    if nextRec.isUser { break } // Hit next user turn
                    if let nextSenderId = nextRec.senderId,
                       let nextMember = membersList.first(where: { $0.id == nextSenderId }) {
                        if !actualResponders.contains(nextMember.name) {
                            actualResponders.append(nextMember.name)
                        }
                    }
                    // If next agent also chained another mention, stop attribution for this trigger here
                    let nextScan = GroupMentionRouter.parseMentions(in: nextRec.rawText, members: membersList)
                    if nextScan.isEveryone || !nextScan.memberIds.isEmpty {
                        break
                    }
                    checkIdx += 1
                }

                potentialMissing = routedResponderNames.filter { !actualResponders.contains($0) }
            } else {
                // Pure agent reply: does NOT produce new consumers
                actualResponders = []
                potentialMissing = []
            }

            analyzedTurns.append(GroupDebugTurn(
                id: record.id,
                roundNumber: index + 1,
                timestamp: record.timestamp,
                senderName: senderName,
                senderEmoji: senderEmoji,
                senderAgentId: record.senderId,
                isUser: record.isUser,
                isOwner: isOwner,
                roleType: roleType,
                mentionsEveryone: scan.isEveryone,
                isEveryoneDowngraded: isEveryoneDowngraded,
                mentionedMemberNames: mentionedNames,
                hasNoExplicitMentions: !scan.isEveryone && mentionedNames.isEmpty,
                routingReason: reasonDescription,
                routedResponderNames: routedResponderNames,
                actualResponders: actualResponders,
                potentialMissingResponders: potentialMissing,
                rawText: record.rawText,
                exchangeId: currentExchangeId
            ))

            groupHistory.append(currentMsg)
        }

        turns = analyzedTurns
    }
}

// MARK: - FlowLayout Helper for Tag Capsules

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var maxHeightInRow: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            x += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
        height = y + maxHeightInRow
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var maxHeightInRow: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
    }
}
