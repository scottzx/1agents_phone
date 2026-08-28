import Foundation

/// Speaks an agent reply, on the device's speaker when it can and on the
/// phone's when it can't.
///
/// The phone half of the device path was already complete before this file:
/// `MossSpeechClient.synthesizePCM16` produced headerless 16 kHz mono PCM16 and
/// `HardwareBLECentral.sendVoicePCM16` bracketed it with 0x05 VoiceReply
/// status 2/3 across the audio L2CAP CoC, which is exactly what the firmware
/// SDK consumes (agent_link.cpp:454 → OnStreamData → `on_audio_out`). Two
/// things were missing, and both are here:
///
///  1. **Segmentation.** The old path synthesized the whole reply, then wrote
///     every byte in one blocking `writePCM16`. A 150-character summary is
///     ~10-15 s of audio — 320-480 KB at 16 kHz/16-bit/mono — and BLE L2CAP
///     moves tens of KB per second, so the first sound arrived many seconds
///     after the text did. Sentence-sized segments start playback after the
///     first one and overlap synthesis of segment N+1 with delivery of N.
///
///  2. **Plan B.** DEMO_PRD.md §6 requires phone-speaker fallback, and the
///     CuiCan board does not implement `on_audio_out` yet (its agent_link is an
///     unwired snapshot — see that component's SOURCE.md), so today the device
///     path cannot actually make sound. Falling back keeps the audio loop
///     closed instead of failing the turn.
@MainActor
final class HardwareVoiceOutput {
    /// Where the audio should come out.
    enum Route: String, CaseIterable, Identifiable {
        /// Try the device, fall back to the phone on any failure. The default,
        /// and what the PRD's "Plan A with Plan B standing by" means.
        case auto
        /// Device only. A failure is a failure — used when bringing up the
        /// firmware audio path, where a silent fallback would hide the bug.
        case device
        /// Phone only. The PRD's demo-safe setting.
        case phone

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "自动（优先设备，失败回落手机）"
            case .device: return "仅设备"
            case .phone: return "仅手机"
            }
        }
    }

    enum Outcome: Equatable {
        case spokeOnDevice(segments: Int, bytes: Int)
        case spokeOnPhone(segments: Int, reason: String?)
        /// The phone fallback was chosen but produced no sound because the
        /// app-wide "read replies aloud" preference is off. Reported rather
        /// than silently swallowed: silence that looks like success is the
        /// worst outcome to debug on a demo floor, and this bridge must not
        /// flip a global user preference behind their back.
        case phoneMuted(reason: String?)
        case skipped(reason: String)

        var logDescription: String {
            switch self {
            case .spokeOnDevice(let segments, let bytes):
                return "设备播报 \(segments) 段，\(bytes) 字节"
            case .spokeOnPhone(let segments, let reason):
                let why = reason.map { "（回落原因：\($0)）" } ?? ""
                return "手机播报 \(segments) 段\(why)"
            case .phoneMuted(let reason):
                let why = reason.map { "（回落原因：\($0)）" } ?? ""
                return "需回落手机播报\(why)，但“朗读回复”开关未打开，本次静音"
            case .skipped(let reason):
                return "未播报：\(reason)"
            }
        }
    }

    struct Delivery {
        /// Synthesizes one segment to headerless 16 kHz mono PCM16.
        let synthesize: (String) async throws -> Data
        /// Hands one segment's PCM to the device speaker.
        let sendToDevice: (Data) async throws -> Void
        /// True when the device link can actually take audio right now.
        let deviceReady: () -> Bool
        /// Called before each segment so the caller can log/annotate progress.
        let willSpeak: (Int, Int, String) -> Void
    }

    static let shared = HardwareVoiceOutput()

    private init() {}

    /// Speaks `text`, returning what actually happened.
    ///
    /// Never throws: a turn whose text already reached the screen should not be
    /// reported as failed because audio didn't work. The outcome carries the
    /// detail, and the caller logs it.
    func speak(
        _ text: String,
        route: Route,
        phoneSessionId: String,
        delivery: Delivery
    ) async -> Outcome {
        // The same sanitizer + splitter the in-app read-aloud path uses, so a
        // reply spoken by the device and the same reply spoken by the phone are
        // broken into identical segments.
        let sanitized = VoiceTextSanitizer.sanitize(text)
        guard !sanitized.isEmpty else { return .skipped(reason: "回复为空") }
        let segments = AIChatViewModel.splitIntoSpeechSegments(sanitized)
        guard !segments.isEmpty else { return .skipped(reason: "分段后为空") }

        switch route {
        case .phone:
            guard speakOnPhone(sanitized, sessionId: phoneSessionId) else {
                return .phoneMuted(reason: nil)
            }
            return .spokeOnPhone(segments: segments.count, reason: nil)

        case .device:
            do {
                let bytes = try await speakOnDevice(segments, delivery: delivery)
                return .spokeOnDevice(segments: segments.count, bytes: bytes)
            } catch {
                return .skipped(reason: error.localizedDescription)
            }

        case .auto:
            guard delivery.deviceReady() else {
                let reason = "设备音频通道未就绪"
                guard speakOnPhone(sanitized, sessionId: phoneSessionId) else {
                    return .phoneMuted(reason: reason)
                }
                return .spokeOnPhone(segments: segments.count, reason: reason)
            }
            do {
                let bytes = try await speakOnDevice(segments, delivery: delivery)
                return .spokeOnDevice(segments: segments.count, bytes: bytes)
            } catch {
                // Whatever already played on the device stays played; the
                // fallback re-speaks the whole reply rather than trying to
                // resume mid-sentence, which would be worse to listen to than
                // a short repeat.
                guard speakOnPhone(sanitized, sessionId: phoneSessionId) else {
                    return .phoneMuted(reason: error.localizedDescription)
                }
                return .spokeOnPhone(segments: segments.count, reason: error.localizedDescription)
            }
        }
    }

    /// Synthesizes and delivers segment by segment, overlapping the synthesis
    /// of the next segment with the BLE write of the current one.
    ///
    /// The overlap is what makes segmentation worth doing: synthesis is a
    /// network round-trip to Moss and delivery is a slow L2CAP write, and
    /// serializing them would make the segmented path *slower* end-to-end than
    /// the single-shot one it replaces.
    private func speakOnDevice(_ segments: [String], delivery: Delivery) async throws -> Int {
        var delivered = 0
        var pending: Task<Data, Error>? = Task { try await delivery.synthesize(segments[0]) }

        for index in segments.indices {
            guard let current = pending else { break }
            // Kick off the next synthesis before awaiting this segment's
            // delivery, so the Moss round-trip overlaps the BLE write.
            let next: Task<Data, Error>? = index + 1 < segments.count
                ? Task { [segment = segments[index + 1]] in try await delivery.synthesize(segment) }
                : nil

            let pcm16: Data
            do {
                pcm16 = try await current.value
            } catch {
                next?.cancel()
                throw error
            }

            delivery.willSpeak(index + 1, segments.count, segments[index])
            do {
                try await delivery.sendToDevice(pcm16)
            } catch {
                next?.cancel()
                throw error
            }
            delivered += pcm16.count
            pending = next
        }

        return delivered
    }

    /// Plan B. `VoiceOutputPlayer` already owns synthesis, queueing, prefetch
    /// and playback for in-app read-aloud, so the fallback is one call rather
    /// than a second audio stack.
    ///
    /// Returns false when `VoiceOutputPreferences.isEnabled` is off — the
    /// player drops every enqueue in that state, so calling it anyway would
    /// report success and play nothing.
    private func speakOnPhone(_ text: String, sessionId: String) -> Bool {
        guard VoiceOutputPreferences.isEnabled else { return false }
        VoiceOutputPlayer.shared.enqueueSegmented(text, sessionId: sessionId)
        return true
    }

    /// Stops any phone-side playback this bridge started.
    func stopPhonePlayback(sessionId: String) {
        VoiceOutputPlayer.shared.stopSession(sessionId)
    }
}
