import XCTest
@testable import MinisAppleDomain

final class GroupChatEngineTests: XCTestCase {
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
}

private actor GroupEngineRepository: GroupChatRepository {
    private let value: GroupChatRoom
    private var history: [GroupMessage] = []
    private var responses: [String]
    private var userMessageCount = 0
    private var order: [String] = []
    private var concurrent = 0
    private var maximumConcurrent = 0

    init(room: GroupChatRoom, responses: [String], history: [GroupMessage] = []) {
        value = room
        self.responses = responses
        self.history = history
    }

    func room(id: String) async -> GroupChatRoom? { id == value.id ? value : nil }
    func transcript(room: GroupChatRoom) async -> [GroupMessage] { history }
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

    func snapshot() -> (order: [String], maximumConcurrent: Int, messages: [GroupMessage], userMessageCount: Int) {
        (order, maximumConcurrent, history, userMessageCount)
    }
}
