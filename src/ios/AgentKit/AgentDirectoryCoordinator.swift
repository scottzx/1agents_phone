//
//  AgentDirectoryCoordinator.swift
//  Minis
//
//  Turns `create_agent` / `list_agents` / `send_agent_message` into real work.
//
//  Structured like SubagentCoordinator (tools in, model-readable text out) so
//  the two dispatch surfaces stay symmetrical, but the runtime is different in
//  one way that drives everything below: the recipient of an inter-agent
//  message is not a scratch session we own, it is a conversation the user
//  reads and may be typing into right now. So delivery is written to be
//  non-destructive — the recipient's composer draft is preserved, a running
//  turn is refused rather than silently pre-empted, and the message lands as a
//  visibly attributed user turn instead of a hidden injection.
//
//  Loop safety
//  -----------
//  Two agents can each hold the other's id, so A→B→A is one prompt away. The
//  busy check already breaks the tight case (A is parked inside its tool call,
//  so it is processing, so B's reply-send is refused) — but only while A
//  waits. `relayOrigin` closes the rest: it records the live from→to edges of
//  every in-flight relay, and a send is refused if the recipient is already
//  upstream in the caller's chain, or if that chain is `maxHops` long.
//

import Foundation

@MainActor
final class AgentDirectoryCoordinator {
    static let shared = AgentDirectoryCoordinator()

    private let logger = AppLogger(category: "AgentDirectory")

    /// Live relay edges: recipient session → sender session. An entry exists
    /// from the moment a message is delivered until the recipient's turn ends,
    /// which is exactly the window in which a reply could bounce back.
    private var relayOrigin: [String: String] = [:]

    /// Structured group messages emitted while a group-member model is still
    /// inside its turn. They cannot be posted immediately: the enclosing group
    /// orchestrator owns ordering and turn caps. `runMemberTurn` consumes the
    /// queued canonical line and publishes it as that member's one utterance.
    private var pendingGroupMessages: [String: [String]] = [:]

    /// How many agents one message may pass through. Three is enough for
    /// "ask a colleague, who asks a specialist" and short enough that a
    /// runaway relay costs a handful of turns rather than a token budget.
    private static let maxHops = 3

    /// Palette the create-agent UI offers, reused so an agent the model
    /// created looks like one the user created.
    private static let palette = ["#5B8DEF", "#E0A33E", "#4CAF7D", "#C46BC4", "#E4694E", "#5AA9C4"]

    private init() {}

    // MARK: - Entry point

    func handle(
        toolName: String,
        input: [String: Any],
        callerSessionId: String,
        callerAgentId: String?,
        callerGroupId: String? = nil
    ) async -> String {
        switch toolName {
        case "create_agent":
            return await handleCreate(input: input)
        case "list_agents":
            return await handleList(callerAgentId: callerAgentId)
        case "send_agent_message":
            return await handleSend(
                input: input,
                callerSessionId: callerSessionId,
                callerAgentId: callerAgentId,
                callerGroupId: callerGroupId
            )
        default:
            return "Unknown agent-directory tool: \(toolName)"
        }
    }

    // MARK: - create_agent

    private func handleCreate(input: [String: Any]) async -> String {
        let name = string(input["name"])
        guard !name.isEmpty else {
            return "Error: `name` is required — the new assistant needs something for the user to call it."
        }
        let persona = string(input["persona"])
        guard !persona.isEmpty else {
            return "Error: `persona` is required. Without it the new assistant is a blank copy of the default one, which is not worth a roster slot."
        }

        let policy = AgentToolPolicy(rawValue: string(input["work_mode"]).lowercased()) ?? .orchestrator
        let emoji = string(input["emoji"])
        let accent = normalizedHex(string(input["accent_color"]))
            ?? Self.palette[AgentStore.shared.agents.count % Self.palette.count]

        let agent = await AgentStore.shared.create(
            name: name,
            emoji: emoji,
            title: string(input["title"]),
            summary: string(input["summary"]),
            accentColor: accent,
            toolPolicy: policy,
            personaBody: persona
        )
        logger.info("created agent \(agent.id.prefix(8)) name=\(name) policy=\(policy.rawValue)")

        return """
            Assistant created.
            agent_id: \(agent.id)
            name: \(agent.emoji) \(agent.name)\(agent.title.isEmpty ? "" : " (\(agent.title))")
            mode: \(policy.rawValue)

            It is in the user's roster now, with its own conversation — they \
            can open it from the home screen. It has no history and has not \
            been told anything; to give it a first instruction use \
            send_agent_message with is_group: false and agent_id: [\(agent.id)].

            Tell the user it exists, in one line, in your own voice. Do not \
            list what tools it has or explain how agents work.
            """
    }

