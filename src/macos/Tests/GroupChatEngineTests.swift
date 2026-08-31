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

    func testStructuredA2APublishedLineUsesRenderedIdentity() throws {
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
            "投递回执的去重 key 必须与 UI 投影后的群聊消息一致"
        )
    }

    func testEngineRunsMentionedMembersStrictlySeriallyAndDoesNotPublishPasses() async {
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
        let repository = GroupEngineRepository(room: room, responses: ["A speaks", "(pass)"])
        let engine = GroupChatEngine(repository: repository)

        _ = await engine.send(roomID: room.id, text: "<@everyone> discuss")

        let result = await repository.snapshot()
        XCTAssertEqual(result.order.prefix(2), ["a", "b"])
        XCTAssertEqual(result.maximumConcurrent, 1)
        XCTAssertEqual(result.messages.filter { $0.speaker.memberId != nil }.map(\.text), ["A speaks"])
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
}

private actor GroupEngineRepository: GroupChatRepository {
    private let value: GroupChatRoom
    private var history: [GroupMessage] = []
    private var responses: [String]
    private var userMessageCount = 0
    private var order: [String] = []
    private var concurrent = 0
    private var maximumConcurrent = 0
    private var transcriptReadCount = 0

    init(room: GroupChatRoom, responses: [String], history: [GroupMessage] = []) {
        value = room
        self.responses = responses
        self.history = history
    }

    func room(id: String) async -> GroupChatRoom? { id == value.id ? value : nil }
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
        await Task.yield()
        concurrent -= 1
        let response = responses.isEmpty ? "(pass)" : responses.removeFirst()
        return GroupChatMemberTurnResult(text: response)
    }

    func snapshot() -> (order: [String], maximumConcurrent: Int, messages: [GroupMessage], userMessageCount: Int, transcriptReadCount: Int) {
        (order, maximumConcurrent, history, userMessageCount, transcriptReadCount)
    }
}
