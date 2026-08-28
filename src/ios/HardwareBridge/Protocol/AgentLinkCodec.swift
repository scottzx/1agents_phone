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
    static let voiceReplyCommandID: UInt8 = 0x05
    static let ioActuateCommandID: UInt8 = 0x33
    /// 0x34 GetIoManifest — asks the board to re-send its 0x18 manifest.
    static let getIoManifestCommandID: UInt8 = 0x34
    /// 0x37 SetAgentRoster — the App→device counterpart of 0x18, feeding the
    /// firmware's `on_agent_list` callback. Picked from the gap between the
    /// generic-I/O command block (0x33–0x36) and the capture block (0x3C/0x3D),
    /// deliberately far from AGENT_EVT_CUSTOM's 0x64+ board-private floor.
    static let setAgentRosterCommandID: UInt8 = 0x37
    static let screenID = "screen0"
    static let maximumScreenTextBytes = 470
    static let streamEndFinalHeaderBytes = 60
    /// version(1) + msg_type(1) + command_id(1) + sequence(1) + payload_len(2).
    static let headerSize = 6

    /// Upper bound the firmware itself clamps manifest fragments to
    /// (agent_link.cpp:275). Matching it keeps both directions symmetric.
    static let maximumFragmentBytes = 480
    /// Fragment floor from the same clamp, used when the negotiated ATT MTU is
    /// unknown or absurdly small.
    static let minimumFragmentBytes = 16

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

    /// Decodes any device→App event frame into a typed `AgentLinkEvent`.
    ///
    /// Replaces the previous "try three specific decoders and drop the rest"
    /// routing: every event id the firmware can emit now lands in a case, and
    /// ids we don't know surface as `.unknown` instead of disappearing.
    ///
    /// Returns nil for frames that aren't events (responses to our commands),
    /// which the caller logs separately.
    static func event(from data: Data) throws -> AgentLinkEvent? {
        let frame = try decode(data)
        guard frame.type == .event else { return nil }
        guard !frame.encrypted else { throw CodecError.encryptionUnsupported }
        let payload = frame.payload

        switch frame.identifier {
        case AgentLinkEvent.ID.prompt:
            guard let text = String(data: payload, encoding: .utf8) else { throw CodecError.invalidUTF8 }
            return .prompt(text.trimmingCharacters(in: .whitespacesAndNewlines))

        case AgentLinkEvent.ID.button:
            guard payload.count >= 2 else {
                throw CodecError.invalidPayloadLength(expected: 2, actual: payload.count)
            }
            let bytes = [UInt8](payload)
            return .button(id: bytes[0], action: bytes[1])

        case AgentLinkEvent.ID.sensor:
            return .sensor(payload)

        case AgentLinkEvent.ID.wakeword:
            return .wakeword(String(data: payload, encoding: .utf8) ?? "")

        case AgentLinkEvent.ID.powerStatus:
            guard payload.count >= 2 else {
                throw CodecError.invalidPayloadLength(expected: 2, actual: payload.count)
            }
            let bytes = [UInt8](payload)
            // An unrecognized state byte is reported as plain discharging
            // rather than rejected — the level is the useful half.
            let state = AgentLinkEvent.PowerState(rawValue: bytes[0]) ?? .discharging
            return .powerStatus(state: state, level: bytes[1])

        case AgentLinkEvent.ID.selectedAgent:
            guard payload.count >= 2 else {
                throw CodecError.invalidPayloadLength(expected: 2, actual: payload.count)
            }
            let bytes = [UInt8](payload)
            let idLength = Int(bytes[1])
            guard payload.count >= 2 + idLength else {
                throw CodecError.invalidPayloadLength(expected: 2 + idLength, actual: payload.count)
            }
            let idData = payload.subdata(in: payload.startIndex.advanced(by: 2)..<payload.startIndex.advanced(by: 2 + idLength))
            guard let agentId = String(data: idData, encoding: .utf8) else { throw CodecError.invalidUTF8 }
            return .selectedAgent(index: bytes[0], agentId: agentId)

        case AgentLinkEvent.ID.ioManifest:
            guard payload.count >= 2 else {
                throw CodecError.invalidPayloadLength(expected: 2, actual: payload.count)
            }
            let bytes = [UInt8](payload)
            let fragment = payload.subdata(in: payload.startIndex.advanced(by: 2)..<payload.endIndex)
            return .ioManifestChunk(index: bytes[0], isLast: bytes[1] != 0, fragment: fragment)

        case AgentLinkEvent.ID.ioReading:
            guard payload.count >= 1 else {
                throw CodecError.invalidPayloadLength(expected: 1, actual: payload.count)
            }
            let idLength = Int(payload[payload.startIndex])
            // id + the val_type byte that follows it.
            guard payload.count >= 1 + idLength + 1 else {
                throw CodecError.invalidPayloadLength(expected: 1 + idLength + 1, actual: payload.count)
            }
            let idRange = payload.startIndex.advanced(by: 1)..<payload.startIndex.advanced(by: 1 + idLength)
            guard let endpointId = String(data: payload.subdata(in: idRange), encoding: .utf8) else {
                throw CodecError.invalidUTF8
            }
            let valueType = payload[payload.startIndex.advanced(by: 1 + idLength)]
            let raw = payload.subdata(in: payload.startIndex.advanced(by: 1 + idLength + 1)..<payload.endIndex)
            return .ioReading(endpointId: endpointId, value: AgentLinkValue.decode(type: valueType, raw: raw))

        case AgentLinkEvent.ID.manifestChanged:
            guard let rev = payload.littleEndianInteger(UInt32.self) else {
                throw CodecError.invalidPayloadLength(expected: 4, actual: payload.count)
            }
            return .manifestChanged(rev: rev)

        case AgentLinkEvent.ID.recordStreamStart:
            return .recordStreamStart(try streamStartPayload(from: payload))

        case AgentLinkEvent.ID.recordStreamEnd:
            return .recordStreamEnd(try streamEndPayload(from: payload))

        case AgentLinkEvent.ID.imageStreamStart:
            // [format(1)][width(2,LE)][height(2,LE)][total_len(4,LE)] — agent_link.cpp:772.
            guard payload.count >= 9 else {
                throw CodecError.invalidPayloadLength(expected: 9, actual: payload.count)
            }
            let bytes = [UInt8](payload)
            let width = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            let height = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
            let total = UInt32(bytes[5]) | (UInt32(bytes[6]) << 8) | (UInt32(bytes[7]) << 16) | (UInt32(bytes[8]) << 24)
            return .imageStreamStart(format: bytes[0], width: width, height: height, totalBytes: total)

        case AgentLinkEvent.ID.imageStreamEnd:
            return .imageStreamEnd(try streamEndPayload(from: payload))

        case AgentLinkEvent.ID.customFloor...:
            return .custom(id: frame.identifier, payload: payload)

        default:
            return .unknown(id: frame.identifier, payload: payload)
        }
    }

    /// 0x33 IoActuate for an arbitrary endpoint: `[id_len(1)][id][args…]`,
    /// routed on the board by id to the callback registered with
    /// `agent_link_register_io`. This is the generic form of
    /// `screenTextCommand`, which is now one caller of it.
    ///
    /// Adding a new downlink channel (chat message, roundtable state, roster)
    /// costs a `register_io` call on the board and nothing in the SDK — which
    /// is exactly what generic I/O was designed for.
    static func ioActuateCommand(
        endpointId: String,
        args: Data,
        sequence: UInt8,
        nulTerminate: Bool = false
    ) -> Data {
        let identifier = Data(endpointId.utf8)
        var payload = Data([UInt8(identifier.count)])
        payload.append(identifier)
        payload.append(args)
        if nulTerminate { payload.append(0) }
        return encode(type: .command, identifier: ioActuateCommandID, sequence: sequence, payload: payload)
    }

    /// 0x34 GetIoManifest — no payload; the board answers with 0x18 fragments
    /// and then an ordinary ACK.
    static func getIoManifestCommand(sequence: UInt8) -> Data {
        encode(type: .command, identifier: getIoManifestCommandID, sequence: sequence, payload: Data())
    }

    /// 0x37 SetAgentRoster, fragmented into `[chunk_idx(1)][last(1)][json…]`
    /// frames — byte-for-byte the layout the firmware already uses for 0x18
    /// (agent_link.cpp:252-256), just running the other direction.
    ///
    /// Fragments split raw UTF-8 bytes at arbitrary offsets, exactly as
    /// `SendManifest` does: the receiver concatenates every fragment before
    /// decoding, so a split multi-byte codepoint is harmless. Doing it any
    /// other way would diverge from the format the board already parses.
    ///
    /// Sequence numbers increment per fragment starting at `startingSequence`,
    /// so a caller advances its own counter by `result.count`.
    static func agentRosterCommands(
        json: Data,
        fragmentBudget: Int,
        startingSequence: UInt8
    ) -> [Data] {
        let budget = max(minimumFragmentBytes, min(fragmentBudget, maximumFragmentBytes))
        var frames: [Data] = []
        var offset = 0
        var index: UInt8 = 0
        var sequence = startingSequence

        // `repeat` rather than `while`: an empty roster is a meaningful state
        // (no agents configured) and must still produce one last=1 frame, or
        // the device keeps showing a stale roster forever.
        repeat {
            let end = min(offset + budget, json.count)
            let fragment = json.subdata(in: offset..<end)
            var payload = Data([index, end >= json.count ? 0x01 : 0x00])
            payload.append(fragment)
            frames.append(encode(
                type: .command,
                identifier: setAgentRosterCommandID,
                sequence: sequence,
                payload: payload
            ))
            offset = end
            index &+= 1
            sequence &+= 1
        } while offset < json.count

        return frames
    }

    /// Fragment budget for a negotiated ATT MTU, mirroring the firmware's own
    /// arithmetic (agent_link.cpp:268-276): MTU minus 3 bytes of ATT overhead
    /// and 8 bytes of agent_link header + chunk header, clamped to [16, 480].
    static func fragmentBudget(attMTU: Int) -> Int {
        let raw = attMTU > 3 + 8 + 16 ? attMTU - 3 - 8 : 150
        return max(minimumFragmentBytes, min(raw, maximumFragmentBytes))
    }

    private static func streamStartPayload(from payload: Data) throws -> StreamStartPayload {
        guard payload.count >= 4 else {
            throw CodecError.invalidPayloadLength(expected: 4, actual: payload.count)
        }
        let bytes = [UInt8](payload)
        let transferID = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let nameData = payload.subdata(in: payload.startIndex.advanced(by: 4)..<payload.endIndex)
        return StreamStartPayload(transferID: transferID, name: String(data: nameData, encoding: .utf8) ?? "")
    }

    private static func streamEndPayload(from payload: Data) throws -> StreamEndPayload {
        let minimumLength = 4 + 1 + 4
        guard payload.count >= minimumLength else {
            throw CodecError.invalidPayloadLength(expected: minimumLength, actual: payload.count)
        }
        let bytes = [UInt8](payload)
        let transferID = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let validBytes = UInt32(bytes[5]) | (UInt32(bytes[6]) << 8) | (UInt32(bytes[7]) << 16) | (UInt32(bytes[8]) << 24)
        return StreamEndPayload(transferID: transferID, status: bytes[4], validBytes: validBytes)
    }

    static func screenTextCommand(_ text: String, sequence: UInt8) -> Data {
        // Trim by Character, not by byte, so a multi-byte codepoint is never
        // cut in half — the board consumes this as a C string and would render
        // the tail as mojibake.
        var text = text
        while text.utf8.count > maximumScreenTextBytes, !text.isEmpty {
            text.removeLast()
        }
        return ioActuateCommand(
            endpointId: screenID,
            args: Data(text.utf8),
            sequence: sequence,
            nulTerminate: true // Current board callback consumes a C string.
        )
    }

    /// Encodes 0x05 VoiceReply. Status 2 announces that PCM is about to arrive
    /// over audio L2CAP PSM 0x0081; status 3 closes the segment and lets the
    /// firmware call `on_audio_end`.
    static func voiceReplyCommand(
        sessionID: UInt32,
        status: UInt8,
        sequence: UInt8
    ) -> Data {
        precondition(status == 2 || status == 3)
        var payload = Data()
        payload.append(UInt8(sessionID & 0xff))
        payload.append(UInt8((sessionID >> 8) & 0xff))
        payload.append(UInt8((sessionID >> 16) & 0xff))
        payload.append(UInt8((sessionID >> 24) & 0xff))
        payload.append(status)
        return encode(
            type: .command,
            identifier: voiceReplyCommandID,
            sequence: sequence,
            payload: payload
        )
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