    // MARK: - list_agents

    private func handleList(callerAgentId: String?) async -> String {
        await AgentStore.shared.refresh()
        let roster = AgentStore.shared.agents
        guard !roster.isEmpty else {
            return "No assistants in the roster yet. create_agent adds one."
        }

        var lines: [String] = []
        for agent in roster {
            var entry = "agent_id: \(agent.id)"
            entry += "\nname: \(agent.emoji) \(agent.name)"
            if !agent.title.isEmpty { entry += " (\(agent.title))" }
            entry += "\nmode: \(agent.toolPolicy.rawValue)"
            if !agent.summary.isEmpty { entry += "\nabout: \(agent.summary)" }
            if agent.id == callerAgentId {
                entry += "\nnote: this is you — you cannot message yourself."
            } else if let main = agent.mainSessionId, isBusy(sessionId: main) {
                entry += "\nstatus: busy (mid-turn right now)"
            } else {
                entry += "\nstatus: idle"
            }
            lines.append(entry)
        }

        return lines.joined(separator: "\n\n") + """


            For a private message, call send_agent_message with is_group: false \
            and agent_id as a list (even for one recipient). Each assistant has \
            its own memory and cannot see this conversation, so whatever you \
            send has to carry its own context.
            """
    }

    // MARK: - send_agent_message

    private func handleSend(
        input: [String: Any],
        callerSessionId: String,
        callerAgentId: String?,
        callerGroupId: String?
    ) async -> String {
        guard let isGroup = bool(input["is_group"]) else {
            return "Error: `is_group` is required. Use false for a private broadcast or true for a group transcript message."
        }
        let groupId = string(input["group_id"])
        if isGroup {
            guard !groupId.isEmpty else {
                return "Error: `group_id` is required when `is_group` is true."
            }
            return await handleGroupSend(
                input: input,
                groupId: groupId,
                callerSessionId: callerSessionId,
                callerAgentId: callerAgentId,
                callerGroupId: callerGroupId
            )
        }
        guard groupId.isEmpty else {
            return "Error: omit `group_id` when `is_group` is false."
        }
        let targetIds = stringArray(input["agent_id"])
        guard !targetIds.isEmpty else {
            return "Error: `agent_id` must be a non-empty list. Call list_agents to see who exists."
        }
        guard !targetIds.contains(GroupMentionRouter.everyoneId) else {
            return "Error: `at_all` is valid only with `is_group: true`."
        }
        if let callerAgentId, targetIds.contains(callerAgentId) {
            return "Error: `agent_id` cannot contain the sending assistant."
        }

        var results: [String] = []
        for targetId in targetIds {
            var one = input
            one["agent_id"] = targetId
            results.append(await handleDirectSend(
                input: one,
                callerSessionId: callerSessionId,
                callerAgentId: callerAgentId
            ))
        }
        return results.joined(separator: "\n\n")
    }

