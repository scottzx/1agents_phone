import XCTest
@testable import MinisDesktopCore

final class ChatPersistenceTests: XCTestCase {
    func testLegacyChatJSONDecodesWithAdditiveDefaults() throws {
        let sessionJSON = Data(#"{"id":"session-1","title":"Legacy","modelId":"legacy-model","createdAt":0,"updatedAt":1}"#.utf8)
        let session = try JSONDecoder().decode(ChatSession.self, from: sessionJSON)
        XCTAssertEqual(session.id, "session-1")
        XCTAssertEqual(session.modelId, "legacy-model")
        XCTAssertNil(session.agentId)
        XCTAssertNil(session.spawnStatus)

        let messageJSON = Data(#"{"id":"message-1","sessionId":"session-1","role":"assistant","parts":[{"type":"toolUse","value":{"toolUseId":"call-1","name":"file_read","input":"{}","description":null,"thoughtSignature":null}}],"createdAt":0}"#.utf8)
        let message = try JSONDecoder().decode(RawMessage.self, from: messageJSON)
        XCTAssertEqual(message.streamInterruptCount, 0)
        XCTAssertEqual(message.sortOrder, 0)
        XCTAssertNil(message.errorInfo)
        XCTAssertNil(message.senderAgentId)

        let markerJSON = Data(#"{"id":"marker-1","sessionId":"session-1","summary":"old summary","firstKeptSortOrder":4,"compactedCount":3,"createdAt":0}"#.utf8)
        let marker = try JSONDecoder().decode(CompactMarker.self, from: markerJSON)
        XCTAssertEqual(marker.version, 1)
        XCTAssertNil(marker.lastCompactedMessageId)

        let mediaJSON = Data(#"{"id":"media-1","relativePath":"image.png","mimeType":"image/png","originalFileName":null}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MediaRef.self, from: mediaJSON).linuxPath)
    }

    func testDesktopStoreSatisfiesSharedRepositoryAndPreservesRichMessages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory)
        let repository: any ChatRepository = store
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ChatSession(
            id: "shared-session",
            title: "Shared",
            category: "Work",
            modelId: "claude-shared",
            createdAt: createdAt,
            updatedAt: createdAt,
            source: "repository-test",
            agentId: "agent-1",
            spawnRole: "main"
        )
        try await repository.repositorySaveSession(session)

        let richMessage = RawMessage(
            id: "shared-message",
            sessionId: session.id,
            role: .assistant,
            parts: [
                .text("I will read it."),
                .toolUse(ToolUse(toolUseId: "call-1", name: "file_read", input: #"{"path":"README.md"}"#))
            ],
            createdAt: createdAt.addingTimeInterval(1),
            tokenUsage: StoredTokenUsage(inputTokens: 10, outputTokens: 4, cacheCreationTokens: 0, cacheReadTokens: 2),
            reasoningContent: "brief reasoning",
            streamInterruptCount: 1,
            senderAgentId: "agent-1"
        )
        try await repository.repositoryAppendMessages([richMessage])

        let storedSession = try await repository.repositorySession(id: session.id)
        let storedSessions = try await repository.repositorySessions()
        let storedMessages = try await repository.repositoryMessages(sessionId: session.id)
        XCTAssertEqual(storedSession?.modelId, "claude-shared")
        XCTAssertEqual(storedSessions.map(\.id), [session.id])
        XCTAssertEqual(storedMessages, [richMessage])

        let runtimeConversation = try await store.conversation(session.id)
        let runtimeMessages = try await store.messages(sessionID: session.id)
        XCTAssertEqual(runtimeConversation?.kind, .agent)
        XCTAssertEqual(runtimeMessages.first?.id, richMessage.id)
        XCTAssertTrue(runtimeMessages.first?.text.contains("file_read") == true)

        // Reopening proves the additive compatibility columns are durable and
        // do not depend on actor memory.
        let reopened = try DesktopStore(baseURL: directory)
        let reopenedSession = try await reopened.repositorySession(id: session.id)
        let reopenedMessages = try await reopened.repositoryMessages(sessionId: session.id)
        XCTAssertEqual(reopenedSession?.category, "Work")
        XCTAssertEqual(reopenedMessages, [richMessage])
    }

    func testRepositoryProjectsExistingRuntimeRowsWithoutRewritingThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory)
        let conversation = RuntimeConversation(id: "runtime-session", title: "Runtime", createdAt: .distantPast, updatedAt: .distantPast)
        try await store.upsertConversation(conversation)
        let runtimeMessage = RuntimeMessageRecord(id: "runtime-message", sessionID: conversation.id, role: .user, text: "plain text", createdAt: .distantPast)
        try await store.appendMessage(runtimeMessage)

        let projectedSession = try await store.repositorySession(id: conversation.id)
        let projectedMessages = try await store.repositoryMessages(sessionId: conversation.id)
        let unchangedRuntimeMessages = try await store.messages(sessionID: conversation.id)
        XCTAssertEqual(projectedSession?.title, "Runtime")
        XCTAssertEqual(projectedSession?.modelId, "desktop-default")
        XCTAssertEqual(projectedMessages.first?.parts, [.text("plain text")])
        XCTAssertEqual(unchangedRuntimeMessages, [runtimeMessage])
    }
}
