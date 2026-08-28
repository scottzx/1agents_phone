//
//  GroupChatOrchestrator.swift
//  Minis
//
//  Runs a group turn: decide who speaks, let them speak one at a time, and
//  write what they said back into the room.
//
//  Modelled on grok-bot 0.18's group-chat-orchestrator.ts, including the parts
//  that look like limitations and are not:
//
//  - **Strictly serial.** One `await` per member, never a task group. Two
//    agents talking at once would produce a transcript nobody can follow, and
//    it would also blow through SessionConcurrencyManager's five slots the
//    moment the user has another conversation open.
//  - **Four caps** (rounds x total messages x one message per member per turn x
//    "everyone passed"). Together they make a runaway room structurally
//    impossible, which is a much stronger guarantee than the chain-based hop
//    guard AgentDirectoryCoordinator uses for point-to-point relays — a group's
//    natural shape is fan-out, and a chain guard does not bound fan-out.
//  - **A failed member turn is a pass, not a room-wide failure.**
//

import Foundation

@MainActor
final class GroupChatOrchestrator {
    static let shared = GroupChatOrchestrator()

    private let logger = AppLogger(category: "GroupChat")

    /// Bumped every time a user sends into a group. Every step of a running
    /// orchestration re-checks it, so a second message cancels the first one's
    /// remaining rounds instead of interleaving with them (grok's turn epoch).
    private var epochs: [String: Int] = [:]
    /// Groups with an orchestration in flight. A second send never starts a
    /// second loop — two loops taking turns in one room would interleave.
    private var running: Set<String> = []
    /// Groups whose in-flight loop had already passed its last round when a new
    /// message arrived. Drained when that loop exits, so the message gets an
    /// answer instead of sitting in the transcript unanswered.
    private var pendingRerun: Set<String> = []

    private init() {}

    func isRunning(groupId: String) -> Bool { running.contains(groupId) }

    // MARK: - Entry points

    /// Fire-and-forget entry used by the chat UI: persist the user's line, then
    /// let the room answer in the background so the composer returns at once.
    func userDidSend(groupId: String, text: String) {
        Task { _ = await run(groupId: groupId, userText: text) }
    }

    /// Awaitable entry, for callers that need the closing line — the hardware
    /// bridge speaks it.
    ///
    /// Returns the last thing said in the room, or nil if nobody spoke.
    @discardableResult
    func run(groupId: String, userText: String) async -> String? {
        guard let group = await GroupStore.shared.loadGroup(groupId) else { return nil }
        let members = await GroupStore.shared.members(of: group)
        guard !members.isEmpty else {
            logger.warning("group \(groupId.prefix(8)) has no resolvable members")
            return nil
        }

        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            await postUserMessage(group: group, members: members, text: trimmed)
        }

        // A message sent while the room is still talking is not dropped and
        // does not start a second loop: the running loop re-reads the
        // transcript at the top of every round, so it picks this up as part of
        // the next round's window. Only if it has no rounds left does it need
        // to be re-driven afterwards.
        guard !running.contains(groupId) else {
            pendingRerun.insert(groupId)
            logger.info("group \(groupId.prefix(8)) is mid-turn — message joins the running room")
            return nil
        }

        running.insert(groupId)
        let epoch = bumpEpoch(groupId)
        // Borrow the transcript vm's `isProcessing` so the composer disables
        // itself and offers Stop while the room is talking — exactly what it
        // does for a normal turn. This vm runs no agent loop, so the flag is
        // only ever set from here and from cancel().
        setTranscriptBusy(group: group, true)
        bindHardware(group: group, members: members)
        pushState(.thinking, group: group, name: group.title, brief: trimmed)

        let closing: String?
        switch group.mode {
        case .freeform:
            closing = await runFreeform(group: group, members: members, epoch: epoch)
        case .roundtable:
            closing = await runRoundtable(group: group, members: members, epoch: epoch, topic: trimmed)
        }

        pushState(.done, group: group, name: group.title)
        running.remove(groupId)
        setTranscriptBusy(group: group, false)

