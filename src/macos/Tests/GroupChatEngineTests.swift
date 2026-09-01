import XCTest
@testable import MinisAppleDomain

final class GroupChatEngineTests: XCTestCase {
    func testSyntheticAgentInputsUseMarkdownWithoutChangingHumanMessages() {
        let member = GroupMember(id: "a", name: "A", title: "", emoji: "", accentColor: "", summary: "", slot: 0)
        let groupPrompt = GroupChatPrompt.turnPrompt(
            member: member,
            groupTitle: "Room",
            peers: [],
            allMembers: [member],
            newMessages: [.user("**important**")]
        )

        XCTAssertTrue(AgentInboundMessageClassifier.shouldRenderMarkdown(groupPrompt))
        XCTAssertTrue(AgentInboundMessageClassifier.shouldRenderMarkdown("📨 来自助手「B」的消息：\n\n**important**"))
        XCTAssertFalse(AgentInboundMessageClassifier.shouldRenderMarkdown("**human-authored markdown markers**"))
    }

    func testGroupPromptUsesReadableMentionsWithoutMessageToolCalls() {
        let owner = GroupMember(id: "a", name: "产品经理", title: "", emoji: "", accentColor: "", summary: "", slot: 0)
        let peer = GroupMember(id: "b", name: "市场专家", title: "", emoji: "", accentColor: "", summary: "", slot: 1)
        let system = GroupChatPrompt.memberSystemBlock(
            member: owner,
            groupId: "group",
            groupTitle: "Room",
            mode: .freeform,
            isOwner: true,
            peers: [peer]
        )
        let turn = GroupChatPrompt.turnPrompt(
            member: owner,
            groupTitle: "Room",
            peers: [peer],
            allMembers: [owner, peer],
            newMessages: [.user("<@a> 说说")]
        )

        XCTAssertTrue(system.contains("@市场专家"))
        XCTAssertTrue(system.contains("`@所有人`"))
        XCTAssertFalse(system.contains("send_agent_message"))
        XCTAssertTrue(turn.contains("@完整名字"))
        XCTAssertFalse(turn.contains("send_agent_message"))
    }

    func testCanonicalMentionRendersReadableIdentity() throws {
        let market = GroupMember(id: "a-market", name: "市场专家", title: "", emoji: "", accentColor: "", summary: "", slot: 0)
        let product = GroupMember(id: "a-product", name: "产品经理", title: "", emoji: "", accentColor: "", summary: "", slot: 1)
        let host = GroupMember(id: "a-host", name: "主持人", title: "", emoji: "", accentColor: "", summary: "", slot: 2)
        let members = [market, product, host]
        let canonical = try GroupMentionRouter.composeA2AMessage(
            message: "来认识一下",
            targetAgentIds: [market.id, product.id],
            mentionEveryone: false,
            senderAgentId: host.id,
            members: members,
            ownerAgentId: host.id
        ).get()

        XCTAssertEqual(
            GroupMentionRouter.render(canonical, members: members),
            "@市场专家 @产品经理 来认识一下",
            "群聊持久化使用稳定 id，但 UI 始终展示可读名字"
        )
    }

    func testEngineRunsMentionedMembersConcurrentlyAndDoesNotPublishPasses() async {
        let room = GroupChatRoom(
            id: "room",
            sessionID: "session",
            title: "Room",
            mode: .freeform,
            ownerMemberID: "a",
            members: [
                GroupChatParticipant(id: "a", name: "A", slot: 0),
                GroupChatParticipant(id: "b", name: "B", slot: 1),
            ]
        )
        let repository = GroupEngineRepository(
            room: room,
            responses: [],
            responsesByMember: ["a": ["A speaks"], "b": ["(pass)"]],
            delaysByMember: ["a": [20_000_000], "b": [20_000_000]]
        )
        let engine = GroupChatEngine(repository: repository)

        _ = await engine.send(roomID: room.id, text: "<@everyone> discuss")

        let result = await repository.snapshot()
        XCTAssertEqual(Set(result.order.prefix(2)), Set(["a", "b"]))
        XCTAssertEqual(result.maximumConcurrent, 2)
        XCTAssertEqual(result.messages.filter { $0.speaker.memberId != nil }.map(\.text), ["A speaks"])
    }

