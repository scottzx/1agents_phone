import Foundation

/// Reassembles the board's self-describing I/O manifest from 0x18 fragments.
///
/// The firmware splits the manifest JSON at arbitrary byte offsets
/// (agent_link.cpp:277-292) and relies on the App to concatenate before
/// decoding — so a fragment boundary can fall inside a multi-byte UTF-8
/// codepoint. Nothing here may decode a fragment on its own.
///
/// Until now the phone ignored 0x18 entirely, so the board's endpoint list
/// never reached the agent loop.
struct IoManifestAssembler {
    /// One endpoint, mirroring what `BuildManifestJson` emits
    /// (agent_link.cpp:220-245). Only `id`/`dir`/`kind`/`value` are always
    /// written; the rest are conditional, hence optional here.
    ///
    /// `default` and `args` are pass-through JSON on the firmware side (the
    /// board supplies `args_schema` as a raw string), so they are intentionally
    /// not modeled — a caller that needs them reads `Manifest.rawJSON`.
    struct Endpoint: Codable, Equatable {
        let id: String
        /// `"in"` (sensor) or `"out"` (actuator).
        let dir: String
        let kind: String
        /// `agent_val_t` name: bool/u16/i32/f32/rgb/vec2/vec3/blob/str.
        let value: String
        let unit: String?
        let desc: String?
        /// `display_name` on the C side, serialized as `"name"`.
        let name: String?
        let range: [Double]?
        let rateHz: UInt16?
        /// `"change"` or `"threshold"`; absent means periodic.
        let event: String?
        /// `"user"` marks an endpoint hidden from the LLM.
        let audience: String?
        let enumValues: [String]?

        var isActuator: Bool { dir == "out" }
        /// Endpoints the board marks `audience:"user"` are app-facing only and
        /// must not be offered to the model as tools.
        var isLLMVisible: Bool { audience != "user" }

        enum CodingKeys: String, CodingKey {
            case id, dir, kind, value, unit, desc, name, range, event, audience
            case rateHz = "rate_hz"
            case enumValues = "enum"
        }
    }

    /// The manifest envelope. The firmware emits an object, not a bare array:
    /// `{"proto":1,"rev":N,"caps":N,"io":[…]}` (agent_link.cpp:208-249).
    struct Manifest: Equatable {
        let proto: Int
        let rev: UInt32
        /// `agent_cap_t` bitmask — which hardware the board actually has.
        let caps: UInt32
        let endpoints: [Endpoint]
        /// Kept so callers can hand the board's own words to the agent loop
        /// without this struct having to model every optional field.
        let rawJSON: String

        func hasCapability(_ capability: DeviceCapability) -> Bool {
            caps & capability.rawValue != 0
        }
    }

    /// `agent_cap_t` from agent_link_caps.h.
    enum DeviceCapability: UInt32, CaseIterable {
        case microphone = 0x001
        case speaker = 0x002
        case screen = 0x004
        case button = 0x008
        case haptic = 0x010
        case battery = 0x020
        case led = 0x040
        case sensor = 0x080
        case actuator = 0x100
        case recording = 0x200
        case camera = 0x400

        var displayName: String {
            switch self {
            case .microphone: return "麦克风"
            case .speaker: return "扬声器"
            case .screen: return "屏幕"
            case .button: return "按键"
            case .haptic: return "震动"
            case .battery: return "电量"
            case .led: return "LED"
            case .sensor: return "传感器"
            case .actuator: return "执行器"
            case .recording: return "录音"
            case .camera: return "摄像头"
            }
        }
    }

    private var fragments: [Data] = []
    private var nextIndex: UInt8 = 0

    /// Feeds one fragment. Returns the complete JSON once the `last` flag
    /// arrives, otherwise nil.
    ///
    /// A fragment whose index isn't the one expected means frames were dropped
    /// or the board restarted its send. Both make the partial buffer garbage,
    /// so it is discarded rather than concatenated into malformed JSON — the
    /// caller re-fetches with command 0x34.
    mutating func accept(index: UInt8, isLast: Bool, fragment: Data) -> Result {
        if index == 0 {
            fragments.removeAll()
            nextIndex = 0
        } else if index != nextIndex {
            let expected = nextIndex
            fragments.removeAll()
            nextIndex = 0
            return .desynchronized(expected: expected, received: index)
        }

        fragments.append(fragment)
        nextIndex = index &+ 1

        guard isLast else { return .incomplete }

        var json = Data()
        for fragment in fragments { json.append(fragment) }
        fragments.removeAll()
        nextIndex = 0
        return .complete(json)
    }

    mutating func reset() {
        fragments.removeAll()
        nextIndex = 0
    }

    enum Result: Equatable {
        case incomplete
        case complete(Data)
        /// Fragments arrived out of order; the buffer was dropped and the
        /// manifest must be re-fetched.
        case desynchronized(expected: UInt8, received: UInt8)
    }

    /// Parses a reassembled manifest. Returns nil on malformed JSON — a board
    /// that sends garbage should produce a log line, not a crash.
    static func parse(_ json: Data) -> Manifest? {
        struct Envelope: Decodable {
            let proto: Int?
            let rev: UInt32?
            let caps: UInt32?
            let io: [Endpoint]?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: json) else { return nil }
        return Manifest(
            proto: envelope.proto ?? 0,
            rev: envelope.rev ?? 0,
            caps: envelope.caps ?? 0,
            endpoints: envelope.io ?? [],
            rawJSON: String(data: json, encoding: .utf8) ?? ""
        )
    }
}
