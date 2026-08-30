//
//  GroupCreateView.swift
//  Minis
//
//  Making a group, and editing one afterwards.
//
//  Shaped after AgentCreateView so the two feel like the same app: same Form
//  sections, same emoji + palette pair, same "explain the mode you just picked"
//  footer. The one genuinely new control is the member picker, and the one
//  genuinely new concept is the owner — the member allowed to @所有人 and the
//  one who sums a roundtable up.
//

import SwiftUI

/// Shared editor body, used for both create and edit so the two screens cannot
/// drift apart on what a group is allowed to be.
private struct GroupForm: View {
    @Binding var title: String
    @Binding var emoji: String
    @Binding var accent: String
    @Binding var mode: GroupChatMode
    @Binding var memberIds: [String]
    @Binding var ownerAgentId: String?

    let roster: [AgentProfile]

    private let palette = ["#5B8DEF", "#E0A33E", "#4CAF7D", "#C46BC4", "#E4694E", "#5AA9C4"]

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "群名"), text: $title)
                TextField(String(localized: "Emoji"), text: $emoji)
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

            Section {
                Picker(String(localized: "讨论方式"), selection: $mode) {
                    ForEach(GroupChatMode.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text(mode.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "讨论方式"))
            }

            Section {
                ForEach(roster) { agent in
                    Button {
                        toggle(agent.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(agent.emoji.isEmpty ? "🤖" : agent.emoji)
                                .frame(width: 30, height: 30)
                                .background(AgentAccent.color(agent.accentColor).opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.name).foregroundStyle(.primary)
                                if !agent.summary.isEmpty {
                                    Text(agent.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if let index = memberIds.firstIndex(of: agent.id) {
                                // The number, not a checkmark: in a roundtable
                                // this order IS the speaking order, and it is
                                // also the node each member lights up on the
                                // hardware's round screen.
                                Text("\(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(Color.accentColor))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(memberIds.count >= GroupProfile.maxMembers && !memberIds.contains(agent.id))
                }
            } header: {
                Text(String(localized: "成员（\(memberIds.count)/\(GroupProfile.maxMembers)）"))
            } footer: {
                Text(String(localized: "按点选顺序发言。圆桌讨论时就是这个顺序，硬件圆屏上的节点也按这个顺序点亮。"))
            }

            Section {
                Picker(String(localized: "群主"), selection: $ownerAgentId) {
                    Text(String(localized: "不设群主")).tag(String?.none)
                    ForEach(selectedAgents) { agent in
                        Text("\(agent.emoji) \(agent.name)").tag(String?.some(agent.id))
                    }
                }
            } footer: {
                Text(String(localized: "群主是唯一能 @所有人 的成员；圆桌讨论时由它做最后总结，也由它的结论走语音播报。"))
            }
        }
    }

    private var selectedAgents: [AgentProfile] {
        memberIds.compactMap { id in roster.first { $0.id == id } }
    }

    private func toggle(_ agentId: String) {
        if let index = memberIds.firstIndex(of: agentId) {
            memberIds.remove(at: index)
            if ownerAgentId == agentId { ownerAgentId = nil }
        } else if memberIds.count < GroupProfile.maxMembers {
            memberIds.append(agentId)
        }
    }
}

struct GroupCreateView: View {
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AgentStore.shared

    @State private var title = ""
    @State private var emoji = "👥"
    @State private var accent = "#5B8DEF"
    @State private var mode: GroupChatMode = .freeform
    @State private var memberIds: [String] = []
    @State private var ownerAgentId: String?

    var body: some View {
        NavigationStack {
            GroupForm(
                title: $title, emoji: $emoji, accent: $accent, mode: $mode,
                memberIds: $memberIds, ownerAgentId: $ownerAgentId,
                roster: store.agents.filter { $0.id != AgentProfile.defaultAgentId }
            )
            .navigationTitle(String(localized: "新建群聊"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "创建")) {
                        Task {
                            guard let group = await GroupStore.shared.create(
                                title: title,
                                emoji: emoji,
                                accentColor: accent,
                                mode: mode,
                                ownerAgentId: ownerAgentId,
                                memberIds: memberIds
                            ) else { return }
                            onCreated(group.id)
                        }
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || memberIds.count < 2
                    )
                }
            }
        }
    }
}

struct GroupEditView: View {
    let group: GroupProfile
    var onSaved: (GroupProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AgentStore.shared

    @State private var title: String
    @State private var emoji: String
    @State private var accent: String
    @State private var mode: GroupChatMode
    @State private var memberIds: [String]
    @State private var ownerAgentId: String?

    init(group: GroupProfile, onSaved: @escaping (GroupProfile) -> Void) {
        self.group = group
        self.onSaved = onSaved
        _title = State(initialValue: group.title)
        _emoji = State(initialValue: group.emoji)
        _accent = State(initialValue: group.accentColor)
        _mode = State(initialValue: group.mode)
        _memberIds = State(initialValue: group.memberIds)
        _ownerAgentId = State(initialValue: group.ownerAgentId)
    }

    var body: some View {
        GroupForm(
            title: $title, emoji: $emoji, accent: $accent, mode: $mode,
            memberIds: $memberIds, ownerAgentId: $ownerAgentId,
            roster: store.agents.filter { $0.id != AgentProfile.defaultAgentId }
        )
        .navigationTitle(String(localized: "群设置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存")) {
                    var updated = group
                    updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.emoji = emoji
                    updated.accentColor = accent
                    updated.mode = mode
                    updated.memberIds = memberIds
                    updated.ownerAgentId = ownerAgentId
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
