import Foundation

// Typed decoding for every device→App event agent_link can emit.
//
// Before this file existed HardwareBLECentral.handleEvent tried three specific
// decoders in sequence (0x04 prompt, 0x52/0x53 record stream) and silently
// dropped everything else — so the board's battery reports (0x14), its
// self-describing I/O manifest (0x18), sensor readings (0x19) and manifest-
// change notices (0x1A) all reached the phone and were thrown away.
//
// Wire formats are read off the firmware's own encoders in
// Agent_link/components/agent_link/src/agent_link.cpp; the comment above each
// case cites the line that defines it. Do not change one side without the other.

/// A value carried by a generic-I/O reading, interpreted per `agent_val_t`
/// (agent_link_io.h). The raw bytes are kept alongside the decoded form so an
/// endpoint we don't understand still round-trips into logs and JSON.
enum AgentLinkValue: Equatable {
    case bool(Bool)
    case int32(Int32)
    case uint16(UInt16)
    case float(Float)
    case vector2(Float, Float)
    case vector3(Float, Float, Float)
    case rgb(UInt32)
    case blob(Data)
    case string(String)
    /// `agent_val_t` byte we don't recognize — kept so new firmware types are
    /// visible in the log instead of vanishing.
    case unsupported(type: UInt8, raw: Data)

    /// `agent_val_t` in agent_link_io.h.
    enum Kind: UInt8 {
        case bool = 0, int32, uint16, float, vector2, vector3, rgb, blob, string
    }

    static func decode(type: UInt8, raw: Data) -> AgentLinkValue {
        guard let kind = Kind(rawValue: type) else { return .unsupported(type: type, raw: raw) }
        switch kind {
        case .bool:
            guard raw.count >= 1 else { return .unsupported(type: type, raw: raw) }
            return .bool(raw[raw.startIndex] != 0)
        case .int32:
            guard let value = raw.littleEndianInteger(UInt32.self) else { return .unsupported(type: type, raw: raw) }
            return .int32(Int32(bitPattern: value))
        case .uint16:
            guard let value = raw.littleEndianInteger(UInt16.self) else { return .unsupported(type: type, raw: raw) }
            return .uint16(value)
        case .float:
            guard let value = raw.littleEndianFloat(at: 0) else { return .unsupported(type: type, raw: raw) }
            return .float(value)
        case .vector2:
            guard let x = raw.littleEndianFloat(at: 0), let y = raw.littleEndianFloat(at: 4) else {
                return .unsupported(type: type, raw: raw)
            }
            return .vector2(x, y)
        case .vector3:
            guard let x = raw.littleEndianFloat(at: 0),
                  let y = raw.littleEndianFloat(at: 4),
                  let z = raw.littleEndianFloat(at: 8) else {
                return .unsupported(type: type, raw: raw)
            }
            return .vector3(x, y, z)
        case .rgb:
            guard let value = raw.littleEndianInteger(UInt32.self) else { return .unsupported(type: type, raw: raw) }
            return .rgb(value)
        case .blob:
            return .blob(raw)
        case .string:
            // Firmware may or may not NUL-terminate a STR reading; trim so the
            // terminator never leaks into the displayed value.
            let trimmed = raw.prefix(while: { $0 != 0 })
            return .string(String(data: Data(trimmed), encoding: .utf8) ?? "")
        }
    }

    /// Compact form for logs and for the JSON we hand to the agent loop.
    var displayText: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int32(let value): return String(value)
        case .uint16(let value): return String(value)
        case .float(let value): return String(format: "%.3f", value)
        case .vector2(let x, let y): return String(format: "[%.3f, %.3f]", x, y)
        case .vector3(let x, let y, let z): return String(format: "[%.3f, %.3f, %.3f]", x, y, z)
        case .rgb(let value): return "#" + String(format: "%06X", value & 0x00ff_ffff)
        case .blob(let data): return "\(data.count) 字节"
        case .string(let text): return text
        case .unsupported(let type, let raw): return "未知类型 \(type)（\(raw.count) 字节）"
        }
    }
}

enum AgentLinkEvent: Equatable {
    /// 0x04 AGENT_EVT_PROMPT — firmware-authored UTF-8 forwarded verbatim.
    case prompt(String)
    /// 0x01 AGENT_EVT_BUTTON — suggested payload `[button_id(1)][action(1)]`.
    case button(id: UInt8, action: UInt8)
    /// 0x02 AGENT_EVT_SENSOR — device-specific; the SDK does not define a shape.
    case sensor(Data)
    /// 0x03 AGENT_EVT_WAKEWORD — payload may carry the matched word.
    case wakeword(String)
    /// 0x14 PowerStatus — `[state(1)][level(1)]` (agent_link.cpp:550-562).
    case powerStatus(state: PowerState, level: UInt8)
    /// 0x16 SelectedAgent — `[index(1)][id_len(1)][id UTF-8]`.
    ///
    /// The firmware header reserves this event for
    /// `agent_link_report_selected_agent()` but never implemented it
    /// (agent_link.cpp:576 returns `not_ready` with a TODO naming exactly this
    /// layout). We define the payload here and the firmware fills the TODO in.
    case selectedAgent(index: UInt8, agentId: String)
    /// 0x18 IoManifest — `[chunk_idx(1)][last(1)][json fragment]` (agent_link.cpp:284-288).
    case ioManifestChunk(index: UInt8, isLast: Bool, fragment: Data)
    /// 0x19 IoReading — `[id_len(1)][id UTF-8][val_type(1)][value…]` (agent_link.cpp:679-688).
    case ioReading(endpointId: String, value: AgentLinkValue)
    /// 0x1A ManifestChanged — `[rev(4, LE)]` (agent_link.cpp:699-703). The App
    /// is expected to re-fetch with command 0x34.
    case manifestChanged(rev: UInt32)
    /// 0x52 StreamStart — record/ASR audio stream opening on L2CAP PSM 0x0081.
    case recordStreamStart(AgentLinkCodec.StreamStartPayload)
    /// 0x53 StreamEnd — that stream closing.
    case recordStreamEnd(AgentLinkCodec.StreamEndPayload)
    /// 0x54 ImageStart — `[format(1)][w(2,LE)][h(2,LE)][total_len(4,LE)]` on PSM
    /// 0x0082. Decoded so the log is informative; this app never opens 0x0082,
    /// and the CuiCan board has no camera.
    case imageStreamStart(format: UInt8, width: UInt16, height: UInt16, totalBytes: UInt32)
    /// 0x55 ImageEnd — same shape as 0x53.
    case imageStreamEnd(AgentLinkCodec.StreamEndPayload)
    /// 0x64+ AGENT_EVT_CUSTOM — board-private packet; the board owns the payload.
    case custom(id: UInt8, payload: Data)
    /// An event id no firmware we know about emits. Surfaced rather than
    /// dropped so a protocol change shows up in the bridge log.
    case unknown(id: UInt8, payload: Data)

