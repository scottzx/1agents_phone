import Foundation

/// Versioned, line-delimited JSON contract shared by direct and service transports.
public enum MinisRuntimeProtocol {
    public static let version = 1
}

public struct RuntimeRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let method: String
    public let sessionID: String?
    public let payload: JSONValue?

    public init(method: String, sessionID: String? = nil, payload: JSONValue? = nil) {
        self.protocolVersion = MinisRuntimeProtocol.version
        self.requestID = UUID()
        self.method = method
        self.sessionID = sessionID
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID = "requestId"
        case method
        case sessionID = "sessionId"
        case payload
    }
}

public struct RuntimeEvent: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID?
    public let name: String
    public let sessionID: String?
    public let sequence: Int
    public let payload: JSONValue?
    public let error: String?

    public init(requestID: UUID? = nil, name: String, sessionID: String? = nil, sequence: Int = 0, payload: JSONValue? = nil, error: String? = nil) {
        self.protocolVersion = MinisRuntimeProtocol.version
        self.requestID = requestID
        self.name = name
        self.sessionID = sessionID
        self.sequence = sequence
        self.payload = payload
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID = "requestId"
        case name
        case sessionID = "sessionId"
        case sequence, payload, error
    }
}

/// A constrained JSON value keeps the wire protocol Codable without leaking
/// platform UI types into the Runtime boundary.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
