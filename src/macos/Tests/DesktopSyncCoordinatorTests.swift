import Foundation
import XCTest
@testable import MinisDesktopCore

final class DesktopSyncCoordinatorTests: XCTestCase {
    func testCoordinatorAppliesInboundPushesDirtyAndClearsSuccessfulRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopStore(baseURL: directory)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.repositorySaveSession(ChatSession(
            id: "session-1", title: "Local", modelId: "model-1", createdAt: created, updatedAt: created
        ))

        let remoteDate = created.addingTimeInterval(30)
        let remote = SyncedSession(
            id: "session-remote", title: "Remote", category: nil, modelId: "model-1",
            createdAt: created, updatedAt: remoteDate, memoryEnabled: 1
        ).portableRecord(unknownFields: ["future": .string("preserved")])
        let transport = MemorySyncTransport(inbound: SyncInboundBatch(records: [remote], deletes: []))
        let coordinator = DesktopSyncCoordinator(repository: store, transport: transport)

        try await coordinator.start(periodicInterval: nil)

        let session = try await store.repositorySession(id: "session-remote")
        let pending = try await store.pendingPortableDirty(limit: 20)
        let sent = transport.sentBatches()
        let status = await coordinator.currentStatus()
        XCTAssertEqual(session?.title, "Remote")
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(sent.count, 1)
        let batch = try XCTUnwrap(sent.first)
        XCTAssertEqual(batch.records.first?.id, SyncRecordID(type: SyncedSession.recordType, id: "session-1"))
        let remoteExport = try await store.exportPortableRecord(id: SyncRecordID(type: SyncedSession.recordType, id: "session-remote"))
        XCTAssertEqual(remoteExport?.unknownFields["future"], .string("preserved"))
        XCTAssertEqual(status.downloadedCount, 1)
        XCTAssertEqual(status.uploadedCount, 1)
        await coordinator.stop()
    }

    func testCloudKitTransportFailsClosedWithoutEntitlement() async {
        let transport = MacCloudKitSyncTransport(enabled: false)
        do {
            try await transport.start()
            XCTFail("Unsigned transport must not start")
        } catch let error as MacCloudKitSyncError {
            guard case .disabled = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class MemorySyncTransport: SyncTransport, @unchecked Sendable {
    let name = "memory"
    let capabilities: TransportCapabilities = [.persistence]
    var retryAfter: Date? { nil }
    private let lock = NSLock()
    private var inbound: SyncInboundBatch
    private var sent: [SyncOutboundBatch] = []
    private var observer: ((SyncInboundBatch) -> Void)?

    init(inbound: SyncInboundBatch) { self.inbound = inbound }
    func start() async throws {}
    func stop() async {}
    func observe(handler: @escaping (SyncInboundBatch) -> Void) { lock.lock(); observer = handler; lock.unlock() }
    func fullFetch(trigger: SyncFetchTrigger) async throws -> SyncInboundBatch { fetchInbound() }
    func fetchChanges(trigger: SyncFetchTrigger) async throws -> SyncInboundBatch { fetchInbound() }
    func send(_ batch: SyncOutboundBatch, trigger: SyncSendTrigger) async throws -> [SyncOutcome] {
        recordSent(batch)
        return batch.records.map { .success($0.id) } + batch.deletes.map(SyncOutcome.success)
    }
    func delete(_ ids: [SyncRecordID]) async throws -> [SyncOutcome] { ids.map(SyncOutcome.success) }
    func sentBatches() -> [SyncOutboundBatch] { lock.lock(); defer { lock.unlock() }; return sent }
    private func recordSent(_ batch: SyncOutboundBatch) { lock.lock(); sent.append(batch); lock.unlock() }
    private func fetchInbound() -> SyncInboundBatch {
        lock.lock(); defer { lock.unlock() }
        let value = inbound
        inbound = SyncInboundBatch(records: [], deletes: [])
        return value
    }
}
