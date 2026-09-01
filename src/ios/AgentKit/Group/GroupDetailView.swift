//
//  GroupDetailView.swift
//  Minis
//
//  Group Profile & Details: member grid with add/remove management,
//  long-press context menus, discussion mode configuration, fast chat entry,
//  and group related task queue.
//

import SwiftUI

struct GroupDetailView: View {
    let groupId: String
    var onEnterGroupChat: ((String) -> Void)? = nil
    var onOpenAgentDetail: ((String) -> Void)? = nil
    var onOpenSession: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var groups = GroupStore.shared
    @ObservedObject private var store = AgentStore.shared

    @State private var group: GroupProfile?
    @State private var members: [GroupMember] = []
    @State private var showingAddMembers = false
    @State private var showingEditGroup = false
    @State private var showingArchiveConfirm = false
    @State private var showingDebugDrawer = false
    @State private var memberToRemove: GroupMember?

    private let gridColumns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let group {
                    // Top: Members Grid Card
                    membersGridCard(group)

                    // Primary Action: Enter Group Chat
                    enterChatButton(group)

                    // Group Info & Mode Card
                    groupInfoCard(group)

                    // Dev Test Debug Entry Card
                    debugEntryCard

                    // Related Tasks Section
                    RelatedTasksView(filter: .group(groupId: group.id, sessionId: group.sessionId)) { entry in
                        onOpenSession?(entry.session.id)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(group?.title ?? String(localized: "群聊"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddMembers) {
            if let group {
                NavigationStack {
                    GroupAddMemberPicker(
                        currentMemberIds: Set(group.memberIds),
                        allAgents: store.agents.filter { $0.id != AgentProfile.defaultAgentId }
                    ) { selectedAgentIds in
                        Task {
                            var updated = group
                            for id in selectedAgentIds {
                                if !updated.memberIds.contains(id), updated.memberIds.count < GroupProfile.maxMembers {
                                    updated.memberIds.append(id)
                                }
                            }
                            await groups.save(updated)
                            await loadData()
                            showingAddMembers = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingEditGroup) {
            if let group {
                NavigationStack {
                    GroupEditSheet(group: group) { updated in
                        self.group = updated
                        showingEditGroup = false
                        Task { await loadData() }
                    }
                }
            }
        }
        .sheet(isPresented: $showingDebugDrawer) {
            GroupMessageDebugView(groupId: groupId)
        }
        .alert(String(localized: "移除成员"), isPresented: Binding(
            get: { memberToRemove != nil },
            set: { if !$0 { memberToRemove = nil } }
        ), presenting: memberToRemove) { member in
            Button(String(localized: "取消"), role: .cancel) { memberToRemove = nil }
            Button(String(localized: "移除"), role: .destructive) {
                removeMember(member.id)
                memberToRemove = nil
            }
        } message: { member in
            Text(String(localized: "确定要将「\(member.name)」从群聊中移除吗？"))
        }
        .alert(String(localized: "解散/归档群聊"), isPresented: $showingArchiveConfirm) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "归档"), role: .destructive) {
                Task {
                    await groups.archive(groupId)
                    dismiss()
                }
            }
        } message: {
            Text(String(localized: "归档后该群聊不再出现在通讯录和聊天列表中，会话记录将保留。"))
        }
        .task {
            await loadData()
        }
    }

    // MARK: - Subviews

    private func membersGridCard(_ group: GroupProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "群成员（\(members.count) 人）"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(String(localized: "长按成员可管理"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: gridColumns, spacing: 14) {
                ForEach(members) { member in
                    memberItemView(member: member, group: group)
                }

                // Add Member Button (Last item)
                if group.memberIds.count < GroupProfile.maxMembers {
                    Button {
                        showingAddMembers = true
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 52, height: 52)
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(String(localized: "添加"))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func memberItemView(member: GroupMember, group: GroupProfile) -> some View {
        let isOwner = group.ownerAgentId == member.id

        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Text(member.emoji.isEmpty ? "🤖" : member.emoji)
                    .font(.system(size: 26))
                    .frame(width: 52, height: 52)
                    .background(AgentAccent.color(member.accentColor).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if isOwner {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.orange, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }

            Text(member.name)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onOpenAgentDetail?(member.id)
            } label: {
                Label(String(localized: "查看智能体介绍"), systemImage: "person.crop.circle")
            }

            if isOwner {
                Button {
                    setOwner(nil)
                } label: {
                    Label(String(localized: "取消群主"), systemImage: "crown.badge.minus")
                }
            } else {
                Button {
                    setOwner(member.id)
                } label: {
                    Label(String(localized: "设为群主"), systemImage: "crown")
                }
            }

            Divider()

            Button(role: .destructive) {
                memberToRemove = member
            } label: {
                Label(String(localized: "从群聊中移除"), systemImage: "person.badge.minus")
            }
        }
    }

    private func enterChatButton(_ group: GroupProfile) -> some View {
        Button {
            onEnterGroupChat?(group.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(String(localized: "进入群聊"))
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func groupInfoCard(_ group: GroupProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(group.emoji.isEmpty ? "👥" : group.emoji)
                    .font(.system(size: 28))
                    .frame(width: 52, height: 52)
                    .background(AgentAccent.color(group.accentColor).opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    Text(group.mode.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(String(localized: "长按可修改"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            Text(group.mode.explanation)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button {
                showingEditGroup = true
            } label: {
                Label(String(localized: "修改群信息与讨论模式"), systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                showingArchiveConfirm = true
            } label: {
                Label(String(localized: "解散/归档群聊"), systemImage: "archivebox")
            }
        }
    }

    private var debugEntryCard: some View {
        Button {
            showingDebugDrawer = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.purple)
                    .frame(width: 32, height: 32)
                    .background(Color.purple.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "开发测试 Debug：群消息消费顺序"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(String(localized: "查看每轮发出人、@目标及消费路由判定"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions & Data

    private func loadData() async {
        if let g = await groups.loadGroup(groupId) {
            group = g
            members = await groups.members(of: g)
        }
    }

    private func removeMember(_ agentId: String) {
        guard var g = group else { return }
        g.memberIds.removeAll { $0 == agentId }
        if g.ownerAgentId == agentId {
            g.ownerAgentId = nil
        }
        Task {
            await groups.save(g)
            await loadData()
        }
    }

    private func setOwner(_ agentId: String?) {
        guard var g = group else { return }
        g.ownerAgentId = agentId
        Task {
            await groups.save(g)
            await loadData()
        }
    }
}

// MARK: - Add Member Picker Sheet

private struct GroupAddMemberPicker: View {
    let currentMemberIds: Set<String>
    let allAgents: [AgentProfile]
    var onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<String> = []
    @State private var searchText = ""

    private var candidateAgents: [AgentProfile] {
        let available = allAgents.filter { !currentMemberIds.contains($0.id) }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AlphabetHelper.sortedByAlphabet(available, by: \.name)
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return available.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.title.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            if candidateAgents.isEmpty {
                Text(String(localized: "没有更多可添加的智能体"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(candidateAgents) { agent in
                    Button {
                        if selectedIds.contains(agent.id) {
                            selectedIds.remove(agent.id)
                        } else {
                            selectedIds.insert(agent.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedIds.contains(agent.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(selectedIds.contains(agent.id) ? Color.accentColor : .secondary)

                            Text(agent.emoji.isEmpty ? "🤖" : agent.emoji)
                                .font(.system(size: 20))
                                .frame(width: 36, height: 36)
                                .background(AgentAccent.color(agent.accentColor).opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                if !agent.title.isEmpty {
                                    Text(agent.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $searchText, prompt: String(localized: "搜索智能体..."))
        .navigationTitle(String(localized: "添加智能体到群聊"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "添加 (\(selectedIds.count))")) {
                    onAdd(Array(selectedIds))
                }
                .disabled(selectedIds.isEmpty)
            }
        }
    }
}

// MARK: - Group Edit Sheet

private struct GroupEditSheet: View {
    let group: GroupProfile
    var onSaved: (GroupProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var emoji: String
    @State private var accent: String
    @State private var mode: GroupChatMode

    private let palette = ["#5B8DEF", "#E0A33E", "#4CAF7D", "#C46BC4", "#E4694E", "#5AA9C4"]

    init(group: GroupProfile, onSaved: @escaping (GroupProfile) -> Void) {
        self.group = group
        self.onSaved = onSaved
        _title = State(initialValue: group.title)
        _emoji = State(initialValue: group.emoji)
        _accent = State(initialValue: group.accentColor)
        _mode = State(initialValue: group.mode)
    }

    var body: some View {
        Form {
            Section(String(localized: "群聊基本信息")) {
                TextField(String(localized: "群名"), text: $title)
                TextField(String(localized: "Emoji 头像"), text: $emoji)
                HStack(spacing: 10) {
                    ForEach(palette, id: \.self) { hex in
                        Circle()
                            .fill(AgentAccent.color(hex))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary, lineWidth: accent == hex ? 2 : 0))
                            .onTapGesture { accent = hex }
                    }
                }
            }

            Section(String(localized: "讨论方式")) {
                Picker(String(localized: "讨论模式"), selection: $mode) {
                    ForEach(GroupChatMode.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text(mode.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "修改群聊信息"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存")) {
                    var updated = group
                    updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.emoji = emoji.isEmpty ? "👥" : emoji
                    updated.accentColor = accent
                    updated.mode = mode
                    Task {
                        await GroupStore.shared.save(updated)
                        onSaved(updated)
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