    func testMentionedMembersExpandIntoIndependentTasksImmediately() async {
        let memberIDs = ["a", "b", "c", "d", "e", "f"]
        let room = GroupChatRoom(
            id: "room",
            sessionID: "session",
            title: "Room",
            mode: .freeform,
            ownerMemberID: "a",
            members: memberIDs.enumerated().map { index, id in
                GroupChatParticipant(id: id, name: id.uppercased(), slot: index)
            }
        )
        let repository = GroupEngineRepository(
            room: room,
            responses: [],
            responsesByMember: Dictionary(uniqueKeysWithValues: memberIDs.map { ($0, ["(pass)"]) }),
            delaysByMember: Dictionary(uniqueKeysWithValues: memberIDs.map { ($0, [30_000_000]) })
        )
        let engine = GroupChatEngine(repository: repository)

        _ = await engine.send(roomID: room.id, text: "<@everyone> report")

        let result = await repository.snapshot()
        XCTAssertEqual(result.maximumConcurrent, 6)
        XCTAssertEqual(Set(result.order), Set(memberIDs))
        XCTAssertEqual(Set(result.timeline.prefix(6)), Set(memberIDs.map { "start:\($0)" }),
                       "@6 must submit six independent tasks before any one finishes")
    }

    func testRepliesEnterFIFOByCompletionOrderAfterTheCurrentMessageBarrier() async {
        let room = GroupChatRoom(
            id: "room", sessionID: "session", title: "Room", mode: .freeform,
            ownerMemberID: "a",
            members: [
                GroupChatParticipant(id: "a", name: "A", slot: 0),
                GroupChatParticipant(id: "b", name: "B", slot: 1),
                GroupChatParticipant(id: "c", name: "C", slot: 2),
                GroupChatParticipant(id: "d", name: "D", slot: 3),
            ]
        )
        let repository = GroupEngineRepository(
            room: room,
            responses: [],
            responsesByMember: [
                "a": ["<@c> from A"],
                "b": ["<@d> from B"],
                "c": ["(pass)"],
                "d": ["(pass)"],
            ],
            delaysByMember: ["a": [80_000_000], "b": [10_000_000]]
        )
        let engine = GroupChatEngine(repository: repository)

        _ = await engine.send(roomID: room.id, text: "<@a> <@b> start")

        let result = await repository.snapshot()
        XCTAssertEqual(result.maximumConcurrent, 2)
        XCTAssertEqual(result.order, ["a", "b", "d", "c"])
        XCTAssertEqual(
            result.messages.filter { $0.speaker.memberId != nil }.map(\.text),
            ["<@d> from B", "<@c> from A"]
        )
        let firstChildStart = try? XCTUnwrap(result.timeline.firstIndex(of: "start:d"))
        let slowParentFinish = try? XCTUnwrap(result.timeline.firstIndex(of: "finish:a"))
        XCTAssertNotNil(firstChildStart)
        XCTAssertNotNil(slowParentFinish)
        if let firstChildStart, let slowParentFinish {
            XCTAssertGreaterThan(firstChildStart, slowParentFinish)
        }
    }

    func testUserMessageReceivedDuringCurrentMessageWaitsBehindItsBarrier() async {
        let room = GroupChatRoom(
            id: "room", sessionID: "session", title: "Room", mode: .freeform,
            ownerMemberID: "a",
            members: [
                GroupChatParticipant(id: "a", name: "A", slot: 0),
                GroupChatParticipant(id: "b", name: "B", slot: 1),
                GroupChatParticipant(id: "c", name: "C", slot: 2),
            ]
        )
        let repository = GroupEngineRepository(
            room: room,
            responses: [],
            responsesByMember: ["a": ["(pass)"], "b": ["(pass)"], "c": ["(pass)"]],
            delaysByMember: ["a": [80_000_000], "b": [80_000_000]]
        )
        let engine = GroupChatEngine(repository: repository)

        async let first: String? = engine.send(roomID: room.id, text: "<@a> <@b> first")
        try? await Task.sleep(nanoseconds: 10_000_000)
        let queued = await engine.send(roomID: room.id, text: "<@c> second")
        _ = await first

        XCTAssertNil(queued)
        let result = await repository.snapshot()
        XCTAssertEqual(Set(result.order.prefix(2)), Set(["a", "b"]))
        XCTAssertEqual(result.order.last, "c")
        let cStart = result.timeline.firstIndex(of: "start:c")
        let aFinish = result.timeline.firstIndex(of: "finish:a")
        let bFinish = result.timeline.firstIndex(of: "finish:b")
        XCTAssertNotNil(cStart)
        XCTAssertNotNil(aFinish)
        XCTAssertNotNil(bFinish)
        if let cStart, let aFinish, let bFinish {
            XCTAssertGreaterThan(cStart, max(aFinish, bFinish))
        }
    }

