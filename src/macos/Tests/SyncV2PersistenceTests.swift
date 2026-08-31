import XCTest
@testable import MinisDesktopCore

final class SyncV2PersistenceTests: XCTestCase {
    func testSessionAndMessageWireKeysMatchIOSV2Contract() throws {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let session = SyncedSession(
            id: "session-1", title: "Title", category: nil, modelId: "model-1",
            createdAt: date, updatedAt: date, memoryEnabled: 1,
            modelBinding: nil, pinnedAt: nil
        ).portableRecord(unknownFields: ["futureFlag": .bool(true)])
        XCTAssertEqual(session.id, SyncRecordID(type: "SessionV2", id: "session-1"))
        XCTAssertEqual(Set(session.fields.keys), [
            "sessionId", "title", "category", "modelId", "createdAt",
            "updatedAt", "memoryEnabled", "modelBinding", "pinnedAt"
        ])

        let message = SyncedMessage(
            id: "message-1", sessionId: "session-1", role: "assistant",
            partsJson: "[]", tokenUsageJson: nil, reasoningContent: nil,
            streamInterruptCount: 0, sortOrder: 3,
            createdAt: date, updatedAt: date
        ).portableRecord()
        XCTAssertEqual(message.id.type, "MessageV2")
        XCTAssertEqual(Set(message.fields.keys), [
            "messageId", "sessionId", "role", "partsJson", "tokenUsageJson",
            "reasoningContent", "streamInterruptCount", "sortOrder", "createdAt", "updatedAt"
        ])

        // Fixture uses the exact tagged PortableFieldValue representation from
        // the pre-extraction iOS implementation. Unknown fields must survive.
        let fixture = Data(#"{"id":{"type":"SessionV2","id":"session-1"},"fields":{"sessionId":{"t":"string","v":"session-1"},"modelId":{"t":"string","v":"model-1"},"createdAt":{"t":"date","v":0},"updatedAt":{"t":"date","v":0},"memoryEnabled":{"t":"int","v":1}},"assets":{},"schemaVersion":1,"minimumCompatibleVersion":null,"unknownFields":{"futureFlag":{"t":"bool","v":true}},"updatedAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(PortableRecord.self, from: fixture)
        XCTAssertEqual(decoded.id.type, "SessionV2")
        XCTAssertEqual(decoded.unknownFields["futureFlag"], .bool(true))
        let roundTrip = try JSONDecoder().decode(PortableRecord.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
    }

    func testDesktopPortableExportApplyLWWUnknownFieldsAndDirtyQueue() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: targetDirectory)
        }
        let source = try DesktopStore(baseURL: sourceDirectory)
        let target = try DesktopStore(baseURL: targetDirectory)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ChatSession(id: "session-1", title: "Local", modelId: "model-1", createdAt: t0, updatedAt: t0)
        try await source.repositorySaveSession(session)
        let message = RawMessage(
            id: "message-1", sessionId: session.id, role: .assistant,
            parts: [.text("hello"), .toolUse(ToolUse(toolUseId: "call-1", name: "file_read", input: "{}"))],
            createdAt: t0.addingTimeInterval(1), reasoningContent: "reason", sortOrder: 4
        )
        try await source.repositoryAppendMessages([message])

        let dirty = try await source.pendingPortableDirty(limit: 20)
        XCTAssertTrue(dirty.contains(where: { $0.id == SyncRecordID(type: "SessionV2", id: session.id) && $0.operation == .upsert }))
        XCTAssertTrue(dirty.contains(where: { $0.id == SyncRecordID(type: "MessageV2", id: message.id) && $0.operation == .upsert }))

        let sessionID = SyncRecordID(type: SyncedSession.recordType, id: session.id)
        let messageID = SyncRecordID(type: SyncedMessage.recordType, id: message.id)
        let exportedSessionOptional = try await source.exportPortableRecord(id: sessionID)
        let exportedMessageOptional = try await source.exportPortableRecord(id: messageID)
        let exportedSession = try XCTUnwrap(exportedSessionOptional)
        let exportedMessage = try XCTUnwrap(exportedMessageOptional)
        let sessionApply = try await target.applyPortableRecord(exportedSession)
        let messageApply = try await target.applyPortableRecord(exportedMessage)
        let targetMessages = try await target.repositoryMessages(sessionId: session.id)
        let targetDirtyAfterApply = try await target.pendingPortableDirty(limit: 20)
        XCTAssertEqual(sessionApply, .applied)
        XCTAssertEqual(messageApply, .applied)
        XCTAssertEqual(targetMessages, [message])
        XCTAssertTrue(targetDirtyAfterApply.isEmpty)

        var newerFields = exportedSession.fields
        newerFields["title"] = .string("Remote Newer")
        newerFields["memoryEnabled"] = .int(0)
        newerFields["modelBinding"] = .string("binding-x")
        let newerDate = t0.addingTimeInterval(20)
        newerFields["updatedAt"] = .date(newerDate)
        newerFields["futureInline"] = .string("kept")
        let newer = PortableRecord(
            id: sessionID,
            fields: newerFields,
            schemaVersion: 2,
            unknownFields: ["futureDetached": .int(9)],
            updatedAt: newerDate
        )
        let newerApply = try await target.applyPortableRecord(newer)
        let newerSession = try await target.repositorySession(id: session.id)
        let reexportedOptional = try await target.exportPortableRecord(id: sessionID)
        let reexported = try XCTUnwrap(reexportedOptional)
        XCTAssertEqual(newerApply, .applied)
        XCTAssertEqual(newerSession?.title, "Remote Newer")
        XCTAssertEqual(reexported.fields["memoryEnabled"], .int(0))
        XCTAssertEqual(reexported.fields["modelBinding"], .string("binding-x"))
        XCTAssertEqual(reexported.unknownFields["futureInline"], .string("kept"))
        XCTAssertEqual(reexported.unknownFields["futureDetached"], .int(9))

        let olderApply = try await target.applyPortableRecord(exportedSession)
        let sessionAfterOlder = try await target.repositorySession(id: session.id)
        let olderDelete = try await target.applyPortableDelete(sessionID, updatedAt: t0.addingTimeInterval(10))
        let newerDelete = try await target.applyPortableDelete(sessionID, updatedAt: t0.addingTimeInterval(30))
        let deletedSession = try await target.repositorySession(id: session.id)
        let resurrection = try await target.applyPortableRecord(newer)
        XCTAssertEqual(olderApply, .ignoredOlder)
        XCTAssertEqual(sessionAfterOlder?.title, "Remote Newer")
        XCTAssertEqual(olderDelete, .ignoredOlder)
        XCTAssertEqual(newerDelete, .applied)
        XCTAssertNil(deletedSession)
        XCTAssertEqual(resurrection, .ignoredOlder)
    }
}
