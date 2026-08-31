//
//  GroupProfile.swift
//  Minis
//
//  A group: several agents and the user in one conversation.
//
//  The shape is lifted from grok-bot 0.18's `group.json`
//  (modules/grok-bot-0.18-reconstructed/source/host/groups/group-store.ts):
//  a group is not a new kind of runtime, it is a roster plus a transcript. What
//  it deliberately is NOT is a shared message array — see GroupChatPrompt for
//  the projection that lets each member run in its own session instead.
//
//  Storage mirrors how AgentProfile is split:
//    - metadata + membership → `agent_groups` / `agent_group_members` in minis.db
//    - the transcript        → an ordinary `sessions` row, spawn_role = 'group'
//    - a member's own thread → a `sessions` row, spawn_role = 'group-member',
//                              agent_id = the member, parent_session_id = the group
//  Nothing lives on disk: a group has no persona and no memory of its own. Its
//  members bring theirs.
//

import Foundation

// Shared Apple-domain group value types.

/// How turn-taking is decided in a group.
public enum GroupChatMode: String, Codable, CaseIterable, Sendable {
    /// @-routed. Who speaks next is whoever the last messages addressed.
    case freeform
    /// Fixed order, every member sees every prior opinion, owner sums up.
    /// This is DEMO_PRD.md's AI Roundtable — a preset, not a separate engine.
    case roundtable

    var displayName: String {
        switch self {
        case .freeform: return String(localized: "自由群聊")
        case .roundtable: return String(localized: "圆桌讨论")
        }
    }

    var explanation: String {
        switch self {
        case .freeform:
            return String(localized: "按 @ 决定谁发言。@所有人 全员轮流说，@某人 只有他收到，不 @ 则接着上一位发言人往下聊。")
        case .roundtable:
            return String(localized: "固定顺序依次发言，后发言的人能看到前面所有观点，最后由群主做总结。适合评估一个议题。")
        }
    }
}

/// `sessions.spawn_role` values this feature adds. The column already carries
/// "main" / "subagent" / "legacy"; these two extend that vocabulary rather than
/// introducing a parallel one, so every existing query keeps working.
public enum GroupSessionRole {
    /// The transcript the user reads. `agent_id` is NULL — a group has no owner
    /// session, which is exactly why it can hold several speakers.
    public static let group = "group"
    /// One member's private thread inside one group. Never listed, never
    /// purged (see the note on ChatStore.purgeExpiredSubagentSessions).
    public static let member = "group-member"
}

public struct GroupProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    /// The `sessions` row holding the transcript.
    var sessionId: String
    var title: String
    /// Group avatar. One or two emoji, same reasoning as AgentProfile.emoji.
    var emoji: String
    /// Hex accent (`#RRGGBB`) for the group's row and header.
    var accentColor: String
    var mode: GroupChatMode
    /// The one member allowed to `@所有人`, and the one who sums up a
    /// roundtable. Nil is legal — then nobody but the user can address everyone.
    var ownerAgentId: String?
    /// Member agent ids, in `sort_order`. The index doubles as the hardware
    /// node slot (see DeviceRoundtableState.speaking(slot:isOwner:)).
    var memberIds: [String]
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?

    var isArchived: Bool { archivedAt != nil }

    /// Same ceiling grok-bot uses (`GROUP_MAX_MEMBERS`). Members speak strictly
    /// one at a time, so a seventh member is another whole model turn of
    /// latency before the user hears anything back.
    public static let maxMembers = 6

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        title: String,
        emoji: String = "👥",
        accentColor: String = "#5B8DEF",
        mode: GroupChatMode = .freeform,
        ownerAgentId: String? = nil,
        memberIds: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.emoji = emoji
        self.accentColor = accentColor
        self.mode = mode
        self.ownerAgentId = ownerAgentId
        self.memberIds = memberIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    // Mirrors AgentProfile's cheap-comparison contract: the roster is diffed by
    // SwiftUI on every transaction flush, and `updatedAt` is the change proxy.
    public static func == (lhs: GroupProfile, rhs: GroupProfile) -> Bool {
        lhs.id == rhs.id
            && lhs.updatedAt == rhs.updatedAt
            && lhs.title == rhs.title
            && lhs.emoji == rhs.emoji
            && lhs.mode == rhs.mode
            && lhs.ownerAgentId == rhs.ownerAgentId
            && lhs.memberIds == rhs.memberIds
            && lhs.archivedAt == rhs.archivedAt
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(updatedAt)
    }
}

/// A member as the router and the prompt builder see it: an AgentProfile
/// flattened to just what a group turn needs. Kept separate from AgentProfile
/// so GroupMentionRouter stays a pure function over values and can be tested
/// without AgentStore, ChatStore or a running app.
public struct GroupMember: Identifiable, Equatable, Hashable, Sendable {
    /// The agent id. Also the participant id on the hardware wire.
    public let id: String
    public let name: String
    /// Short role label ("市场专家"). Doubles as an @-handle when non-empty.
    public let title: String
    public let emoji: String
    public let accentColor: String
    /// One line for the "other participants" block of a member's system prompt.
    public let summary: String
    /// Position in the roster: roundtable speaking order, and the hardware's
    /// round-screen node slot.
    public let slot: Int

    public init(id: String, name: String, title: String, emoji: String, accentColor: String, summary: String, slot: Int) {
        self.id = id
        self.name = name
        self.title = title
        self.emoji = emoji
        self.accentColor = accentColor
        self.summary = summary
        self.slot = slot
    }

    /// Name with its emoji, for a log line or a device roster label.
    public var displayName: String {
        emoji.isEmpty ? name : "\(emoji) \(name)"
    }
}

/// Who said one line in a group.
public enum GroupSpeaker: Equatable, Hashable, Sendable {
    case user
    case member(String)

    public var memberId: String? {
        if case .member(let id) = self { return id }
        return nil
    }

    public var isUser: Bool { self == .user }
}

/// One line of the shared transcript, as the router and the prompt builder see
/// it. This is the projection of a `RawMessage` — tool calls, thinking and
/// everything else a member did privately never become a GroupMessage.
public struct GroupMessage: Equatable, Hashable, Sendable {
    public let speaker: GroupSpeaker
    public let text: String

    public init(speaker: GroupSpeaker, text: String) {
        self.speaker = speaker
        self.text = text
    }

    public static func user(_ text: String) -> GroupMessage { .init(speaker: .user, text: text) }
    public static func member(_ id: String, _ text: String) -> GroupMessage {
        .init(speaker: .member(id), text: text)
    }
}

/// The four caps that make a runaway room structurally impossible, plus the
/// projection window. Values match grok-bot's (`GROUP_MAX_ROUNDS`,
/// `GROUP_MAX_MEMBER_TURNS`, `GROUP_PROMPT_HISTORY_LIMIT`); the reasoning is
/// theirs and it holds here: caps are cheaper and far more predictable than any
/// heuristic for "the conversation has finished".
public enum GroupChatLimits {
    /// Rounds of speaking per user message.
    public static let maxRounds = 3
    /// Total member messages per user message, across all rounds.
    public static let maxMemberTurns = 10
    /// Transcript lines shown to a member in one turn prompt.
    public static let promptHistoryLimit = 24
    /// Ceiling on how long one member's turn may run before the room moves on.
    /// Same value as SubagentTools.maxWaitSeconds, for the same reason: a group
    /// turn is no more entitled to block than a dispatched task is.
    public static let memberTurnTimeoutSeconds = 240
}
