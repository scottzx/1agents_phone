//
//  GroupChatPrompt.swift
//  Minis
//
//  How a member sees the room.
//
//  This is the load-bearing decision of the whole feature, and it is grok-bot
//  0.18's: there is NO shared message array. When 技术负责人 takes a turn, its
//  message array does not contain 市场专家's turns as messages at all. The room
//  is flattened to plain text — one line per utterance, `名字: 内容` — and
//  handed over as a SINGLE user message inside that member's own session.
//
//  That is what makes a group possible without touching the runtime: an
//  AIChatViewModel still has exactly one `agentId`, message roles still
//  alternate, per-session compaction still works, and a member's tool calls and
//  thinking stay private because only its final text is ever read back out.
//
//  The cost is that a member cannot quote a peer's tool output or see anything
//  a peer did not say aloud. That is the correct trade: it is also true of
//  people in a meeting.
//

import Foundation

enum GroupChatPrompt {

    /// Prefix stamped on every group turn prompt. A member's own session shows
    /// these turns in its history, and this is how the UI, compaction and a
    /// human reading the transcript can tell "the room asked me this" from
    /// "the user asked me this".
    static let tagPrefix = "[群聊："

    /// True when `text` is a turn prompt this file produced.
    static func isGroupTurnPrompt(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(tagPrefix)
    }

    /// `[群聊：「产品圆桌」— 与 市场专家、技术负责人 同在]`
    static func tagLine(title: String, peers: [GroupMember]) -> String {
        let names = peers.map(\.name).joined(separator: "、")
        let with = peers.isEmpty ? "" : " — 与 \(names) 同在"
        return "\(tagPrefix)「\(title)」\(with)]"
    }

    // MARK: - Transcript projection

    /// One transcript line as the viewer sees it.
    ///
    /// The ` (你)` suffix is not decoration: the whole room arrives as one
    /// undifferentiated blob of text, so this marker is the ONLY way a member
    /// can tell which lines are its own. (grok's `" (you)"`.)
    static func formatLine(
        _ message: GroupMessage,
        viewerId: String,
        members: [GroupMember]
    ) -> String {
        // Mentions are stored as `<@id>`; a member reads them as names. The
        // tokens it needs in order to reply come from the roster block of its
        // system prompt, which is the single place they are quoted — the same
        // split Slack has, where message text carries ids but a bot composing
        // a mention looks the id up rather than scraping it out of history.
        let body = GroupMentionRouter.render(message.text, members: members)
        switch message.speaker {
        case .user:
            return "用户: \(body)"
        case .member(let id):
            let name = members.first { $0.id == id }?.name ?? "已退出的成员"
            return "\(name)\(id == viewerId ? " (你)" : ""): \(body)"
        }
    }

    /// The last `limit` lines, oldest first.
    static func formatHistory(
        _ history: [GroupMessage],
        viewerId: String,
        members: [GroupMember],
        limit: Int = GroupChatLimits.promptHistoryLimit
    ) -> String {
        let recent = history.suffix(max(0, limit))
        guard !recent.isEmpty else { return "（还没有人说话）" }
        return recent.map { formatLine($0, viewerId: viewerId, members: members) }
            .joined(separator: "\n")
    }

    // MARK: - Turn prompts

    /// The freeform turn prompt: what changed since this member last spoke,
    /// plus an explicit invitation to stay silent.
    ///
    /// The `(pass)` instruction is the reason a room can go quiet on its own —
    /// GroupChatOrchestrator stops as soon as a whole round passes, so nobody
    /// has to guess when a conversation is finished.
    /// - Parameter allowHandoff: false when this member is answering the user
    ///   directly — named with `@`, or defaulted to as the last speaker. The
    ///   orchestrator ends the turn after such a round, so inviting a handoff
    ///   here would produce a line that @s a colleague who then never speaks — a
    ///   transcript that reads as broken. See GroupChatOrchestrator.runFreeform.
    static func turnPrompt(
        member: GroupMember,
        groupTitle: String,
        peers: [GroupMember],
        allMembers: [GroupMember],
        newMessages: [GroupMessage],
        allowHandoff: Bool = true
    ) -> String {
        let body = newMessages.isEmpty
            ? "自你上次发言以来，房间里没有新消息。"
            : "房间里的新消息（从旧到新）：\n"
                + formatHistory(newMessages, viewerId: member.id, members: allMembers)

        let closing = allowHandoff
            ? "要点名某位同事接着说，就把系统提示里列的那串 @ 写法原样抄进正文——不 @ 的话没有人会被叫醒，这一轮就结束了。"
            : "用户这句是冲着你来的，直接把话说完就行——这一轮到你为止，不用把话头递给别人，也不用 @ 任何人。"

        return """
            \(tagLine(title: groupTitle, peers: peers))
            \(body)

            轮到你说话了，\(member.name)。有值得补充的就用你自己的口吻说；没有新东西要说就只回「(pass)」，不要客套。
            \(closing)
            """
    }

