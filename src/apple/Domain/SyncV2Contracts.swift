import Foundation

// MARK: - Portable wire record

public struct SyncRecordID: Hashable, Codable, CustomStringConvertible, Sendable {
    public let type: String
    public let id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }

    public var description: String { "\(type):\(id)" }

    public static func parse(_ value: String) -> SyncRecordID? {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return SyncRecordID(type: String(parts[0]), id: String(parts[1]))
    }
}

public enum PortableFieldValue: Codable, Equatable, Sendable {
    case null
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case json(String)

    private enum Tag: String, Codable { case null, string, int, double, bool, date, data, json }
    private enum CodingKeys: String, CodingKey { case t, v }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: try container.encode(Tag.null, forKey: .t)
        case .string(let value): try container.encode(Tag.string, forKey: .t); try container.encode(value, forKey: .v)
        case .int(let value): try container.encode(Tag.int, forKey: .t); try container.encode(value, forKey: .v)
        case .double(let value): try container.encode(Tag.double, forKey: .t); try container.encode(value, forKey: .v)
        case .bool(let value): try container.encode(Tag.bool, forKey: .t); try container.encode(value, forKey: .v)
        case .date(let value): try container.encode(Tag.date, forKey: .t); try container.encode(value, forKey: .v)
        case .data(let value): try container.encode(Tag.data, forKey: .t); try container.encode(value, forKey: .v)
        case .json(let value): try container.encode(Tag.json, forKey: .t); try container.encode(value, forKey: .v)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .t) {
        case .null: self = .null
        case .string: self = .string(try container.decode(String.self, forKey: .v))
        case .int: self = .int(try container.decode(Int.self, forKey: .v))
        case .double: self = .double(try container.decode(Double.self, forKey: .v))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .v))
        case .date: self = .date(try container.decode(Date.self, forKey: .v))
        case .data: self = .data(try container.decode(Data.self, forKey: .v))
        case .json: self = .json(try container.decode(String.self, forKey: .v))
        }
    }
}

public struct PortableAsset: Codable, Equatable, Sendable {
    public let key: String
    public let fileURL: URL
    public let size: Int
    public let mimeType: String?

    public init(key: String, fileURL: URL, size: Int, mimeType: String? = nil) {
        self.key = key
        self.fileURL = fileURL
        self.size = size
        self.mimeType = mimeType
    }
}

public struct PortableRecord: Codable, Equatable, Sendable {
    public let id: SyncRecordID
    public let fields: [String: PortableFieldValue]
    public let assets: [String: PortableAsset]
    public let schemaVersion: Int
    public let minimumCompatibleVersion: Int?
    public let unknownFields: [String: PortableFieldValue]
    public let updatedAt: Date

    public init(id: SyncRecordID, fields: [String: PortableFieldValue] = [:], assets: [String: PortableAsset] = [:], schemaVersion: Int = 1, minimumCompatibleVersion: Int? = nil, unknownFields: [String: PortableFieldValue] = [:], updatedAt: Date) {
        self.id = id
        self.fields = fields
        self.assets = assets
        self.schemaVersion = schemaVersion
        self.minimumCompatibleVersion = minimumCompatibleVersion
        self.unknownFields = unknownFields
        self.updatedAt = updatedAt
    }

    public func unknownFields(includingUnrecognizedFields knownKeys: Set<String>) -> [String: PortableFieldValue] {
        fields.reduce(into: unknownFields) { result, item in
            if !knownKeys.contains(item.key) { result[item.key] = item.value }
        }
    }
}

public struct SyncOutboundBatch: Sendable {
    public let records: [PortableRecord]
    public let deletes: [SyncRecordID]
    public init(records: [PortableRecord], deletes: [SyncRecordID]) { self.records = records; self.deletes = deletes }
}

public struct SyncInboundBatch: Sendable {
    public let records: [PortableRecord]
    public let deletes: [SyncRecordID]
    public let sourceDeviceId: String?
    public init(records: [PortableRecord], deletes: [SyncRecordID], sourceDeviceId: String? = nil) {
        self.records = records; self.deletes = deletes; self.sourceDeviceId = sourceDeviceId
    }
}

public enum SyncOutcome: Equatable, Sendable {
    case success(SyncRecordID)
    case conflict(SyncRecordID, serverRecord: PortableRecord)
    case transientFailure(SyncRecordID, retryAfter: TimeInterval?)
    case permanentFailure(SyncRecordID, reason: String)
}

// MARK: - Transport boundary

