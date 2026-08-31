import CloudKit
import Foundation
import MinisAppleDomain
import Security

public enum MacCloudKitSyncError: LocalizedError, Sendable {
    case disabled
    case accountUnavailable(CKAccountStatus)
    case invalidRecord

    public var errorDescription: String? {
        switch self {
        case .disabled: "CloudKit sync is disabled because this Runtime is not signed with the Minis iCloud container entitlement."
        case .accountUnavailable(let status): "The iCloud account is unavailable (status \(status.rawValue))."
        case .invalidRecord: "CloudKit returned an invalid Minis Sync V2 record."
        }
    }
}

/// Deliberately small desktop CloudKit transport for SessionV2/MessageV2. It
/// uses the same private container and shared zone as iOS, while keeping the
/// transport disabled in unsigned/ad-hoc builds that cannot possess the
/// required entitlement.
public final class MacCloudKitSyncTransport: SyncTransport, @unchecked Sendable {
    public static let containerIdentifier = "iCloud.com.1agents.phone"
    public static let zoneName = "minis-shared"

    public let name = "iCloud"
    public let capabilities: TransportCapabilities = [.persistence]
    public var retryAfter: Date? { nil }

    private let container: CKContainer?
    private let database: CKDatabase?
    private let zoneID = CKRecordZone.ID(zoneName: zoneName)
    private let enabled: Bool
    private let lock = NSLock()
    private var observer: ((SyncInboundBatch) -> Void)?

    public init(container: CKContainer? = nil, enabled: Bool? = nil) {
        let resolvedEnabled = enabled ?? Self.hasRequiredEntitlement()
        self.enabled = resolvedEnabled
        if resolvedEnabled {
            let resolved = container ?? CKContainer(identifier: Self.containerIdentifier)
            self.container = resolved
            self.database = resolved.privateCloudDatabase
        } else {
            self.container = nil
            self.database = nil
        }
    }

    public func start() async throws {
        guard enabled, let container, let database else { throw MacCloudKitSyncError.disabled }
        let status = try await container.accountStatus()
        guard status == .available else { throw MacCloudKitSyncError.accountUnavailable(status) }
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
    }

    public func stop() async {}

    public func observe(handler: @escaping (SyncInboundBatch) -> Void) {
        lock.lock(); observer = handler; lock.unlock()
    }

    public func send(_ batch: SyncOutboundBatch, trigger: SyncSendTrigger) async throws -> [SyncOutcome] {
        guard enabled else { throw MacCloudKitSyncError.disabled }
        let records = try batch.records.map(makeCKRecord)
        let deletes = batch.deletes.map(recordID)
        do {
            let result = try await modify(records: records, deletes: deletes)
            var outcomes: [SyncOutcome] = []
            for record in batch.records {
                if let error = result.saveErrors[record.id] {
                    outcomes.append(classify(error, id: record.id))
                } else {
                    outcomes.append(.success(record.id))
                }
            }
            for id in batch.deletes {
                if let error = result.deleteErrors[id] { outcomes.append(classify(error, id: id)) }
                else { outcomes.append(.success(id)) }
            }
            return outcomes
        } catch {
            return (batch.records.map(\.id) + batch.deletes).map { classify(error, id: $0) }
        }
    }

    public func delete(_ ids: [SyncRecordID]) async throws -> [SyncOutcome] {
        try await send(SyncOutboundBatch(records: [], deletes: ids), trigger: .manual)
    }

    public func fullFetch(trigger: SyncFetchTrigger) async throws -> SyncInboundBatch {
        guard enabled else { throw MacCloudKitSyncError.disabled }
        let sessions = try await query(recordType: SyncedSession.recordType)
        let messages = try await query(recordType: SyncedMessage.recordType)
        return SyncInboundBatch(records: try (sessions + messages).map(portableRecord), deletes: [], sourceDeviceId: nil)
    }

    public func fetchChanges(trigger: SyncFetchTrigger) async throws -> SyncInboundBatch {
        // The first desktop version favors deterministic replay over maintaining
        // a second opaque server-token cache. LWW/tombstones make full replay
        // idempotent; a token-based delta cursor can replace this internally.
        try await fullFetch(trigger: trigger)
    }

