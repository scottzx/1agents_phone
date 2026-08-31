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

/// The one serial, bounded room algorithm shared by iOS and macOS. The actor
/// owns the per-room epoch and rerun bookkeeping, so two sends never create
/// interleaved member loops and cancellation is observed between every turn.
public actor GroupChatEngine {
    private let repository: any GroupChatRepository
    private let events: any GroupChatEventSink
    private var epochs: [String: Int] = [:]
    private var running: Set<String> = []
    private var pendingRerun: Set<String> = []
    /// Messages which were persisted by an external sender (for example an
    /// A2A handoff) before the engine was asked to route them. They must not
    /// be reconstructed from the cursor because a member message is normally
    /// the cursor boundary for a new freeform run.
    private var pendingSeeds: [String: [GroupMessage]] = [:]

    public init(repository: any GroupChatRepository, events: any GroupChatEventSink = NoopGroupChatEventSink()) {
        self.repository = repository
        self.events = events
    }

    public func isRunning(roomID: String) -> Bool { running.contains(roomID) }

    public func cancel(roomID: String) {
        _ = bumpEpoch(roomID)
        pendingRerun.remove(roomID)
        pendingSeeds.removeValue(forKey: roomID)
    }

    @discardableResult
    public func send(roomID: String, text: String) async -> String? {
        await begin(roomID: roomID, userText: text, seededMessages: [])
    }

    /// Route lines which are already present in the transcript without
    /// appending a duplicate user row. This is used by A2A handoffs, whose
    /// sender has already published an assistant row before it wakes the room.
    @discardableResult
    public func resume(roomID: String, seededMessages: [GroupMessage]) async -> String? {
        await begin(roomID: roomID, userText: nil, seededMessages: seededMessages)
    }

    private func begin(roomID: String, userText: String?, seededMessages: [GroupMessage]) async -> String? {
        guard let room = await repository.room(id: roomID), !room.members.isEmpty else { return nil }
        let canonical: String
        if let userText {
            let members = room.members.map(\.member)
            canonical = GroupMentionRouter.encode(userText.trimmingCharacters(in: .whitespacesAndNewlines), members: members)
            if !canonical.isEmpty { await repository.appendUser(room: room, text: canonical) }
        } else {
            canonical = ""
        }

        guard !running.contains(roomID) else {
            pendingRerun.insert(roomID)
            if !seededMessages.isEmpty {
                pendingSeeds[roomID, default: []].append(contentsOf: seededMessages)
            }
            return nil
        }
        running.insert(roomID)
        let epoch = bumpEpoch(roomID)
        await events.emit(.started(roomID: roomID))
        let closing: String?
        switch room.mode {
        case .freeform:
            closing = await runFreeform(room: room, epoch: epoch, seededMessages: seededMessages)
        case .roundtable:
            let topic = canonical.isEmpty ? seededMessages.last?.text ?? "" : canonical
            closing = await runRoundtable(room: room, epoch: epoch, topic: topic)
        }
        running.remove(roomID)
        await events.emit(.completed(roomID: roomID))
        if pendingRerun.remove(roomID) != nil, isCurrent(roomID, epoch) {
            let pending = pendingSeeds.removeValue(forKey: roomID) ?? []
            return await begin(roomID: roomID, userText: nil, seededMessages: pending)
        }
        return closing
    }

    private func runFreeform(room: GroupChatRoom, epoch: Int, seededMessages: [GroupMessage]) async -> String? {
        let members = room.members.map(\.member)
        var history = await repository.transcript(room: room)
        var newMessages: [GroupMessage]
        if seededMessages.isEmpty {
            let start = history.lastIndex { $0.speaker.memberId != nil }.map { $0 + 1 } ?? 0
            newMessages = Array(history[min(start, history.count)...])
        } else {
            newMessages = seededMessages
        }
        var totalTurns = 0
        var closing: String?
        for round in 0..<GroupChatLimits.maxRounds {
            guard isCurrent(room.id, epoch) else { return closing }
            guard !newMessages.isEmpty else { break }
            let resolution = GroupMentionRouter.resolveResponders(members: members, newMessages: newMessages, history: history, ownerAgentId: room.ownerMemberID)
            guard !resolution.responderIds.isEmpty else { break }
            var spoken = 0
            var nextRoundMessages: [GroupMessage] = []
            for memberID in GroupMentionRouter.orderRoundSpeakers(resolution.responderIds, round: round) {
                guard isCurrent(room.id, epoch), totalTurns < GroupChatLimits.maxMemberTurns,
                      let participant = room.members.first(where: { $0.id == memberID }) else { continue }
                let member = participant.member
                let prompt = GroupChatPrompt.turnPrompt(member: member, groupTitle: room.title, peers: members.filter { $0.id != memberID }, allMembers: members, newMessages: GroupMentionRouter.messagesSinceMemberLastSpoke(history, memberId: memberID))
                guard let answer = await speak(room: room, participant: participant, prompt: prompt, round: round), isCurrent(room.id, epoch) else { continue }
                let published = GroupMessage.member(memberID, answer)
                history.append(published)
                nextRoundMessages.append(published)
                totalTurns += 1
                spoken += 1
                closing = answer
            }
            guard spoken > 0 else { break }
            // The engine actor serializes a room run, and speak() persists every
            // accepted answer before returning. Keep the authoritative in-run
            // projection above instead of re-reading and JSON-decoding the full
            // transcript once per round. Concurrent sends are already captured
            // by pendingSeeds/pendingRerun and begin a fresh run afterwards.
            newMessages = nextRoundMessages
        }
        return closing
    }

    private func runRoundtable(room: GroupChatRoom, epoch: Int, topic: String) async -> String? {
        let members = room.members.map(\.member)
        let experts = room.members.filter { $0.id != room.ownerMemberID }
        let moderator = room.members.first { $0.id == room.ownerMemberID }
        var opinions: [GroupMessage] = []
        var turns = 0
        for participant in experts where turns < GroupChatLimits.maxMemberTurns {
            guard isCurrent(room.id, epoch) else { return opinions.last?.text }
            let member = participant.member
            let prompt = GroupChatPrompt.roundtableTurnPrompt(member: member, groupTitle: room.title, peers: members.filter { $0.id != member.id }, allMembers: members, topic: topic, priorOpinions: opinions)
            if let answer = await speak(room: room, participant: participant, prompt: prompt, round: 0), isCurrent(room.id, epoch) {
                opinions.append(.member(member.id, answer))
                turns += 1
            }
        }
        guard let moderator, isCurrent(room.id, epoch), turns < GroupChatLimits.maxMemberTurns else { return opinions.last?.text }
        let member = moderator.member
        let prompt = GroupChatPrompt.roundtableSummaryPrompt(member: member, groupTitle: room.title, peers: members.filter { $0.id != member.id }, allMembers: members, topic: topic, opinions: opinions)
        return await speak(room: room, participant: moderator, prompt: prompt, round: 0) ?? opinions.last?.text
    }

    private func speak(room: GroupChatRoom, participant: GroupChatParticipant, prompt: String, round: Int) async -> String? {
        await events.emit(.memberStarted(roomID: room.id, memberID: participant.id, round: round))
        let result = await repository.runMemberTurn(GroupChatMemberTurn(room: room, participant: participant, prompt: prompt, round: round))
        guard result.accepted, !result.timedOut, !result.cancelled,
              let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !GroupMentionRouter.isPass(text) else {
            await events.emit(.memberFinished(roomID: room.id, memberID: participant.id, text: nil, skipped: true))
            return nil
        }
        await repository.appendMember(room: room, memberID: participant.id, text: text)
        await events.emit(.memberFinished(roomID: room.id, memberID: participant.id, text: text, skipped: false))
        return text
    }

    private func bumpEpoch(_ roomID: String) -> Int {
        let next = (epochs[roomID] ?? 0) + 1
        epochs[roomID] = next
        return next
    }

    private func isCurrent(_ roomID: String, _ epoch: Int) -> Bool { epochs[roomID] == epoch }
}