public struct TransportCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let pushObserve = TransportCapabilities(rawValue: 1 << 0)
    public static let deltaFetch = TransportCapabilities(rawValue: 1 << 1)
    public static let assets = TransportCapabilities(rawValue: 1 << 2)
    public static let persistence = TransportCapabilities(rawValue: 1 << 3)
    public static let conflictDetect = TransportCapabilities(rawValue: 1 << 4)
}

public enum SyncFetchTrigger: String, Sendable { case startup, foregroundTimer, manual, retry, migration }
public enum SyncSendTrigger: String, Sendable { case scheduledDebounce, manual, migration, retry, foregroundTimer }

public protocol SyncTransport: AnyObject {
    var name: String { get }
    var capabilities: TransportCapabilities { get }
    var retryAfter: Date? { get }
    func start() async throws
    func stop() async
    func send(_ batch: SyncOutboundBatch, trigger: SyncSendTrigger) async throws -> [SyncOutcome]
    func observe(handler: @escaping (SyncInboundBatch) -> Void)
    func fullFetch(trigger: SyncFetchTrigger) async throws -> SyncInboundBatch
    func fetchChanges(trigger: SyncFetchTrigger) async throws -> SyncInboundBatch
    func delete(_ ids: [SyncRecordID]) async throws -> [SyncOutcome]
}

public extension SyncTransport {
    var retryAfter: Date? { nil }
}

// MARK: - Stable session/message V2 shapes

public struct SyncedSession: Codable, Equatable, Sendable {
    public static let recordType = "SessionV2"
    public static let fieldKeys: Set<String> = ["sessionId", "title", "category", "modelId", "createdAt", "updatedAt", "memoryEnabled", "modelBinding", "pinnedAt"]

    public var id: String
    public var title: String?
    public var category: String?
    public var modelId: String
    public var createdAt: Date
    public var updatedAt: Date
    public var memoryEnabled: Int
    public var modelBinding: String?
    public var pinnedAt: Date?

    public init(id: String, title: String? = nil, category: String? = nil, modelId: String, createdAt: Date, updatedAt: Date, memoryEnabled: Int, modelBinding: String? = nil, pinnedAt: Date? = nil) {
        self.id = id; self.title = title; self.category = category; self.modelId = modelId
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.memoryEnabled = memoryEnabled
        self.modelBinding = modelBinding; self.pinnedAt = pinnedAt
    }

    public static func from(_ session: ChatSession, memoryEnabled: Bool, modelBinding: String?) -> SyncedSession {
        SyncedSession(id: session.id, title: session.title, category: session.category, modelId: session.modelId, createdAt: session.createdAt, updatedAt: session.updatedAt, memoryEnabled: memoryEnabled ? 1 : 0, modelBinding: modelBinding, pinnedAt: session.pinnedAt)
    }

    public func portableRecord(unknownFields: [String: PortableFieldValue] = [:]) -> PortableRecord {
        PortableRecord(
            id: SyncRecordID(type: Self.recordType, id: id),
            fields: [
                "sessionId": .string(id), "title": title.map(PortableFieldValue.string) ?? .null,
                "category": category.map(PortableFieldValue.string) ?? .null, "modelId": .string(modelId),
                "createdAt": .date(createdAt), "updatedAt": .date(updatedAt), "memoryEnabled": .int(memoryEnabled),
                "modelBinding": modelBinding.map(PortableFieldValue.string) ?? .null,
                "pinnedAt": pinnedAt.map(PortableFieldValue.date) ?? .null
            ], schemaVersion: 1, unknownFields: unknownFields, updatedAt: updatedAt
        )
    }

    public init?(portableRecord record: PortableRecord) {
        guard record.id.type == Self.recordType,
              case .string(let id)? = record.fields["sessionId"],
              case .string(let modelId)? = record.fields["modelId"],
              case .date(let createdAt)? = record.fields["createdAt"] else { return nil }
        self.init(
            id: id, title: record.fields.optionalString("title"), category: record.fields.optionalString("category"),
            modelId: modelId, createdAt: createdAt, updatedAt: record.fields.date("updatedAt") ?? record.updatedAt,
            memoryEnabled: record.fields.int("memoryEnabled") ?? 1,
            modelBinding: record.fields.optionalString("modelBinding"), pinnedAt: record.fields.optionalDate("pinnedAt")
        )
    }
}

public struct SyncedMessage: Codable, Equatable, Sendable {
    public static let recordType = "MessageV2"
    public static let fieldKeys: Set<String> = ["messageId", "sessionId", "role", "partsJson", "tokenUsageJson", "reasoningContent", "streamInterruptCount", "sortOrder", "createdAt", "updatedAt"]

