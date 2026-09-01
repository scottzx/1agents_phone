import Foundation

/// Platform-neutral description of a room. iOS maps `GroupProfile` into this
/// value; the desktop Runtime maps its persisted group record into the same
/// value. Keeping the loop on these small values prevents either store from
/// becoming the orchestration authority.
public struct GroupChatRoom: Sendable, Equatable {
    public let id: String
    public let sessionID: String
    public let title: String
    public let mode: GroupChatMode
    public let ownerMemberID: String?
    public let members: [GroupChatParticipant]

    public init(id: String, sessionID: String, title: String, mode: GroupChatMode, ownerMemberID: String?, members: [GroupChatParticipant]) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.mode = mode
        self.ownerMemberID = ownerMemberID
        self.members = members
    }
}

public struct GroupChatParticipant: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let title: String
    public let emoji: String
    public let accentColor: String
    public let summary: String
    public let slot: Int

    public init(id: String, name: String, title: String = "", emoji: String = "", accentColor: String = "#5B8DEF", summary: String = "", slot: Int) {
        self.id = id
        self.name = name
        self.title = title
        self.emoji = emoji
        self.accentColor = accentColor
        self.summary = summary
        self.slot = slot
    }

    fileprivate var member: GroupMember {
        GroupMember(id: id, name: name, title: title, emoji: emoji, accentColor: accentColor, summary: summary, slot: slot)
    }
}

public struct GroupChatMemberTurn: Sendable {
    public let room: GroupChatRoom
    public let participant: GroupChatParticipant
    public let prompt: String
    public let round: Int

    public init(room: GroupChatRoom, participant: GroupChatParticipant, prompt: String, round: Int) {
        self.room = room
        self.participant = participant
        self.prompt = prompt
        self.round = round
    }
}

public struct GroupChatMemberTurnResult: Sendable, Equatable {
    public let text: String?
    public let accepted: Bool
    public let timedOut: Bool
    public let cancelled: Bool

    public init(text: String?, accepted: Bool = true, timedOut: Bool = false, cancelled: Bool = false) {
        self.text = text
        self.accepted = accepted
        self.timedOut = timedOut
        self.cancelled = cancelled
    }

    public static let skipped = GroupChatMemberTurnResult(text: nil, accepted: false)
}

public enum GroupChatEngineEvent: Sendable, Equatable {
    case started(roomID: String)
    case memberStarted(roomID: String, memberID: String, round: Int)
    case memberFinished(roomID: String, memberID: String, text: String?, skipped: Bool)
    case completed(roomID: String)
}

/// Repository boundary for group orchestration. Implementations own their
/// persistence and their member execution mechanism (iOS adapts
/// `AgentSessionRunning`; macOS adapts `AgentRuntime`'s provider turn).
public protocol GroupChatRepository: Sendable {
    func room(id: String) async -> GroupChatRoom?
    func transcript(room: GroupChatRoom) async -> [GroupMessage]
    func appendUser(room: GroupChatRoom, text: String) async
    func appendMember(room: GroupChatRoom, memberID: String, text: String) async
    func runMemberTurn(_ turn: GroupChatMemberTurn) async -> GroupChatMemberTurnResult
}

public protocol GroupChatEventSink: Sendable {
    func emit(_ event: GroupChatEngineEvent) async
}

public struct NoopGroupChatEventSink: GroupChatEventSink {
    public init() {}
    public func emit(_ event: GroupChatEngineEvent) async {}
}

