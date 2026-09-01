//
//  GroupListView.swift
//  Minis
//
//  The group's row in the roster, and the screen you land on when you tap it.
//
//  There is no separate group chat screen: a group's transcript is an ordinary
//  session, so it opens in the ordinary AIChatView. The only thing this
//  container adds is telling the hardware bridge which room the device is
//  currently pointed at.
//

import SwiftUI

/// Named `AgentGroupRow`, not `GroupRow`: ModelGroupsView already owns that
/// name for a row in the model-provider group list, which is an unrelated
/// meaning of "group" that predates this feature.
struct AgentGroupRow: View {
    let group: GroupProfile
    var session: ChatSession? = nil
    /// Resolved members, for the avatar strip and the subtitle.
    let members: [GroupMember]
    let isTalking: Bool
    let hasUnread: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(group.emoji.isEmpty ? "👥" : group.emoji)
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
                .background(AgentAccent.color(group.accentColor).opacity(0.15))
                .clipShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle().fill(Color.red)
                            .frame(width: 9, height: 9)
                            .offset(x: 2, y: -2)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isTalking {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .frame(width: 16, height: 16)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(group.title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    Text(group.mode.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let date = session?.updatedAt {
                        ConversationTimestamp(date: date)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(isTalking ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if isTalking { return String(localized: "正在讨论…") }
        if let lastMessage = session?.lastMessage, !lastMessage.isEmpty { return lastMessage }
        guard !members.isEmpty else { return String(localized: "还没有成员") }
        return members.map(\.name).joined(separator: "、")
    }
}

/// Wraps a group's transcript and keeps the hardware bridge pointed at it.
struct GroupSessionView: View {
    let groupId: String

    @State private var group: GroupProfile?
    @State private var showingSettings = false

    var body: some View {
        Group {
            if let group {
                AIChatView(
                    sessionId: group.sessionId,
                    initialHeaderTitle: "\(group.title)（\(group.memberIds.count)人）",
                    headerActionSystemImage: "person.2.badge.gearshape",
                    headerActionAccessibilityLabel: String(localized: "群设置"),
                    onHeaderAction: { showingSettings = true }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingSettings) {
            if let group {
                NavigationStack {
                    GroupEditView(group: group) { updated in
                        self.group = updated
                        showingSettings = false
                    }
                }
            }
        }
        .task {
            group = await GroupStore.shared.loadGroup(groupId)
            // Pointing the device at this room is what makes a hardware prompt
            // go to the orchestrator instead of to a single agent. Scoped to
            // the screen's lifetime so leaving the room hands the board back to
            // the ordinary one-agent path.
            HardwareBridgeCoordinator.shared.activeGroupId = groupId
        }
        .onDisappear {
            if HardwareBridgeCoordinator.shared.activeGroupId == groupId {
                HardwareBridgeCoordinator.shared.activeGroupId = nil
            }
        }
    }
}