    public static func hasRequiredEntitlement() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] else { return false }
        return containers.contains(Self.containerIdentifier)
    }

    private func makeCKRecord(_ portable: PortableRecord) throws -> CKRecord {
        let record = CKRecord(recordType: portable.id.type, recordID: recordID(portable.id))
        record["payload"] = try JSONEncoder().encode(portable) as CKRecordValue
        record["updatedAt"] = portable.updatedAt as CKRecordValue
        return record
    }

    private func portableRecord(_ record: CKRecord) throws -> PortableRecord {
        guard let data = record["payload"] as? Data else { throw MacCloudKitSyncError.invalidRecord }
        return try JSONDecoder().decode(PortableRecord.self, from: data)
    }

    private func recordID(_ id: SyncRecordID) -> CKRecord.ID {
        let raw = Data("\(id.type):\(id.id)".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return CKRecord.ID(recordName: raw, zoneID: zoneID)
    }

    private struct ModifyResult: Sendable {
        var saveErrors: [SyncRecordID: Error]
        var deleteErrors: [SyncRecordID: Error]
    }

    private func modify(records: [CKRecord], deletes: [CKRecord.ID]) async throws -> ModifyResult {
        guard let database else { throw MacCloudKitSyncError.disabled }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: deletes)
            operation.savePolicy = .changedKeys
            operation.isAtomic = false
            let box = ModifyResultBox()
            operation.perRecordSaveBlock = { recordID, result in
                if case .failure(let error) = result { box.recordSave(recordID, error) }
            }
            operation.perRecordDeleteBlock = { recordID, result in
                if case .failure(let error) = result { box.recordDelete(recordID, error) }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success: continuation.resume(returning: box.result())
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func query(recordType: String) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let page = try await queryPage(recordType: recordType, cursor: cursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
        } while cursor != nil
        return records
    }

    private func queryPage(recordType: String, cursor: CKQueryOperation.Cursor?) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        guard let database else { throw MacCloudKitSyncError.disabled }
        return try await withCheckedThrowingContinuation { continuation in
            let operation: CKQueryOperation
            if let cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                operation = CKQueryOperation(query: CKQuery(recordType: recordType, predicate: NSPredicate(value: true)))
                operation.zoneID = zoneID
            }
            operation.resultsLimit = CKQueryOperation.maximumResults
            let box = RecordBox()
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result { box.append(record) }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor): continuation.resume(returning: (box.values(), cursor))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func classify(_ error: Error, id: SyncRecordID) -> SyncOutcome {
        let ck = error as? CKError
        if ck?.code == .serverRecordChanged,
           let server = ck?.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
           let portable = try? portableRecord(server) {
            return .conflict(id, serverRecord: portable)
        }
        if let retry = ck?.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
            return .transientFailure(id, retryAfter: retry)
        }
        switch ck?.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .transientFailure(id, retryAfter: nil)
        default:
            return .permanentFailure(id, reason: error.localizedDescription)
        }
    }

    private final class RecordBox: @unchecked Sendable {
        private let lock = NSLock(); private var records: [CKRecord] = []
        func append(_ record: CKRecord) { lock.lock(); records.append(record); lock.unlock() }
        func values() -> [CKRecord] { lock.lock(); defer { lock.unlock() }; return records }
    }

    private final class ModifyResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var saveErrors: [SyncRecordID: Error] = [:]
        private var deleteErrors: [SyncRecordID: Error] = [:]
        func recordSave(_ recordID: CKRecord.ID, _ error: Error) { lock.lock(); defer { lock.unlock() }; if let id = Self.syncID(recordID) { saveErrors[id] = error } }
        func recordDelete(_ recordID: CKRecord.ID, _ error: Error) { lock.lock(); defer { lock.unlock() }; if let id = Self.syncID(recordID) { deleteErrors[id] = error } }
        func result() -> ModifyResult { lock.lock(); defer { lock.unlock() }; return ModifyResult(saveErrors: saveErrors, deleteErrors: deleteErrors) }
        private static func syncID(_ recordID: CKRecord.ID) -> SyncRecordID? {
            let name = recordID.recordName
            guard let data = Data(base64Encoded: name.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+") + String(repeating: "=", count: (4 - name.count % 4) % 4)),
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            return SyncRecordID.parse(raw)
        }
    }
}