    /// The roundtable turn prompt (DEMO_PRD.md §3): the topic plus every prior
    /// opinion in full, so each speaker can agree with or push back on what was
    /// already said instead of answering in a vacuum.
    static func roundtableTurnPrompt(
        member: GroupMember,
        groupTitle: String,
        peers: [GroupMember],
        allMembers: [GroupMember],
        topic: String,
        priorOpinions: [GroupMessage]
    ) -> String {
        var lines = [tagLine(title: groupTitle, peers: peers),
                     "议题：\(GroupMentionRouter.render(topic, members: allMembers))", ""]

        if priorOpinions.isEmpty {
            lines.append("你是第一位发言的人。")
        } else {
            lines.append("在你之前，同事们已经说过：")
            for opinion in priorOpinions {
                guard let id = opinion.speaker.memberId,
                      let speaker = allMembers.first(where: { $0.id == id }) else { continue }
                let role = speaker.title.isEmpty ? "" : "（\(speaker.title)）"
                lines.append("【\(speaker.name)\(role)】：\(GroupMentionRouter.render(opinion.text, members: allMembers))")
            }
        }

        let role = member.title.isEmpty ? "" : "（\(member.title)）"
        lines.append("")
        lines.append(
            "轮到你了，\(member.name)\(role)。就着上面的讨论，从你的专业角度给出判断——"
                + "可以赞同也可以反驳，但要说清楚理由。控制在 120 字以内，口语化，不要分点罗列。"
        )
        return lines.joined(separator: "\n")
    }

    /// The moderator's closing prompt for a roundtable.
    static func roundtableSummaryPrompt(
        member: GroupMember,
        groupTitle: String,
        peers: [GroupMember],
        allMembers: [GroupMember],
        topic: String,
        opinions: [GroupMessage]
    ) -> String {
        var lines = [tagLine(title: groupTitle, peers: peers),
                     "议题：\(GroupMentionRouter.render(topic, members: allMembers))", ""]
        for opinion in opinions {
            guard let id = opinion.speaker.memberId,
                  let speaker = allMembers.first(where: { $0.id == id }) else { continue }
            lines.append("【\(speaker.name)】：\(GroupMentionRouter.render(opinion.text, members: allMembers))")
        }
        lines.append("")
        lines.append(
            "你是这场讨论的主持人，\(member.name)。综合上面所有人的意见给出最终结论："
                + "先给立场（支持 / 有条件支持 / 不支持），再说核心理由，最后给一条可执行的建议。"
                + "150 字以内，语气果断——这段话会被念出来，所以要顺口，不要用分点和符号。"
        )
        return lines.joined(separator: "\n")
    }

    // MARK: - System prompt

    /// Prepended to a member's own persona while it is taking a group turn.
    ///
    /// Peers are listed by name and one line of description for a concrete
    /// reason: a member can only hand off with `@`, and it cannot @ someone
    /// whose name it was never told.
    static func memberSystemBlock(
        member: GroupMember,
        groupTitle: String,
        mode: GroupChatMode,
        isOwner: Bool,
        peers: [GroupMember]
    ) -> String {
        var lines: [String] = [
            "## 你正在群聊里",
            "",
            "你是 \(member.name)，群聊「\(groupTitle)」的参与者之一。你的人设、记忆和说话方式都不变，"
                + "变的只是场合：这里除了用户，还有别的同事在听。",
        ]

        if peers.isEmpty {
            lines.append("目前群里只有你和用户。")
        } else {
            lines.append("")
            lines.append("群里的其他人，以及 @ 他们时要原样写的写法：")
            for peer in peers {
                let role = peer.title.isEmpty ? "" : "（\(peer.title)）"
                let about = peer.summary.isEmpty ? "" : " — \(peer.summary)"
                lines.append("- \(peer.name)\(role)\(about)　→　\(GroupMentionRouter.token(for: peer.id))")
            }
        }

        lines.append("")
        lines.append("规矩：")
        lines.append("- 你这一轮说出来的**最终文字**就是群里看到的全部。工具调用、思考过程、中间步骤都留在你自己这边，别人看不到，所以结论要能独立成立。")
        lines.append("- 说话简短、像人在聊天。不要复述别人刚说过的话，不要总结全场——那是主持人的事。")
        lines.append("- 没有新东西要补充就只回「(pass)」。在群里保持安静是合格的表现，凑话不是。")

        if mode == .freeform {
            lines.append(
                "- 要让某位同事接着说，必须在正文里 @ 他，写法是上面列出的那串 "
                    + "`\(GroupMentionRouter.token(for: "..."))`，**从上面原样复制，不要自己拼**。"
                    + "系统靠这串字符找人，用户看到的是名字，所以你照抄不会让句子变难读。"
            )
            lines.append("- 没有被 @ 到的人收不到消息，也不会发言。你这一轮不 @ 任何人，讨论就到此为止——这是正常的结束方式。")
            if isOwner {
                lines.append(
                    "- 你是群主，只有你可以用 \(GroupMentionRouter.everyoneToken) 把全体叫起来。"
                        + "用之前想清楚是不是真的每个人都该说话。"
                )
            } else {
                lines.append("- 只有群主能招呼所有人。你写了也不会生效，点名具体的人就好。")
            }
        }

        lines.append("- 不要把你和用户单独私聊里的内容搬到群里来。")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
