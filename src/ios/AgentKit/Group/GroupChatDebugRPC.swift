#if DEBUG
import Foundation

/// Exercises the group routing and the turn projection over the existing DEBUG
/// JSON-RPC server, with no model call and no board attached.
///
/// The routing rules are the part of this feature most likely to be quietly
/// broken by a later change, and they are also the part that is expensive to
/// check the honest way — every real check costs several model turns. So
/// `debug.group.route` answers "who would speak, and what exactly would they
/// see" in milliseconds against a synthetic transcript.
enum GroupChatDebugRPC {

    /// `debug.group.route` — dry-run the router and the projection.
    @MainActor
    static func route(params: [String: Any]) async -> Any {
        let members: [GroupMember]
        let ownerAgentId: String?
        var groupTitle = params["title"] as? String ?? "调试群"

        if let groupId = params["groupId"] as? String {
            guard let group = await GroupStore.shared.loadGroup(groupId) else {
                return ["error": "没有 id 为 \(groupId) 的群聊"]
            }
            members = await GroupStore.shared.members(of: group)
            ownerAgentId = group.ownerAgentId
            groupTitle = group.title
        } else if let agentIds = params["agentIds"] as? [String], !agentIds.isEmpty {
            // Synthetic roster, so routing can be exercised before any group
            // exists — the same affordance debug.hardware.roster offers.
            var built: [GroupMember] = []
            for (index, id) in agentIds.enumerated() {
                guard let profile = await AgentStore.shared.loadAgent(id) else { continue }
                built.append(
                    GroupMember(id: profile.id, name: profile.name, title: profile.title,
                                emoji: profile.emoji, accentColor: profile.accentColor,
                                summary: profile.summary, slot: index)
                )
            }
            members = built
            ownerAgentId = params["ownerAgentId"] as? String
        } else {
            return ["error": "传 groupId，或者传 agentIds 构造一个临时群"]
        }
        guard !members.isEmpty else { return ["error": "没有可用成员"] }

        // History is given as ["user:文本", "<agentId>:文本"], oldest first.
        let history: [GroupMessage] = (params["history"] as? [String] ?? []).compactMap { line in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let who = String(line[line.startIndex..<separator])
            // Hand-written history uses readable `@名字`; encode it so the dry
            // run sees the same canonical text a real message would carry.
            let text = GroupMentionRouter.encode(
                String(line[line.index(after: separator)...]), members: members)
            return who == "user" ? .user(text) : .member(who, text)
        }
        guard !history.isEmpty else { return ["error": "history 为空。格式：[\"user:问题\", \"<agentId>:回答\"]"] }

        let newCount = min(max((params["newCount"] as? Int) ?? 1, 1), history.count)
        let newMessages = Array(history.suffix(newCount))

        let resolution = GroupMentionRouter.resolveResponders(
            members: members,
            newMessages: newMessages,
            history: history,
            ownerAgentId: ownerAgentId
        )

        let prompts = resolution.responderIds.compactMap { id -> [String: Any]? in
            guard let member = members.first(where: { $0.id == id }) else { return nil }
            return [
                "member": member.name,
                "systemBlock": GroupChatPrompt.memberSystemBlock(
                    member: member, groupTitle: groupTitle, mode: .freeform,
                    isOwner: member.id == ownerAgentId,
                    peers: members.filter { $0.id != member.id }
                ),
                "turnPrompt": GroupChatPrompt.turnPrompt(
                    member: member,
                    groupTitle: groupTitle,
                    peers: members.filter { $0.id != member.id },
                    allMembers: members,
                    newMessages: GroupMentionRouter.messagesSinceMemberLastSpoke(history, memberId: member.id)
                ),
            ]
        }

        return [
            "members": members.map { ["id": $0.id, "name": $0.name, "slot": $0.slot,
                                      "token": GroupMentionRouter.token(for: $0.id),
                                      "looseHandles": GroupMentionRouter.handles(for: $0)] },
            "everyoneToken": GroupMentionRouter.everyoneToken,
            "ownerAgentId": ownerAgentId as Any? ?? NSNull(),
            "newMessages": newMessages.map { GroupChatPrompt.formatLine($0, viewerId: "", members: members) },
            "reason": resolution.reason.rawValue,
            "responders": resolution.responderIds.compactMap { id in members.first { $0.id == id }?.name },
            "downgradedEveryoneBy": resolution.downgradedEveryoneBy,
            "usedLooseNamesBy": resolution.usedLooseNamesBy,
            "rounds": GroupChatLimits.maxRounds,
            "maxMemberTurns": GroupChatLimits.maxMemberTurns,
            "prompts": prompts,
        ]
    }

    /// `debug.group.run` — really run one turn, models and all. Slow, and the
    /// only way to see the whole loop end to end without the UI.
    @MainActor
    static func run(params: [String: Any]) async -> Any {
        guard let groupId = params["groupId"] as? String else {
            return ["error": "缺少 groupId"]
        }
        guard let text = params["text"] as? String, !text.isEmpty else {
            return ["error": "缺少 text"]
        }
        guard let group = await GroupStore.shared.loadGroup(groupId) else {
            return ["error": "没有 id 为 \(groupId) 的群聊"]
        }

        let closing = await GroupChatOrchestrator.shared.run(groupId: groupId, userText: text)
        let history = await GroupChatOrchestrator.shared.transcript(of: group)
        let members = await GroupStore.shared.members(of: group)

        return [
            "group": group.title,
            "mode": group.mode.rawValue,
            "closing": closing as Any? ?? NSNull(),
            "transcript": history.map { GroupChatPrompt.formatLine($0, viewerId: "", members: members) },
        ]
    }

    /// `debug.group.list` — the groups on this device, with their ids.
    @MainActor
    static func list() async -> Any {
        let groups = await ChatStore.shared.listGroups(includeArchived: true)
        return [
            "count": groups.count,
            "groups": groups.map { group in
                [
                    "id": group.id,
                    "title": group.title,
                    "mode": group.mode.rawValue,
                    "sessionId": group.sessionId,
                    "ownerAgentId": group.ownerAgentId as Any? ?? NSNull(),
                    "memberIds": group.memberIds,
                    "archived": group.isArchived,
                    "running": GroupChatOrchestrator.shared.isRunning(groupId: group.id),
                ] as [String: Any]
            },
        ]
    }
}
#endif
