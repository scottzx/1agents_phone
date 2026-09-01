//
//  GroupChatOrchestrator.swift
//  Minis
//
//  Routes group messages in FIFO order. Every selected member becomes an
//  independent session task in the shared global FIFO; the next source
//  message waits for all tasks produced by the current message to settle.
//
//  Modelled on grok-bot 0.18's group-chat-orchestrator.ts, while allowing a
//  room to keep collaborating for as long as members keep addressing peers:
//
//  - **Per-member tasks.** @6 creates six global queue entries immediately;
//    the shared five session slots, not the group message, control admission.
//  - **FIFO barrier.** A queued reply cannot wake more members until all tasks
//    caused by the current source message have settled.
//  - **Quiescence ends the run.** The loop stops when nobody is addressed or
//    every selected member passes, rather than after a fixed round count.
//  - **A failed member turn is a pass, not a room-wide failure.**
//

import Foundation

@MainActor
final class GroupChatOrchestrator {
    static let shared = GroupChatOrchestrator(
        sessionRunner: IOSAgentSessionRunner.shared,
        transcriptPresenter: IOSGroupTranscriptPresenter.shared
    )

    private let repository: IOSGroupChatRepository
    private let transcriptPresenter: any GroupTranscriptPresenting
    private let sharedEngine: GroupChatEngine
    private var engineRunning: Set<String> = []

    init(sessionRunner: any AgentSessionRunning, transcriptPresenter: any GroupTranscriptPresenting) {
        let repository = IOSGroupChatRepository(sessionRunner: sessionRunner, transcriptPresenter: transcriptPresenter)
        self.repository = repository
        self.transcriptPresenter = transcriptPresenter
        self.sharedEngine = GroupChatEngine(repository: repository)
    }

    func isRunning(groupId: String) -> Bool { engineRunning.contains(groupId) }