/// The shared room scheduler for iOS and macOS. Each public message is routed in
/// FIFO order and immediately expands into one independent session task per
/// addressed member. The repository/session executor owns global admission
/// capacity; the room does not treat the message as one combined execution.
/// The next public message waits until all tasks produced by the current one
/// settle, and public replies re-enter the FIFO in arrival order.
public actor GroupChatEngine {
    private enum PendingMessage: Sendable {
        case user(id: UUID, text: String)
        case message(GroupMessage)
    }

    private let repository: any GroupChatRepository
    private let events: any GroupChatEventSink
    private var epochs: [String: Int] = [:]
    private var running: Set<String> = []
    private var pendingMessages: [String: [PendingMessage]] = [:]
    private var activeRooms: [String: GroupChatRoom] = [:]
    private var userPreparations: [UUID: Task<GroupMessage?, Never>] = [:]
    private var lastUserPreparation: [String: Task<GroupMessage?, Never>] = [:]

    public init(
        repository: any GroupChatRepository,
        events: any GroupChatEventSink = NoopGroupChatEventSink()
    ) {
        self.repository = repository
        self.events = events
    }

    public func isRunning(roomID: String) -> Bool { running.contains(roomID) }

    public func cancel(roomID: String) {
        _ = bumpEpoch(roomID)
        pendingMessages.removeValue(forKey: roomID)
    }

    @discardableResult
    public func send(roomID: String, text: String) async -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return await begin(roomID: roomID, incomingMessages: [.user(id: UUID(), text: text)])
    }

    /// Route lines which are already present in the transcript without
    /// appending a duplicate user row. This is used by A2A handoffs, whose
    /// sender has already published an assistant row before it wakes the room.
    @discardableResult
    public func resume(roomID: String, seededMessages: [GroupMessage]) async -> String? {
        guard !seededMessages.isEmpty else { return nil }
        return await begin(roomID: roomID, incomingMessages: seededMessages.map(PendingMessage.message))
    }

    private func begin(roomID: String, incomingMessages: [PendingMessage]) async -> String? {
        // Enqueue before the first suspension point. Otherwise two near-simultaneous
        // sends can be reordered by whichever asynchronous room lookup finishes
        // first, violating the room's FIFO contract before scheduling even begins.
        pendingMessages[roomID, default: []].append(contentsOf: incomingMessages)
        if let room = activeRooms[roomID] {
            scheduleUserPreparations(incomingMessages, room: room)
        }

        guard !running.contains(roomID) else { return nil }
        running.insert(roomID)
        let epoch = bumpEpoch(roomID)
        guard let room = await repository.room(id: roomID), !room.members.isEmpty,
              isCurrent(roomID, epoch) else {
            running.remove(roomID)
            pendingMessages.removeValue(forKey: roomID)
            return nil
        }
        activeRooms[roomID] = room
        scheduleUserPreparations(pendingMessages[roomID] ?? [], room: room)
        await events.emit(.started(roomID: roomID))
        let closing: String?
        switch room.mode {
        case .freeform:
            closing = await runFreeform(room: room, epoch: epoch)
        case .roundtable:
            closing = await drainRoundtable(room: room, epoch: epoch)
        }
        running.remove(roomID)
        activeRooms.removeValue(forKey: roomID)
        lastUserPreparation.removeValue(forKey: roomID)
        await events.emit(.completed(roomID: roomID))
        // A send may arrive after cancellation while the cancelled member task
        // is still unwinding. It observes `running`, so make sure its queued
        // block gets a fresh epoch once the old run releases the room.
        if pendingMessages[roomID]?.isEmpty == false {
            return await begin(roomID: roomID, incomingMessages: [])
        }
        return closing
    }

    private func runFreeform(room: GroupChatRoom, epoch: Int) async -> String? {
        let members = room.members.map(\.member)
        let history = await repository.transcript(room: room)
        var lastProcessedMemberID = history.reversed().compactMap { $0.speaker.memberId }.first
        var closing: String?
        var messageIndex = 0

        while isCurrent(room.id, epoch), let pending = dequeueMessage(roomID: room.id) {
            guard let message = await materialize(pending, room: room), isCurrent(room.id, epoch) else {
                continue
            }
            let routingHistory = lastProcessedMemberID.map { [GroupMessage.member($0, "")] } ?? []
            let resolution = GroupMentionRouter.resolveResponders(
                members: members,
                newMessages: [message],
                history: routingHistory + [message],
                ownerAgentId: room.ownerMemberID
            )
            if let sender = message.speaker.memberId { lastProcessedMemberID = sender }
            guard !resolution.responderIds.isEmpty else {
                messageIndex += 1
                continue
            }

            let turns = resolution.responderIds.compactMap { memberID -> (GroupChatParticipant, String)? in
                guard let participant = room.members.first(where: { $0.id == memberID }) else { return nil }
                let prompt = GroupChatPrompt.turnPrompt(
                    member: participant.member,
                    groupTitle: room.title,
                    peers: members.filter { $0.id != memberID },
                    allMembers: members,
                    newMessages: [message]
                )
                return (participant, prompt)
            }
            let currentMessageIndex = messageIndex

            await withTaskGroup(of: String?.self) { group in
                // Submit every addressed session task now, in routing order.
                // On iOS each task then joins SessionConcurrencyManager's one
                // global FIFO, shared with normal conversations and A2A. Thus
                // an @6 message creates six queue entries immediately: five
                // may run and the sixth waits for a global slot.
                for (participant, prompt) in turns {
                    group.addTask {
                        await self.speak(
                            room: room,
                            participant: participant,
                            prompt: prompt,
                            round: currentMessageIndex,
                            epoch: epoch,
                            enqueueReply: true
                        )
                    }
                }
                while let answer = await group.next() {
                    guard isCurrent(room.id, epoch) else {
                        group.cancelAll()
                        break
                    }
                    if let answer { closing = answer }
                }
            }
            messageIndex += 1
        }
        return closing
    }

    private func drainRoundtable(room: GroupChatRoom, epoch: Int) async -> String? {
        var closing: String?
        var messageIndex = 0
        while isCurrent(room.id, epoch), let pending = dequeueMessage(roomID: room.id) {
            guard let message = await materialize(pending, room: room), isCurrent(room.id, epoch) else {
                continue
            }
            if let answer = await runRoundtable(room: room, epoch: epoch, topic: message.text, round: messageIndex) {
                closing = answer
            }
            messageIndex += 1
        }
        return closing
    }

    private func runRoundtable(room: GroupChatRoom, epoch: Int, topic: String, round: Int) async -> String? {
        let members = room.members.map(\.member)
        let experts = room.members.filter { $0.id != room.ownerMemberID }
        let moderator = room.members.first { $0.id == room.ownerMemberID }
        var opinions: [GroupMessage] = []

        await withTaskGroup(of: GroupMessage?.self) { group in
            for participant in experts {
                let member = participant.member
                let prompt = GroupChatPrompt.roundtableTurnPrompt(
                    member: member,
                    groupTitle: room.title,
                    peers: members.filter { $0.id != member.id },
                    allMembers: members,
                    topic: topic,
                    priorOpinions: []
                )
                group.addTask {
                    guard let answer = await self.speak(
                        room: room,
                        participant: participant,
                        prompt: prompt,
                        round: round,
                        epoch: epoch,
                        enqueueReply: false
                    ) else { return nil }
                    return .member(member.id, answer)
                }
            }
            while let opinion = await group.next() {
                guard isCurrent(room.id, epoch) else {
                    group.cancelAll()
                    break
                }
                if let opinion { opinions.append(opinion) }
            }
        }

        guard let moderator, isCurrent(room.id, epoch) else { return opinions.last?.text }
        let member = moderator.member
        let prompt = GroupChatPrompt.roundtableSummaryPrompt(member: member, groupTitle: room.title, peers: members.filter { $0.id != member.id }, allMembers: members, topic: topic, opinions: opinions)
        return await speak(room: room, participant: moderator, prompt: prompt, round: round, epoch: epoch, enqueueReply: false) ?? opinions.last?.text
    }

    private func speak(
        room: GroupChatRoom,
        participant: GroupChatParticipant,
        prompt: String,
        round: Int,
        epoch: Int,
        enqueueReply: Bool
    ) async -> String? {
        await events.emit(.memberStarted(roomID: room.id, memberID: participant.id, round: round))
        let result = await repository.runMemberTurn(GroupChatMemberTurn(room: room, participant: participant, prompt: prompt, round: round))
        guard isCurrent(room.id, epoch), !Task.isCancelled,
              result.accepted, !result.timedOut, !result.cancelled,
              let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !GroupMentionRouter.isPass(text) else {
            await events.emit(.memberFinished(roomID: room.id, memberID: participant.id, text: nil, skipped: true))
            return nil
        }
        await repository.appendMember(room: room, memberID: participant.id, text: text)
        guard isCurrent(room.id, epoch), !Task.isCancelled else { return nil }
        if enqueueReply {
            pendingMessages[room.id, default: []].append(.message(.member(participant.id, text)))
        }
        await events.emit(.memberFinished(roomID: room.id, memberID: participant.id, text: text, skipped: false))
        return text
    }

    private func materialize(_ pending: PendingMessage, room: GroupChatRoom) async -> GroupMessage? {
        switch pending {
        case .message(let message):
            return message
        case .user(let id, _):
            if userPreparations[id] == nil {
                scheduleUserPreparations([pending], room: room)
            }
            let message = await userPreparations[id]?.value
            userPreparations.removeValue(forKey: id)
            return message
        }
    }

    /// Persist user-authored blocks as soon as they arrive so the composer does
    /// not appear stuck behind a long member barrier. Preparations are chained
    /// per room, preserving FIFO even when several sends arrive during an
    /// asynchronous room lookup. The scheduler later awaits the prepared value
    /// at that block's queue position.
    private func scheduleUserPreparations(_ messages: [PendingMessage], room: GroupChatRoom) {
        for message in messages {
            guard case .user(let id, let text) = message, userPreparations[id] == nil else { continue }
            let canonical = GroupMentionRouter.encode(text, members: room.members.map(\.member))
            let previous = lastUserPreparation[room.id]
            let repository = repository
            let task = Task<GroupMessage?, Never> {
                if let previous { _ = await previous.value }
                guard !canonical.isEmpty else { return nil }
                await repository.appendUser(room: room, text: canonical)
                return .user(canonical)
            }
            userPreparations[id] = task
            lastUserPreparation[room.id] = task
        }
    }

    private func dequeueMessage(roomID: String) -> PendingMessage? {
        guard var queue = pendingMessages[roomID], !queue.isEmpty else {
            pendingMessages.removeValue(forKey: roomID)
            return nil
        }
        let block = queue.removeFirst()
        if queue.isEmpty {
            pendingMessages.removeValue(forKey: roomID)
        } else {
            pendingMessages[roomID] = queue
        }
        return block
    }

    private func bumpEpoch(_ roomID: String) -> Int {
        let next = (epochs[roomID] ?? 0) + 1
        epochs[roomID] = next
        return next
    }

    private func isCurrent(_ roomID: String, _ epoch: Int) -> Bool { epochs[roomID] == epoch }
}