    func testNearSimultaneousUserMessagesEnterFIFOAtArrivalNotAfterRoomLookup() async {
        let room = GroupChatRoom(
            id: "room", sessionID: "session", title: "Room", mode: .freeform,
            ownerMemberID: "a",
            members: [
                GroupChatParticipant(id: "a", name: "A", slot: 0),
                GroupChatParticipant(id: "b", name: "B", slot: 1),
            ]
        )
        let repository = GroupEngineRepository(
            room: room,
            responses: [],
            roomDelaysNanoseconds: [80_000_000, 0],
            responsesByMember: ["a": ["(pass)"], "b": ["(pass)"]]
        )
        let engine = GroupChatEngine(repository: repository)

        async let first: String? = engine.send(roomID: room.id, text: "<@a> first")
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second: String? = engine.send(roomID: room.id, text: "<@b> second")
        _ = await (first, second)

        let result = await repository.snapshot()
        XCTAssertEqual(result.order, ["a", "b"])
        XCTAssertEqual(result.messages.filter { $0.speaker == .user }.map(\.text), ["<@a> first", "<@b> second"])
    }

    func testPersistedMemberSeedRoutesWithoutAppendingDuplicateUserMessage() async {
        let room = GroupChatRoom(
            id: "room", sessionID: "session", title: "Room", mode: .freeform,
            ownerMemberID: "a",
            members: [
                GroupChatParticipant(id: "a", name: "A", slot: 0),
                GroupChatParticipant(id: "b", name: "B", slot: 1),
            ]
        )
        let seed = GroupMessage.member("a", "<@b> please respond")
        let repository = GroupEngineRepository(room: room, responses: ["B reply"], history: [seed])
        let engine = GroupChatEngine(repository: repository)

        _ = await engine.resume(roomID: room.id, seededMessages: [seed])

        let result = await repository.snapshot()
        XCTAssertEqual(result.userMessageCount, 0)
        XCTAssertEqual(result.order.first, "b")
        XCTAssertTrue(result.messages.contains(.member("b", "B reply")))
    }

    func testFreeformRunLoadsTranscriptOnlyOnceAcrossMultipleRounds() async {
        let room = GroupChatRoom(
            id: "room", sessionID: "session", title: "Room", mode: .freeform,
            ownerMemberID: "a",
            members: [
                GroupChatParticipant(id: "a", name: "A", slot: 0),
                GroupChatParticipant(id: "b", name: "B", slot: 1),
            ]
        )
        let repository = GroupEngineRepository(
            room: room,
            responses: ["<@b> please continue", "B reply"]
        )
        let engine = GroupChatEngine(repository: repository)

        _ = await engine.send(roomID: room.id, text: "<@a> start")

        let result = await repository.snapshot()
        XCTAssertEqual(result.order, ["a", "b"])
        XCTAssertEqual(result.transcriptReadCount, 1)
    }

    func testReadableAgentNameReplyIsCanonicalizedAndQueued() async {
        let room = GroupChatRoom(
            id: "room", sessionID: "session", title: "Room", mode: .freeform,
            ownerMemberID: "a",
            members: [
                GroupChatParticipant(id: "a", name: "产品经理", slot: 0),
                GroupChatParticipant(id: "b", name: "市场专家", slot: 1),
            ]
        )
        let repository = GroupEngineRepository(
            room: room,
            responses: [],
            responsesByMember: [
                "a": ["@市场专家 请你接着说"],
                "b": ["(pass)"],
            ]
        )
        let engine = GroupChatEngine(repository: repository)

        _ = await engine.send(roomID: room.id, text: "<@a> 先说说")

        let result = await repository.snapshot()
        XCTAssertEqual(result.order, ["a", "b"])
        XCTAssertEqual(
            result.messages.filter { $0.speaker.memberId != nil }.map(\.text),
            ["<@b> 请你接着说"]
        )
    }