    public var id: String
    public var sessionId: String
    public var role: String
    public var partsJson: String
    public var tokenUsageJson: String?
    public var reasoningContent: String?
    public var streamInterruptCount: Int
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, sessionId: String, role: String, partsJson: String, tokenUsageJson: String? = nil, reasoningContent: String? = nil, streamInterruptCount: Int = 0, sortOrder: Int = 0, createdAt: Date, updatedAt: Date) {
        self.id = id; self.sessionId = sessionId; self.role = role; self.partsJson = partsJson
        self.tokenUsageJson = tokenUsageJson; self.reasoningContent = reasoningContent
        self.streamInterruptCount = streamInterruptCount; self.sortOrder = sortOrder
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public static func from(_ message: RawMessage, updatedAt: Date) -> SyncedMessage {
        let parts = (try? String(data: JSONEncoder().encode(message.parts), encoding: .utf8)) ?? "[]"
        let usage = message.tokenUsage.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        return SyncedMessage(id: message.id, sessionId: message.sessionId, role: message.role.rawValue, partsJson: parts, tokenUsageJson: usage, reasoningContent: message.reasoningContent, streamInterruptCount: message.streamInterruptCount, sortOrder: message.sortOrder, createdAt: message.createdAt, updatedAt: updatedAt)
    }

    public func portableRecord(unknownFields: [String: PortableFieldValue] = [:]) -> PortableRecord {
        PortableRecord(
            id: SyncRecordID(type: Self.recordType, id: id),
            fields: [
                "messageId": .string(id), "sessionId": .string(sessionId), "role": .string(role),
                "partsJson": .string(partsJson), "tokenUsageJson": tokenUsageJson.map(PortableFieldValue.string) ?? .null,
                "reasoningContent": reasoningContent.map(PortableFieldValue.string) ?? .null,
                "streamInterruptCount": .int(streamInterruptCount), "sortOrder": .int(sortOrder),
                "createdAt": .date(createdAt), "updatedAt": .date(updatedAt)
            ], schemaVersion: 1, unknownFields: unknownFields, updatedAt: updatedAt
        )
    }

    public init?(portableRecord record: PortableRecord) {
        guard record.id.type == Self.recordType,
              case .string(let id)? = record.fields["messageId"],
              case .string(let sessionId)? = record.fields["sessionId"],
              case .string(let role)? = record.fields["role"],
              case .string(let partsJson)? = record.fields["partsJson"],
              case .date(let createdAt)? = record.fields["createdAt"] else { return nil }
        self.init(id: id, sessionId: sessionId, role: role, partsJson: partsJson,
                  tokenUsageJson: record.fields.optionalString("tokenUsageJson"),
                  reasoningContent: record.fields.optionalString("reasoningContent"),
                  streamInterruptCount: record.fields.int("streamInterruptCount") ?? 0,
                  sortOrder: record.fields.int("sortOrder") ?? 0, createdAt: createdAt,
                  updatedAt: record.fields.date("updatedAt") ?? record.updatedAt)
    }
}

public struct PortableDirtyRecord: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case upsert, delete }
    public let id: SyncRecordID
    public let operation: Operation
    public let priority: Int
    public let updatedAt: Date
    public init(id: SyncRecordID, operation: Operation = .upsert, priority: Int = 0, updatedAt: Date = Date()) {
        self.id = id; self.operation = operation; self.priority = priority; self.updatedAt = updatedAt
    }
}

public enum PortableApplyResult: Equatable, Sendable { case applied, ignoredOlder, unsupportedType, invalidRecord }

public protocol PortableRecordRepository: Sendable {
    func exportPortableRecord(id: SyncRecordID) async throws -> PortableRecord?
    func applyPortableRecord(_ record: PortableRecord) async throws -> PortableApplyResult
    func applyPortableDelete(_ id: SyncRecordID, updatedAt: Date) async throws -> PortableApplyResult
    func markPortableDirty(_ dirty: PortableDirtyRecord) async throws
    func pendingPortableDirty(limit: Int) async throws -> [PortableDirtyRecord]
    func clearPortableDirty(_ ids: [SyncRecordID]) async throws
}

private extension Dictionary where Key == String, Value == PortableFieldValue {
    func optionalString(_ key: String) -> String? { if case .string(let value)? = self[key] { return value }; return nil }
    func int(_ key: String) -> Int? { if case .int(let value)? = self[key] { return value }; return nil }
    func date(_ key: String) -> Date? { if case .date(let value)? = self[key] { return value }; return nil }
    func optionalDate(_ key: String) -> Date? { date(key) }
}