    private func handleDirectSend(
        input: [String: Any],
        callerSessionId: String,
        callerAgentId: String?
    ) async -> String {
        let targetId = string(input["agent_id"])
        let message = string(input["message"])
        guard !message.isEmpty else { return "Error: `message` is required." }
        guard targetId != callerAgentId else {
            return "Error: that agent_id is you. To think something through, just think it — do not message yourself."
        }
        guard let target = await AgentStore.shared.loadAgent(targetId) else {
            return "No assistant with agent_id \(targetId). Call list_agents for the current roster."
        }
        guard !target.isArchived else {
            return "\(target.name) is archived and is not part of the roster any more. Tell the user rather than working around it."
        }

        let waitSeconds = min(max(int(input["wait_seconds"]) ?? 0, 0), AgentDirectoryTools.maxWaitSeconds)
        let interrupt = bool(input["interrupt"]) ?? false

        guard let targetSession = await AgentStore.shared.openMainSession(for: targetId), !targetSession.isEmpty else {
            return "Could not open \(target.name)'s conversation, so the message was not delivered."
        }

        // Loop guard — see the note at the top of this file.
        if let refusal = relayRefusal(from: callerSessionId, to: targetSession, targetName: target.name) {
            return refusal
        }

        let (vm, isFresh) = ViewModelCache.shared.getOrCreate(for: targetSession)
        if isFresh { await vm.loadSession() }

        if vm.isProcessing || isBusy(sessionId: targetSession) {
            guard interrupt else {
                return """
                    \(target.name) is mid-turn right now, so the message was NOT delivered.

                    It may be answering the user. Either wait and send again, \
                    or resend with interrupt: true if what you have genuinely \
                    supersedes what it is doing.
                    """
            }
            vm.cancel()
            // cancel() flips isProcessing synchronously, so send() below would
            // be accepted immediately — but the cancelled loop is still tearing
            // down and writing to the transcript. A short settle keeps the
            // interrupted turn and the incoming message from interleaving in a
            // conversation the user actually reads.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let sender = await senderLabel(agentId: callerAgentId)
        let inbound = envelope(from: sender, message: message, awaitingReply: waitSeconds > 0)

        // Preserve whatever the user had half-typed in that conversation.
        // send() clears inputText synchronously, so restoring right after the
        // call puts their draft back untouched.
        let draft = vm.inputText
        let messageCountBeforeSend = vm.messages.count
        vm.inputText = inbound
        vm.send()
        let accepted = vm.isProcessing
        vm.inputText = draft

        guard accepted else {
            return """
                \(target.name) did not accept the message — its conversation is \
                at or near its context limit and is waiting on the user to \
                compact it. Nothing was delivered. Tell the user plainly \
                instead of retrying.
                """
        }

        relayOrigin[targetSession] = callerSessionId
        SessionBadgeStore.shared.pushFront(.unread, for: targetSession)
        logger.info("relayed message to agent=\(targetId.prefix(8)) wait=\(waitSeconds)s interrupt=\(interrupt)")

        guard waitSeconds > 0 else {
            scheduleRelayCleanup(targetSession: targetSession, vm: vm)
            return """
                Message delivered to \(target.name). You did not wait, so its \
                reply goes to its own conversation and you will not see it — \
                send with wait_seconds if you need the answer. Do not tell the \
                user you will report back on what it says.
                """
        }

        let landed = await awaitTurn(vm: vm, seconds: waitSeconds)

        guard landed else {
            // Edge deliberately left in place — the recipient is still mid-turn
            // and could still try to answer us, which is exactly what the loop
            // guard exists to catch. The cleanup task retires it.
            scheduleRelayCleanup(targetSession: targetSession, vm: vm)
            return """
                \(target.name) is still working on it after \(waitSeconds)s and \
                the wait ran out. Its answer will land in its own conversation, \
                not here. Either send again with a longer wait_seconds, or tell \
                the user where the answer will show up — do not promise to \
                bring it back yourself.
                """
        }

        relayOrigin[targetSession] = nil

        guard let reply = lastAssistantText(vm: vm, after: messageCountBeforeSend), !reply.isEmpty else {
            return """
                \(target.name) received the message but produced no text reply. \
                Say so plainly rather than inventing what it might have said.
                """
        }

        return """
            \(target.name) replied:

            \(reply)

            That is their answer, in their words. Use it, attribute it to them \
            when it matters, and disagree with it if you have reason to — you \
            are the one talking to the user.
            """
    }

    // MARK: - send_agent_message (pseudo-group)

    private func handleGroupSend(
        input: [String: Any],
        groupId: String,
        callerSessionId: String,
        callerAgentId: String?,
        callerGroupId: String?
    ) async -> String {
        guard let senderId = callerAgentId, !senderId.isEmpty else {
            return "Error: a group A2A message needs an assistant sender."
        }
        let message = string(input["message"])
        guard !message.isEmpty else { return "Error: `message` is required." }
        guard let group = await GroupStore.shared.loadGroup(groupId), !group.isArchived else {
            return "Error: no active group with group_id \(groupId)."
        }
        // A hidden group-member session is permanently attached to one group.
        // Requiring the explicit id to agree prevents a model from accidentally
        // writing a line into a different shared transcript.
        if let callerGroupId, callerGroupId != groupId {
            return "Error: this member session belongs to group_id \(callerGroupId), not \(groupId)."
        }

        let members = await GroupStore.shared.members(of: group)
        let requestedTargets = stringArray(input["agent_id"])
        let atAll = requestedTargets.contains(GroupMentionRouter.everyoneId)
        // `at_all` deliberately wins over ids. That makes a model's overly
        // broad list deterministic and follows the public tool contract.
        let targets = atAll ? [] : requestedTargets
        let canonical: String
        switch GroupMentionRouter.composeA2AMessage(
            message: message,
            targetAgentIds: targets,
            mentionEveryone: atAll,
            senderAgentId: senderId,
            members: members,
            ownerAgentId: group.ownerAgentId
        ) {
        case .success(let text):
            canonical = text
        case .failure(let error):
            return groupSendError(error, group: group)
        }

        if callerGroupId == groupId {
            pendingGroupMessages[callerSessionId, default: []].append(canonical)
            logger.info("queued in-turn group A2A group=\(groupId.prefix(8)) sender=\(senderId.prefix(8)) targets=\(targets.count) all=\(atAll)")
            return "Group message accepted. It will be published as your current turn in \(group.title); the shared transcript router will wake the addressed members. Do not repeat the message in your final text."
        }

        guard let sender = members.first(where: { $0.id == senderId }) else {
            return "Error: you are not a member of \(group.title), so you cannot write to its shared transcript."
        }
        await GroupChatOrchestrator.shared.agentDidSend(
            group: group,
            sender: sender,
            members: members,
            canonicalText: canonical
        )
        logger.info("posted external group A2A group=\(groupId.prefix(8)) sender=\(senderId.prefix(8)) targets=\(targets.count) all=\(atAll)")
        return "Message posted to group \(group.title). The group orchestrator will project the updated shared context to the addressed members."
    }

    /// Called only by GroupChatOrchestrator at the boundary of a member turn.
    /// Multiple tool calls still become one utterance, preserving the group's
    /// one-message-per-member turn accounting.
    func consumePendingGroupMessage(callerSessionId: String) -> String? {
        guard let messages = pendingGroupMessages.removeValue(forKey: callerSessionId),
              !messages.isEmpty else { return nil }
        return messages.joined(separator: "\n")
    }

    func discardPendingGroupMessage(callerSessionId: String) {
        pendingGroupMessages[callerSessionId] = nil
    }

    private func groupSendError(_ error: GroupMentionRouter.A2AError, group: GroupProfile) -> String {
        switch error {
        case .senderNotInGroup:
            return "Error: you are not a member of \(group.title)."
        case .noTargets:
            return "Error: `agent_id` needs at least one group member, or the group owner may pass [\"at_all\"]."
        case .targetNotInGroup(let id):
            return "Error: agent_id \(id) is not a member of \(group.title)."
        case .cannotTargetSelf:
            return "Error: `agent_id` cannot contain the sending assistant."
        case .everyoneRequiresOwner:
            return "Error: only the owner assistant of \(group.title) may pass [\"at_all\"]. Name specific members in `agent_id` instead."
        case .messageContainsMentions:
            return "Error: put every recipient in `agent_id` (or use [\"at_all\"] as owner); do not place @ mentions inside `message`."
        }
    }

    // MARK: - Relay bookkeeping

    /// Refuse a send that would close a loop, or run one too deep.
    private func relayRefusal(from caller: String, to target: String, targetName: String) -> String? {
        var chain: [String] = [caller]
        var cursor = caller
        var hops = 0
        while let upstream = relayOrigin[cursor], hops < Self.maxHops * 2 {
            chain.append(upstream)
            cursor = upstream
            hops += 1
        }
        if chain.contains(target) {
            return """
                Not delivered: \(targetName) is already upstream in this exchange \
                — the message you are answering came from them, directly or \
                through someone else. Answering it here is the reply; sending \
                one back starts a loop. End your turn with the answer instead.
                """
        }
        if chain.count > Self.maxHops {
            return """
                Not delivered: this message has already been passed between \
                \(Self.maxHops) assistants. Handle it yourself or tell the user \
                it needs their call, rather than passing it along again.
                """
        }
        return nil
    }

    /// Drop the relay edge once the recipient's turn ends. Used on the paths
    /// where we are not parked waiting for it ourselves.
    private func scheduleRelayCleanup(targetSession: String, vm: AIChatViewModel) {
        Task { [weak self] in
            // Bounded: a turn that outlives this has long since stopped being
            // part of the relay we are guarding.
            let deadline = Date().addingTimeInterval(TimeInterval(AgentDirectoryTools.maxWaitSeconds))
            while vm.isProcessing, Date() < deadline {
                if Task.isCancelled { break }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
            self?.relayOrigin[targetSession] = nil
        }
    }

    // MARK: - Delivery helpers

    // Waiting for the recipient's turn and reading its answer both moved to
    // AgentTurnAwaiter when group chat needed the same two operations.
    private func awaitTurn(vm: AIChatViewModel, seconds: Int) async -> Bool {
        await AgentTurnAwaiter.awaitTurn(vm: vm, seconds: seconds)
    }

    private func lastAssistantText(vm: AIChatViewModel, after index: Int) -> String? {
        AgentTurnAwaiter.lastAssistantText(vm: vm, after: index)
    }

    /// How the message is presented in the recipient's transcript. The header
    /// is visible to the user on purpose: an assistant they never addressed
    /// speaking in their conversation should never look like it came from them.
    private func envelope(from sender: String, message: String, awaitingReply: Bool) -> String {
        var text = String(localized: "📨 来自助手「\(sender)」的消息：") + "\n\n" + message
        if awaitingReply {
            text += "\n\n" + String(localized: "（对方正在等你的回复，你这一轮的最终文字会原样回传给它。）")
        }
        return text
    }

    private func senderLabel(agentId: String?) async -> String {
        guard let agentId, let agent = await AgentStore.shared.loadAgent(agentId) else {
            return String(localized: "另一个助手")
        }
        let emoji = agent.emoji.isEmpty ? "" : agent.emoji + " "
        return emoji + agent.name
    }

    private func isBusy(sessionId: String) -> Bool {
        if let vm = ViewModelCache.shared.get(for: sessionId), vm.isProcessing { return true }
        return SessionActivityTracker.shared.isActive(sessionId)
    }

    // MARK: - Argument coercion
    //
    // Providers are inconsistent about JSON types — a boolean can arrive as
    // "true" and an integer as "30" — so the tool layer normalizes rather than
    // failing on a well-formed call that was merely stringly typed.

    private func string(_ value: Any?) -> String {
        guard let value = value as? String else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let s = value as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
        if let i = value as? Int { return i != 0 }
        return nil
    }

    private func stringArray(_ value: Any?) -> [String] {
        let raw: [Any]
        if let values = value as? [Any] {
            raw = values
        } else if let values = value as? [String] {
            raw = values
        } else {
            return []
        }
        var seen = Set<String>()
        return raw.compactMap { item in
            guard let value = item as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    /// Accept `#RRGGBB` or a bare `RRGGBB`; reject anything else so a bad value
    /// falls through to the palette rather than to AgentAccent's grey fallback.
    private func normalizedHex(_ raw: String) -> String? {
        var value = raw
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, UInt32(value, radix: 16) != nil else { return nil }
        return "#" + value.uppercased()
    }
}