    /// Debug/inspection projection of the persisted shared transcript. Keep
    /// this adapter on the orchestrator so callers do not reach into the
    /// repository actor or duplicate its filtering of tool-only audit rows.
    func transcript(of group: GroupProfile) async -> [GroupMessage] {
        guard let room = await repository.room(id: group.id) else { return [] }
        return await repository.transcript(room: room)
    }

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
        guard !members.isEmpty else { return nil }
        let wasRunning = engineRunning.contains(groupId)
        if !wasRunning {
            setTranscriptBusy(group: group, true)
            bindHardware(group: group, members: members)
            pushState(.thinking, group: group, name: group.title, brief: userText)
            engineRunning.insert(groupId)
        }
        let result = await sharedEngine.send(roomID: groupId, text: userText)
        if !wasRunning {
            engineRunning.remove(groupId)
            pushState(.done, group: group, name: group.title)
            setTranscriptBusy(group: group, false)
        }
        return result
    }

    /// Publish an A2A line which is already stored in the shared transcript,
    /// then let the same engine FIFO queue route it. The explicit
    /// seed is essential because member rows normally form a new run cursor.
    func agentDidSend(
        group: GroupProfile,
        sender: GroupMember,
        members: [GroupMember],
        canonicalText: String,
        callerSessionId: String? = nil
    ) async {
        await repository.appendPersistedMember(roomID: group.id, memberID: sender.id, text: canonicalText)
        deliverToHardware(canonicalText, group: group, members: members, from: sender)
        let trigger = GroupMessage.member(sender.id, canonicalText)
        Task {
            let result = await self.resume(group: group, members: members, seed: trigger)
            if let callerSessionId, callerSessionId != group.sessionId, let result, !result.isEmpty {
                await AsyncTaskNoticeManager.shared.postNotice(
                    sourceSessionId: callerSessionId,
                    taskType: "group",
                    taskId: group.id,
                    title: group.title,
                    status: "done",
                    result: result
                )
            }
        }
    }

    /// Stop the shared room loop and discard queued blocks. The epoch gate
    /// rejects member results that return after cancellation is observed.
    func cancel(groupId: String) {
        Task { await sharedEngine.cancel(roomID: groupId) }
    }

    @discardableResult
    private func resume(group: GroupProfile, members: [GroupMember], seed: GroupMessage) async -> String? {
        let wasRunning = engineRunning.contains(group.id)
        if !wasRunning {
            engineRunning.insert(group.id)
            setTranscriptBusy(group: group, true)
            bindHardware(group: group, members: members)
            pushState(.thinking, group: group, name: group.title, brief: seed.text)
        }
        let result = await sharedEngine.resume(roomID: group.id, seededMessages: [seed])
        if !wasRunning {
            engineRunning.remove(group.id)
            pushState(.done, group: group, name: group.title)
            setTranscriptBusy(group: group, false)
        }
        return result
    }


    private func setTranscriptBusy(group: GroupProfile, _ busy: Bool) {
        transcriptPresenter.setBusy(sessionId: group.sessionId, busy)
    }

    // MARK: - Hardware

    // Deliberately fire-and-forget and failure-tolerant: the room must run
    // identically whether or not a board is connected, and every one of these
    // is a no-op when it is not.

    private func bindHardware(group: GroupProfile, members: [GroupMember]) {
        guard HardwareBridgeCoordinator.shared.activeGroupId == group.id else { return }
        // Keyed by `group.id`, not by the session: that is the id this group
        // occupies in the chat-list catalog, and the id the board echoes back
        // when the user opens the room on the device.
        DeviceRosterService.shared.bind(
            conversationId: group.id,
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

/// iOS persistence/session adapter for the shared Foundation-only engine.
/// The engine owns scheduling; this adapter owns ChatStore rows, the visible
/// transcript projection and the platform's `AgentSessionRunning` bridge.
private actor IOSGroupChatRepository: GroupChatRepository {
    private let sessionRunner: any AgentSessionRunning
    private let transcriptPresenter: any GroupTranscriptPresenting

    init(sessionRunner: any AgentSessionRunning, transcriptPresenter: any GroupTranscriptPresenting) {
        self.sessionRunner = sessionRunner
        self.transcriptPresenter = transcriptPresenter
    }

    func room(id: String) async -> GroupChatRoom? {
        guard let group = await GroupStore.shared.loadGroup(id) else { return nil }
        let members = await GroupStore.shared.members(of: group).map {
            GroupChatParticipant(id: $0.id, name: $0.name, title: $0.title, emoji: $0.emoji, accentColor: $0.accentColor, summary: $0.summary, slot: $0.slot)
        }
        return GroupChatRoom(id: group.id, sessionID: group.sessionId, title: group.title, mode: group.mode, ownerMemberID: group.ownerAgentId, members: members)
    }

    func transcript(room: GroupChatRoom) async -> [GroupMessage] {
        let raw = await ChatStore.shared.loadMessages(sessionId: room.sessionID)
        return raw.compactMap { row in
            let text = row.parts.compactMap { if case .text(let value) = $0 { value } else { nil } }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch row.role {
            case .user: return row.isToolResultOnly ? nil : .user(text)
            case .assistant: return row.senderAgentId.map { .member($0, text) }
            }
        }
    }

    func appendUser(room: GroupChatRoom, text: String) async {
        await append(room: room, senderID: nil, text: text, isUser: true)
    }

    func appendMember(room: GroupChatRoom, memberID: String, text: String) async {
        await append(room: room, senderID: memberID, text: text, isUser: false)
    }

    /// An A2A sender has already made the deliberate decision to speak. Store
    /// that member row once, before `GroupChatEngine.resume` routes the same
    /// value as an explicit seed.
    func appendPersistedMember(roomID: String, memberID: String, text: String) async {
        guard let room = await room(id: roomID) else { return }
        await appendMember(room: room, memberID: memberID, text: text)
    }

    func runMemberTurn(_ turn: GroupChatMemberTurn) async -> GroupChatMemberTurnResult {
        guard let group = await GroupStore.shared.loadGroup(turn.room.id),
              let member = (await GroupStore.shared.members(of: group)).first(where: { $0.id == turn.participant.id }),
              let sessionID = await GroupStore.shared.openMemberSession(group: group, agentId: member.id) else {
            return .skipped
        }
        let system = GroupChatPrompt.memberSystemBlock(member: member, groupId: group.id, groupTitle: group.title, mode: group.mode, isOwner: member.id == group.ownerAgentId, peers: (await GroupStore.shared.members(of: group)).filter { $0.id != member.id })
        let result = await sessionRunner.run(AgentSessionRunRequest(
            sessionId: sessionID,
            prompt: turn.prompt,
            agentId: member.id,
            groupId: group.id,
            source: "group",
            systemPromptBlock: system,
            thinkingLevel: ThinkingLevel.off.rawValue,
            timeoutSeconds: 0
        ))
        return GroupChatMemberTurnResult(text: result.text, accepted: result.accepted, timedOut: result.timedOut, cancelled: result.cancelled)
    }

    private func append(room: GroupChatRoom, senderID: String?, text: String, isUser: Bool) async {
        let members: [GroupMember]
        if let group = await GroupStore.shared.loadGroup(room.id) {
            members = await GroupStore.shared.members(of: group)
        } else {
            members = []
        }
        var raw = RawMessage(id: UUID().uuidString, sessionId: room.sessionID, role: isUser ? .user : .assistant, parts: [.text(text)], createdAt: Date())
        raw.senderAgentId = senderID
        await ChatStore.shared.appendMessage(raw)
        await transcriptPresenter.append(sessionId: room.sessionID, senderAgentId: senderID, text: GroupMentionRouter.render(text, members: members), isUser: isUser)
    }
}
