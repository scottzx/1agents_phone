import Foundation
import MinisAppleDomain

public struct DesktopSyncStatus: Codable, Sendable, Equatable {
    public var isRunning: Bool
    public var lastCompletedAt: Date?
    public var lastError: String?
    public var uploadedCount: Int
    public var downloadedCount: Int

    public init(isRunning: Bool = false, lastCompletedAt: Date? = nil, lastError: String? = nil, uploadedCount: Int = 0, downloadedCount: Int = 0) {
        self.isRunning = isRunning
        self.lastCompletedAt = lastCompletedAt
        self.lastError = lastError
        self.uploadedCount = uploadedCount
        self.downloadedCount = downloadedCount
    }
}

/// Runtime-owned bridge between the shared portable repository and a concrete
/// transport. The GUI never opens the database or talks to CloudKit directly.
public actor DesktopSyncCoordinator {
    private let repository: any PortableRecordRepository
    private let transport: SyncTransportBox
    private var periodicTask: Task<Void, Never>?
    private var started = false
    private var status = DesktopSyncStatus()

    public init(repository: any PortableRecordRepository, transport: any SyncTransport) {
        self.repository = repository
        self.transport = SyncTransportBox(transport)
    }

    @discardableResult
    public func start(periodicInterval: Duration? = .seconds(60)) async throws -> Bool {
        guard !started else { return false }
        try await transport.start()
        transport.observe { [weak self] batch in
            Task { await self?.applyInbound(batch) }
        }
        started = true
        _ = try await synchronize(trigger: .startup)
        if let periodicInterval {
            periodicTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: periodicInterval)
                    guard !Task.isCancelled else { return }
                    _ = try? await self?.synchronize(trigger: .foregroundTimer)
                }
            }
        }
        return true
    }

    public func stop() async {
        periodicTask?.cancel()
        periodicTask = nil
        started = false
        await transport.stop()
    }

    @discardableResult
    public func synchronize(trigger: SyncFetchTrigger = .manual) async throws -> DesktopSyncStatus {
        guard !status.isRunning else { return status }
        status.isRunning = true
        status.lastError = nil
        defer { status.isRunning = false }
        do {
            let inbound = try await transport.fetchChanges(trigger: trigger)
            let downloaded = await applyInbound(inbound)
            let dirty = try await repository.pendingPortableDirty(limit: 500)
            var records: [PortableRecord] = []
            var deletes: [SyncRecordID] = []
            for item in dirty {
                switch item.operation {
                case .upsert:
                    if let record = try await repository.exportPortableRecord(id: item.id) { records.append(record) }
                case .delete:
                    deletes.append(item.id)
                }
            }
            let outcomes = dirty.isEmpty
                ? []
                : try await transport.send(SyncOutboundBatch(records: records, deletes: deletes), trigger: .manual)
            var clear: [SyncRecordID] = []
            for outcome in outcomes {
                switch outcome {
                case .success(let id): clear.append(id)
                case .conflict(let id, let serverRecord):
                    let result = try await repository.applyPortableRecord(serverRecord)
                    if result == .applied { clear.append(id) }
                case .transientFailure: break
                case .permanentFailure: break
                }
            }
            if !clear.isEmpty { try await repository.clearPortableDirty(clear) }
            status.uploadedCount += clear.count
            status.downloadedCount += downloaded
            status.lastCompletedAt = Date()
            return status
        } catch {
            status.lastError = error.localizedDescription
            throw error
        }
    }

    public func currentStatus() -> DesktopSyncStatus { status }

    @discardableResult
    private func applyInbound(_ batch: SyncInboundBatch) async -> Int {
        var applied = 0
        for record in batch.records {
            if (try? await repository.applyPortableRecord(record)) == .applied { applied += 1 }
        }
        for id in batch.deletes {
            if (try? await repository.applyPortableDelete(id, updatedAt: Date())) == .applied { applied += 1 }
        }
        return applied
    }
}

/// The shared iOS-era transport protocol predates Swift 6 Sendable checking.
/// Desktop transports serialize their own mutable state; this wrapper makes
/// that ownership boundary explicit without forcing every iOS transport onto a
/// new concurrency model in the same migration.
private final class SyncTransportBox: @unchecked Sendable {
    private let base: any SyncTransport
    init(_ base: any SyncTransport) { self.base = base }
    func start() async throws { try await base.start() }
    func stop() async { await base.stop() }
    func observe(_ handler: @escaping (SyncInboundBatch) -> Void) { base.observe(handler: handler) }
    func fetchChanges(trigger: SyncFetchTrigger) async throws -> SyncInboundBatch { try await base.fetchChanges(trigger: trigger) }
    func send(_ batch: SyncOutboundBatch, trigger: SyncSendTrigger) async throws -> [SyncOutcome] { try await base.send(batch, trigger: trigger) }
}