        // Something arrived after this loop was out of rounds. Answer it.
        if pendingRerun.remove(groupId) != nil, isCurrent(groupId, epoch) {
            return await run(groupId: groupId, userText: "")
        }
        return closing
    }

    /// Stop a room mid-turn. The member currently speaking finishes into its
    /// own session, but nothing further is posted to the room.
    func cancel(groupId: String) {
        _ = bumpEpoch(groupId)
        pendingRerun.remove(groupId)
    }

    // MARK: - Freeform

    private func runFreeform(
        group: GroupProfile,
        members: [GroupMember],
        epoch: Int
    ) async -> String? {
        var history = await transcript(of: group)
        // Everything up to and including the last thing a member said has
        // already been answered; what follows is what this turn responds to.
        // Usually that is one user message, but it is two when the user sent
        // again while the room was still thinking.
        var consumed = history.lastIndex { $0.speaker.memberId != nil }.map { $0 + 1 } ?? 0
        var totalSpoken = 0
        var closing: String?

        for round in 0..<GroupChatLimits.maxRounds {
            guard isCurrent(group.id, epoch) else { return closing }

            // Re-read so a line the user typed mid-round joins THIS turn rather
            // than stranding until they send again.
            history = await transcript(of: group)
            let newMessages = Array(history[min(consumed, history.count)...])
            consumed = history.count
            guard !newMessages.isEmpty else { break }

            let resolution = GroupMentionRouter.resolveResponders(
                members: members,
                newMessages: newMessages,
                history: history,
                ownerAgentId: group.ownerAgentId
            )
            for offender in resolution.downgradedEveryoneBy {
                let name = members.first { $0.id == offender }?.name ?? offender
                logger.info("group \(group.id.prefix(8)): \(name) 用了 @所有人 但不是群主，已降级为具名 @")
            }
            for offender in resolution.usedLooseNamesBy {
                let name = members.first { $0.id == offender }?.name ?? offender
                logger.info("group \(group.id.prefix(8)): \(name) 用名字而不是 <@id> 做的 @，这次按名字兜底了；改名后会失效")
            }
            guard !resolution.responderIds.isEmpty else { break }
            logger.info("group \(group.id.prefix(8)) round \(round) responders=\(resolution.responderIds.count) reason=\(resolution.reason.rawValue)")

            var spokeThisRound = 0
            for memberId in GroupMentionRouter.orderRoundSpeakers(resolution.responderIds, round: round) {
                guard isCurrent(group.id, epoch) else { return closing }
                guard totalSpoken < GroupChatLimits.maxMemberTurns else {
                    logger.info("group \(group.id.prefix(8)) hit the \(GroupChatLimits.maxMemberTurns)-message cap")
                    return closing
                }
                guard let member = members.first(where: { $0.id == memberId }) else { continue }

                let prompt = GroupChatPrompt.turnPrompt(
                    member: member,
                    groupTitle: group.title,
                    peers: members.filter { $0.id != member.id },
                    allMembers: members,
                    newMessages: GroupMentionRouter.messagesSinceMemberLastSpoke(history, memberId: member.id)
                )
                guard let said = await speak(group: group, member: member, members: members, prompt: prompt) else {
                    continue
                }
                // Appended locally too, so a later speaker in the SAME round
                // sees what was just said without another store round-trip.
                history.append(.member(member.id, said))
                totalSpoken += 1
                spokeThisRound += 1
                closing = said
            }

            // Everybody passed. The room is out of things to say, which is a
            // better stop condition than any counter.
            guard spokeThisRound > 0 else { break }
        }
        return closing
    }

    // MARK: - Roundtable

    /// Fixed order, every speaker sees every prior opinion, owner sums up
    /// (DEMO_PRD.md §3). Deterministic on purpose: this is the mode meant to be
    /// demoed, and a model deciding who talks next is the one thing guaranteed
    /// to behave differently on stage than it did in rehearsal.
    private func runRoundtable(
        group: GroupProfile,
        members: [GroupMember],
        epoch: Int,
        topic: String
    ) async -> String? {
        let experts = members.filter { $0.id != group.ownerAgentId }
        let moderator = members.first { $0.id == group.ownerAgentId }

        var opinions: [GroupMessage] = []
        for member in experts {
            guard isCurrent(group.id, epoch) else { return opinions.last?.text }
            let prompt = GroupChatPrompt.roundtableTurnPrompt(
                member: member,
                groupTitle: group.title,
                peers: members.filter { $0.id != member.id },
                allMembers: members,
                topic: topic,
                priorOpinions: opinions
            )
            guard let said = await speak(group: group, member: member, members: members, prompt: prompt) else {
                continue
            }
            opinions.append(.member(member.id, said))
        }

        guard let moderator, isCurrent(group.id, epoch) else { return opinions.last?.text }
        let prompt = GroupChatPrompt.roundtableSummaryPrompt(
            member: moderator,
            groupTitle: group.title,
            peers: members.filter { $0.id != moderator.id },
            allMembers: members,
            topic: topic,
            opinions: opinions
        )
        return await speak(group: group, member: moderator, members: members, prompt: prompt)
            ?? opinions.last?.text
    }

    // MARK: - One member's turn

    /// Run one member's turn and publish what it said. Returns nil when the
    /// member passed, failed or timed out — all three are "the room moves on".
    private func speak(
        group: GroupProfile,
        member: GroupMember,
        members: [GroupMember],
        prompt: String
    ) async -> String? {
        pushState(
            DeviceRoundtableState.speaking(slot: member.slot, isOwner: member.id == group.ownerAgentId),
            group: group,
            name: member.name
        )

        guard let said = await runMemberTurn(group: group, member: member, members: members, prompt: prompt) else {
            return nil
        }
        guard !GroupMentionRouter.isPass(said) else {
            logger.info("group \(group.id.prefix(8)): \(member.name) passed")
            return nil
        }
        await postMemberMessage(group: group, member: member, members: members, text: said)
        deliverToHardware(said, group: group, members: members, from: member)
        return said
    }

    /// Drive the member's own session through one turn.
    ///
    /// The mechanics are AgentDirectoryCoordinator.handleSend's, which have
    /// been delivering inter-agent messages for a while: set inputText, send,
    /// park, read the last assistant text. The differences are that the target
    /// is the member's group thread rather than its 1:1 conversation, and that
    /// a busy member is interrupted rather than refused — in a room, being
    /// addressed is not optional.
    private func runMemberTurn(
        group: GroupProfile,
        member: GroupMember,
        members: [GroupMember],
        prompt: String
    ) async -> String? {
        guard let sessionId = await GroupStore.shared.openMemberSession(group: group, agentId: member.id) else {
            logger.error("could not open a group session for \(member.name)")
            return nil
        }

        let (vm, isFresh) = ViewModelCache.shared.getOrCreate(for: sessionId)
        if isFresh { await vm.loadSession() }
        vm.groupId = group.id
        vm.agentId = member.id
        vm.agentRole = .main
        // "group" joins "shortcut" and "hardware" in send()'s headless set: a
        // member's thread has no UI to answer a compact prompt, so a full
        // context must auto-compact rather than stall the room.
        vm.sessionSource = "group"
        // Re-assembled every turn rather than once: the roster, the owner and
        // the mode can all have changed since this member last spoke.
        vm.groupPromptBlock = GroupChatPrompt.memberSystemBlock(
            member: member,
            groupTitle: group.title,
            mode: group.mode,
            isOwner: member.id == group.ownerAgentId,
            peers: members.filter { $0.id != member.id }
        )

        if vm.isProcessing {
            vm.cancel()
            // cancel() flips isProcessing synchronously but the cancelled loop
            // is still writing to the transcript; the same 0.5s settle
            // AgentDirectoryCoordinator uses keeps the two turns from
            // interleaving in a transcript the user can read.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let countBefore = vm.messages.count
        let draft = vm.inputText
        vm.inputText = prompt
        vm.send()
        let accepted = vm.isProcessing
        vm.inputText = draft

        guard accepted else {
            logger.warning("\(member.name) 拒绝了群消息（上下文已满）")
            return nil
        }
        guard await AgentTurnAwaiter.awaitTurn(vm: vm, seconds: GroupChatLimits.memberTurnTimeoutSeconds) else {
            logger.warning("\(member.name) 超时未完成发言，本轮跳过")
            return nil
        }
        return AgentTurnAwaiter.lastAssistantText(vm: vm, after: countBefore)
    }

    // MARK: - Transcript

    /// Project the stored transcript into the value type the router and the
    /// prompt builder work with. Tool calls, thinking and everything else a
    /// member did privately are dropped here — only what was said aloud
    /// becomes a GroupMessage.
    func transcript(of group: GroupProfile) async -> [GroupMessage] {
        let raw = await ChatStore.shared.loadMessages(sessionId: group.sessionId)
        return raw.compactMap { row -> GroupMessage? in
            let text = row.parts.compactMap { part -> String? in
                if case .text(let value) = part { return value }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            switch row.role {
            case .user:
                guard !row.isToolResultOnly else { return nil }
                return .user(text)
            case .assistant:
                guard let sender = row.senderAgentId else { return nil }
                return .member(sender, text)
            }
        }
    }

    private func postUserMessage(group: GroupProfile, members: [GroupMember], text: String) async {
        await post(
            group: group,
            role: .user,
            senderAgentId: nil,
            text: text,
            display: GroupMentionRouter.render(text, members: members),
            uiRole: .user
        )
    }

    private func postMemberMessage(
        group: GroupProfile,
        member: GroupMember,
        members: [GroupMember],
        text: String
    ) async {
        await post(
            group: group,
            role: .assistant,
            senderAgentId: member.id,
            text: text,
            display: GroupMentionRouter.render(text, members: members),
            uiRole: .assistant
        )
    }

    /// Append one line to the room: to SQLite, and to the live transcript view
    /// model when the user is looking at it.
    /// - Parameters:
    ///   - text: canonical form, with `<@id>` mentions. This is what is stored
    ///     and what routing and the LLM prompt read.
    ///   - display: the same line with mentions rendered as names, for the
    ///     transcript the user is looking at right now. On a later reload
    ///     loadSession renders the stored row the same way.
    private func post(
        group: GroupProfile,
        role: MessageRole,
        senderAgentId: String?,
        text: String,
        display: String,
        uiRole: ChatMessageRole
    ) async {
        var raw = RawMessage(
            id: UUID().uuidString,
            sessionId: group.sessionId,
            role: role,
            parts: [.text(text)],
            createdAt: Date()
        )
        raw.senderAgentId = senderAgentId
        await ChatStore.shared.appendMessage(raw)

        guard let vm = ViewModelCache.shared.get(for: group.sessionId) else { return }
        let message = ChatMessage(role: uiRole, content: uiRole == .user ? display : "")
        message.senderAgentId = senderAgentId
        if uiRole == .assistant {
            message.blocks = [AssistantBlock(kind: .text, content: display)]
        }
        vm.messages.append(message)
    }

    private func setTranscriptBusy(group: GroupProfile, _ busy: Bool) {
        ViewModelCache.shared.get(for: group.sessionId)?.isProcessing = busy
    }

    // MARK: - Epochs

    private func bumpEpoch(_ groupId: String) -> Int {
        let next = (epochs[groupId] ?? 0) + 1
        epochs[groupId] = next
        return next
    }

    private func isCurrent(_ groupId: String, _ epoch: Int) -> Bool {
        epochs[groupId] == epoch
    }

    // MARK: - Hardware

    // Deliberately fire-and-forget and failure-tolerant: the room must run
    // identically whether or not a board is connected, and every one of these
    // is a no-op when it is not.

    private func bindHardware(group: GroupProfile, members: [GroupMember]) {
        guard HardwareBridgeCoordinator.shared.activeGroupId == group.id else { return }
        DeviceRosterService.shared.bind(
            conversationId: group.sessionId,
            title: group.title,
            agentIds: members.map(\.id)
        )
    }

    private func pushState(
        _ state: DeviceRoundtableState,
        group: GroupProfile,
        name: String,
        brief: String = ""
    ) {
        guard isBoundToDevice(group) else { return }
        HardwareBridgeCoordinator.shared.sendState(state, name: name, brief: brief)
    }

    private func deliverToHardware(
        _ text: String,
        group: GroupProfile,
        members: [GroupMember],
        from member: GroupMember
    ) {
        guard isBoundToDevice(group) else { return }
        // Rendered, not canonical: a 240x240 round screen showing a UUID is
        // worse than useless.
        HardwareBridgeCoordinator.shared.deliverGroupMessage(
            GroupMentionRouter.render(text, members: members),
            fromAgentId: member.id
        )
    }

    /// Only the room the device is actually pointed at drives the screen. A
    /// group running in the background must not light up nodes for a
    /// conversation the user is not in.
    private func isBoundToDevice(_ group: GroupProfile) -> Bool {
        HardwareBridgeCoordinator.shared.activeGroupId == group.id
    }
}
