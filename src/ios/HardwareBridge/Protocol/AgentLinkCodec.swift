import Foundation

// Ported from voice_type_hardware/apps/ios/AgentBridge/AgentBridge/Protocol/AgentLinkCodec.swift
// with 0x52/0x53 (real-time ASR record-stream) event parsing added. Wire format
// defined by Agent_link/components/agent_link/include/agent_link.h and
// agent_link_transport.h (firmware side; do not change without updating both).

enum AgentLinkMessageType: UInt8, Equatable {
    case command = 0x01
    case response = 0x02
    case event = 0x03
}

struct AgentLinkFrame: Equatable {
    let type: AgentLinkMessageType
    let identifier: UInt8
    let sequence: UInt8
    let encrypted: Bool
    let payload: Data
}

enum AgentLinkCodec {
    static let version: UInt8 = 0x01
    static let promptEvent: UInt8 = 0x04
    static let streamStartEvent: UInt8 = 0x52
    static let streamEndEvent: UInt8 = 0x53
    static let ioActuateCommand: UInt8 = 0x33
    static let screenID = "screen0"
    static let maximumScreenTextBytes = 470
    static let streamEndFinalHeaderBytes = 60

    struct StreamStartPayload: Equatable {
        let transferID: UInt32
        let name: String
    }

    struct StreamEndPayload: Equatable {
        let transferID: UInt32
        let status: UInt8
        let validBytes: UInt32

        var isTruncated: Bool { status != 0 }
    }

    static func decode(_ data: Data) throws -> AgentLinkFrame {
        guard data.count >= 6 else { throw CodecError.frameTooShort }
        let bytes = [UInt8](data)
        guard bytes[0] == version else { throw CodecError.unsupportedVersion(bytes[0]) }

        let rawType = bytes[1]
        guard let type = AgentLinkMessageType(rawValue: rawType & 0x7f) else {
            throw CodecError.invalidMessageType(rawType)
        }
        let payloadLength = Int(bytes[4]) | (Int(bytes[5]) << 8)
        guard data.count == 6 + payloadLength else {
            throw CodecError.invalidPayloadLength(expected: payloadLength, actual: data.count - 6)
        }
        return AgentLinkFrame(
            type: type,
            identifier: bytes[2],
            sequence: bytes[3],
            encrypted: rawType & 0x80 != 0,
            payload: data.subdata(in: 6..<data.count)
        )
    }

    static func prompt(from data: Data) throws -> String? {
        let frame = try decode(data)
        guard frame.type == .event, frame.identifier == promptEvent else { return nil }
        guard !frame.encrypted else { throw CodecError.encryptionUnsupported }
        guard let text = String(data: frame.payload, encoding: .utf8) else {
            throw CodecError.invalidUTF8
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decodes a 0x52 StreamStart control event (payload = transfer_id LE(4) + name UTF-8).
    static func streamStart(from data: Data) throws -> StreamStartPayload? {
        let frame = try decode(data)
        guard frame.type == .event, frame.identifier == streamStartEvent else { return nil }
        guard !frame.encrypted else { throw CodecError.encryptionUnsupported }
        guard frame.payload.count >= 4 else { throw CodecError.invalidPayloadLength(expected: 4, actual: frame.payload.count) }
        let bytes = [UInt8](frame.payload)
        let transferID = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let nameData = frame.payload.subdata(in: 4..<frame.payload.count)
        let name = String(data: nameData, encoding: .utf8) ?? ""
        return StreamStartPayload(transferID: transferID, name: name)
    }

    /// Decodes a 0x53 StreamEnd control event (payload = transfer_id LE(4) + status(1) +
    /// valid_bytes LE(4) + 60-byte final_header, currently unused and discarded).
    static func streamEnd(from data: Data) throws -> StreamEndPayload? {
        let frame = try decode(data)
        guard frame.type == .event, frame.identifier == streamEndEvent else { return nil }
        guard !frame.encrypted else { throw CodecError.encryptionUnsupported }
        let minimumLength = 4 + 1 + 4
        guard frame.payload.count >= minimumLength else {
            throw CodecError.invalidPayloadLength(expected: minimumLength, actual: frame.payload.count)
        }
        let bytes = [UInt8](frame.payload)
        let transferID = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let status = bytes[4]
        let validBytes = UInt32(bytes[5]) | (UInt32(bytes[6]) << 8) | (UInt32(bytes[7]) << 16) | (UInt32(bytes[8]) << 24)
        return StreamEndPayload(transferID: transferID, status: status, validBytes: validBytes)
    }

    static func screenTextCommand(_ text: String, sequence: UInt8) -> Data {
        let identifier = Data(screenID.utf8)
        var text = text
        while text.utf8.count > maximumScreenTextBytes, !text.isEmpty {
            text.removeLast()
        }

        var payload = Data([UInt8(identifier.count)])
        payload.append(identifier)
        payload.append(Data(text.utf8))
        payload.append(0) // Current board callback consumes a C string.
        return encode(type: .command, identifier: ioActuateCommand, sequence: sequence, payload: payload)
    }

    static func encode(
        type: AgentLinkMessageType,
        identifier: UInt8,
        sequence: UInt8,
        payload: Data
    ) -> Data {
        precondition(payload.count <= Int(UInt16.max))
        let length = UInt16(payload.count)
        var frame = Data([
            version,
            type.rawValue,
            identifier,
            sequence,
            UInt8(length & 0xff),
            UInt8((length >> 8) & 0xff),
        ])
        frame.append(payload)
        return frame
    }

    enum CodecError: LocalizedError, Equatable {
        case frameTooShort
        case unsupportedVersion(UInt8)
        case invalidMessageType(UInt8)
        case invalidPayloadLength(expected: Int, actual: Int)
        case invalidUTF8
        case encryptionUnsupported

        var errorDescription: String? {
            switch self {
            case .frameTooShort: return "agent_link 帧不足 6 字节"
            case .unsupportedVersion(let version): return "不支持 agent_link 版本 \(version)"
            case .invalidMessageType(let type): return "未知消息类型 \(type)"
            case .invalidPayloadLength(let expected, let actual):
                return "载荷长度错误：声明 \(expected)，实际 \(actual)"
            case .invalidUTF8: return "Prompt 不是有效 UTF-8"
            case .encryptionUnsupported: return "暂不支持加密 agent_link 帧"
            }
        }
    }
}