    func testFreeformRunContinuesPastLegacyRoundAndTurnCaps() async {
        let room = GroupChatRoom(
            id: "room", sessionID: "session", title: "Room", mode: .freeform,
            ownerMemberID: "a",
            members: [
                GroupChatParticipant(id: "a", name: "A", slot: 0),
                GroupChatParticipant(id: "b", name: "B", slot: 1),
            ]
        )
        var responses = (0..<11).map { index in
            let next = index.isMultiple(of: 2) ? "b" : "a"
            return "<@\(next)> continue \(index)"
        }
        responses.append("(pass)")
        let repository = GroupEngineRepository(room: room, responses: responses)
        let engine = GroupChatEngine(repository: repository)

        _ = await engine.send(roomID: room.id, text: "<@a> start")

        let result = await repository.snapshot()
        XCTAssertEqual(result.messages.filter { $0.speaker.memberId != nil }.count, 11)
        XCTAssertEqual(result.order.count, 12)
    }
}

private actor GroupEngineRepository: GroupChatRepository {
    private let value: GroupChatRoom
    private var history: [GroupMessage] = []
    private var responses: [String]
    private var roomDelaysNanoseconds: [UInt64]
    private var delaysNanoseconds: [UInt64]
    private var responsesByMember: [String: [String]]
    private var delaysByMember: [String: [UInt64]]
    private var userMessageCount = 0
    private var order: [String] = []
    private var concurrent = 0
    private var maximumConcurrent = 0
    private var transcriptReadCount = 0
    private var timeline: [String] = []

    init(
        room: GroupChatRoom,
        responses: [String],
        history: [GroupMessage] = [],
        roomDelaysNanoseconds: [UInt64] = [],
        delaysNanoseconds: [UInt64] = [],
        responsesByMember: [String: [String]] = [:],
        delaysByMember: [String: [UInt64]] = [:]
    ) {
        value = room
        self.responses = responses
        self.history = history
        self.roomDelaysNanoseconds = roomDelaysNanoseconds
        self.delaysNanoseconds = delaysNanoseconds
        self.responsesByMember = responsesByMember
        self.delaysByMember = delaysByMember
    }

    func room(id: String) async -> GroupChatRoom? {
        let delay = roomDelaysNanoseconds.isEmpty ? 0 : roomDelaysNanoseconds.removeFirst()
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return id == value.id ? value : nil
    }
    func transcript(room: GroupChatRoom) async -> [GroupMessage] {
        transcriptReadCount += 1
        return history
    }
    func appendUser(room: GroupChatRoom, text: String) async {
        userMessageCount += 1
        history.append(.user(text))
    }
    func appendMember(room: GroupChatRoom, memberID: String, text: String) async { history.append(.member(memberID, text)) }

    func runMemberTurn(_ turn: GroupChatMemberTurn) async -> GroupChatMemberTurnResult {
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        order.append(turn.participant.id)
        timeline.append("start:\(turn.participant.id)")
        let response: String
        if var memberResponses = responsesByMember[turn.participant.id], !memberResponses.isEmpty {
            response = memberResponses.removeFirst()
            responsesByMember[turn.participant.id] = memberResponses
        } else {
            response = responses.isEmpty ? "(pass)" : responses.removeFirst()
        }
        let delay: UInt64
        if var memberDelays = delaysByMember[turn.participant.id], !memberDelays.isEmpty {
            delay = memberDelays.removeFirst()
            delaysByMember[turn.participant.id] = memberDelays
        } else {
            delay = delaysNanoseconds.isEmpty ? 0 : delaysNanoseconds.removeFirst()
        }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        } else {
            await Task.yield()
        }
        concurrent -= 1
        timeline.append("finish:\(turn.participant.id)")
        return GroupChatMemberTurnResult(text: response)
    }

    func snapshot() -> (order: [String], maximumConcurrent: Int, messages: [GroupMessage], userMessageCount: Int, transcriptReadCount: Int, timeline: [String]) {
        (order, maximumConcurrent, history, userMessageCount, transcriptReadCount, timeline)
    }
}