    /// `state` byte of a 0x14 PowerStatus event.
    enum PowerState: UInt8, Equatable {
        case discharging = 0
        case charging = 1
        /// The SDK substitutes 0x02 on the low-battery (<5%) edge instead of
        /// the charging flag, so this value carries urgency, not charge state.
        case lowBatteryEdge = 2

        var displayText: String {
            switch self {
            case .discharging: return "放电"
            case .charging: return "充电中"
            case .lowBatteryEdge: return "低电量"
            }
        }
    }

    // Event ids, matching agent_link_caps.h's agent_event_t and the literals in
    // agent_link.cpp's BuildEvent calls.
    enum ID {
        static let button: UInt8 = 0x01
        static let sensor: UInt8 = 0x02
        static let wakeword: UInt8 = 0x03
        static let prompt: UInt8 = 0x04
        static let powerStatus: UInt8 = 0x14
        static let selectedAgent: UInt8 = 0x16
        static let ioManifest: UInt8 = 0x18
        static let ioReading: UInt8 = 0x19
        static let manifestChanged: UInt8 = 0x1A
        static let recordStreamStart: UInt8 = 0x52
        static let recordStreamEnd: UInt8 = 0x53
        static let imageStreamStart: UInt8 = 0x54
        static let imageStreamEnd: UInt8 = 0x55
        /// AGENT_EVT_CUSTOM. Everything at or above this is board-private.
        static let customFloor: UInt8 = 0x64
    }

    /// Short human-readable form for the bridge log.
    var logDescription: String {
        switch self {
        case .prompt(let text):
            return "Prompt：\(text)"
        case .button(let id, let action):
            return "按键 \(id) 动作 \(action)"
        case .sensor(let data):
            return "Sensor 事件 \(data.count) 字节"
        case .wakeword(let word):
            return word.isEmpty ? "唤醒词" : "唤醒词：\(word)"
        case .powerStatus(let state, let level):
            return "电量 \(level)%（\(state.displayText)）"
        case .selectedAgent(let index, let agentId):
            return "设备选中 Agent #\(index)：\(agentId)"
        case .ioManifestChunk(let index, let isLast, let fragment):
            return "I/O manifest 分片 #\(index)\(isLast ? "（末片）" : "")：\(fragment.count) 字节"
        case .ioReading(let endpointId, let value):
            return "读数 \(endpointId) = \(value.displayText)"
        case .manifestChanged(let rev):
            return "manifest 变更 rev=\(rev)，需重新拉取"
        case .recordStreamStart(let payload):
            return "音频流开始：\(payload.name)"
        case .recordStreamEnd(let payload):
            return "音频流结束：\(payload.validBytes) 字节，truncated=\(payload.isTruncated)"
        case .imageStreamStart(let format, let width, let height, let totalBytes):
            return "图片流开始：fmt=\(format) \(width)x\(height) \(totalBytes) 字节（本 App 未开启 PSM 0x0082）"
        case .imageStreamEnd(let payload):
            return "图片流结束：\(payload.validBytes) 字节，truncated=\(payload.isTruncated)"
        case .custom(let id, let payload):
            return "板级私有事件 0x\(String(id, radix: 16))：\(payload.count) 字节"
        case .unknown(let id, let payload):
            return "未知事件 0x\(String(id, radix: 16))：\(payload.count) 字节"
        }
    }
}

extension Data {
    /// Little-endian fixed-width read from the front of this slice. Returns nil
    /// when there aren't enough bytes, so callers can fall through to a
    /// "malformed payload" path rather than trapping.
    func littleEndianInteger<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let width = MemoryLayout<T>.size
        guard count >= width else { return nil }
        var value: T = 0
        for offset in 0..<width {
            value |= T(truncatingIfNeeded: Int(self[index(startIndex, offsetBy: offset)])) << (8 * offset)
        }
        return value
    }

    /// Little-endian IEEE-754 single at a byte offset from the slice start.
    func littleEndianFloat(at offset: Int) -> Float? {
        guard count >= offset + 4 else { return nil }
        var bits: UInt32 = 0
        for byte in 0..<4 {
            bits |= UInt32(self[index(startIndex, offsetBy: offset + byte)]) << (8 * byte)
        }
        return Float(bitPattern: bits)
    }
}
