import Foundation
import AVFoundation

// MARK: - Built-in SenseVoice (offline, local model) voice provider
//
// Wraps HardwareVoiceTranscriber (HardwareBridge/Transcription/) — a direct
// CTranscribe wrapper around a bundled SenseVoiceSmall-Q8_0.gguf model — as a
// second built-in, local-only ASR option alongside SystemVoiceProvider,
// following the exact same synthetic-instance pattern (see
// VoiceProvider+System.swift): never stored in ProviderConfigStore.instances,
// never synced, resolved by sentinel-id prefix match at each of the touch
// points VoiceProvider+System.swift already established.
//
// ASR only — the underlying engine does no speech synthesis, so `synthesize`
// always throws and `supportsVoiceOutput` is false. Conformance to
// VoiceOutputCapable is still required structurally: VoiceProviderFactory.make
// returns `any VoiceProviderCapable` (= VoiceInputCapable & VoiceOutputCapable).

final class SenseVoiceProvider: VoiceInputCapable, VoiceOutputCapable {

    static let builtinProviderId = "__builtin_sensevoice__"
    static let shared = SenseVoiceProvider()

    /// Synthetic, LOCAL-ONLY ProviderInstance — mirrors SystemVoiceProvider.providerInstance.
    /// Never stored in ProviderConfigStore.config.instances, so never written to the
    /// DB and never uploaded to iCloud.
    static let providerInstance = ProviderInstance(
        id: builtinProviderId,
        label: String(localized: "SenseVoice (Offline)", comment: "Built-in local ASR provider name"),
        providerType: .openAI,          // arbitrary — never used for auth/routing; routes by id
        credentialType: .apiKey,        // arbitrary — needs no credential
        isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 0)
    )

    private let logger = AppLogger(category: "SenseVoiceProvider")

    var supportsVoiceInput: Bool { true }
    var supportsVoiceOutput: Bool { false }

    // MARK: - Voice input (offline SenseVoice via CTranscribe)

    func transcribe(_ request: VoiceInputRequest) async throws -> VoiceInputResponse {
        let pcm16 = try Self.pcm16At16kMono(fromWAV: request.audioData)
        do {
            let text = try await HardwareVoiceTranscriber.shared.transcribe(pcm16: pcm16)
            return VoiceInputResponse(text: text, language: nil, duration: nil)
        } catch HardwareVoiceTranscriber.TranscriberError.emptyTranscript {
            // Silent/noise segment — not an error, just nothing to say (mirrors
            // SystemVoiceProvider returning "" rather than throwing on a silent
            // utterance).
            return VoiceInputResponse(text: "", language: nil, duration: nil)
        } catch let error as HardwareVoiceTranscriber.TranscriberError {
            throw VoiceProviderError.parseError(error.localizedDescription)
        }
    }

    // MARK: - Voice output (unsupported)

    func synthesize(_ request: VoiceOutputRequest) async throws -> Data {
        throw VoiceProviderError.unsupported("SenseVoice is speech-to-text only")
    }

    // MARK: - WAV → 16kHz mono PCM16

    /// `request.audioData` is WAV, but NOT always the same WAV writer: the real
    /// VAD-driven composer path (VoiceActivityDetector.wavData/SystemVoiceProvider.
    /// encodeWAV) writes a hand-rolled canonical 44-byte header, while
    /// ModelQuickTestSheet's "Quick Test" clip is written via AVAudioFile(forWriting:),
    /// whose chunk layout differs (extra/reordered chunks) — a fixed-offset read
    /// silently reads garbage there. Walk the RIFF chunks properly instead of
    /// assuming a fixed header size.
    ///
    /// Also: the declared sample rate is the mic's NATIVE hardware rate (commonly
    /// 48kHz), not actually 16kHz despite VoiceInputRequest's doc comment.
    /// HardwareVoiceTranscriber does no resampling itself, so feed it anything
    /// other than true 16kHz and the model sees pitch/speed-distorted audio.
    /// Resample here when needed.
    private static func pcm16At16kMono(fromWAV wav: Data) throws -> Data {
        guard wav.count >= 12 else { throw VoiceProviderError.parseError("SenseVoice: audio too short") }
        let bytes = [UInt8](wav)
        guard bytes[0...3].elementsEqual(Array("RIFF".utf8)),
              bytes[8...11].elementsEqual(Array("WAVE".utf8)) else {
            throw VoiceProviderError.parseError("SenseVoice: not a WAV container")
        }

        var channels: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var pcmRange: Range<Int>?

        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let chunkSize = Int(UInt32(bytes[offset + 4]) | (UInt32(bytes[offset + 5]) << 8)
                | (UInt32(bytes[offset + 6]) << 16) | (UInt32(bytes[offset + 7]) << 24))
            let payloadStart = offset + 8
            let payloadEnd = min(payloadStart + chunkSize, bytes.count)
            guard payloadStart <= bytes.count else { break }

            if id == "fmt ", payloadEnd - payloadStart >= 16 {
                channels = UInt16(bytes[payloadStart + 2]) | (UInt16(bytes[payloadStart + 3]) << 8)
                sampleRate = UInt32(bytes[payloadStart + 4]) | (UInt32(bytes[payloadStart + 5]) << 8)
                    | (UInt32(bytes[payloadStart + 6]) << 16) | (UInt32(bytes[payloadStart + 7]) << 24)
                bitsPerSample = UInt16(bytes[payloadStart + 14]) | (UInt16(bytes[payloadStart + 15]) << 8)
            } else if id == "data" {
                pcmRange = payloadStart..<payloadEnd
            }

            // Chunks are padded to an even byte boundary.
            offset = payloadStart + chunkSize + (chunkSize % 2)
        }

        guard let channels, let sampleRate, let bitsPerSample else {
            throw VoiceProviderError.parseError("SenseVoice: WAV missing fmt chunk")
        }
        guard let pcmRange else {
            throw VoiceProviderError.parseError("SenseVoice: WAV missing data chunk")
        }
        guard channels == 1, bitsPerSample == 16 else {
            throw VoiceProviderError.parseError("SenseVoice: expected mono 16-bit PCM (got \(channels)ch/\(bitsPerSample)bit)")
        }
        let pcmData = wav.subdata(in: pcmRange)
        guard sampleRate != 16000 else { return pcmData }
        return try resample(pcmData, fromRate: Double(sampleRate), toRate: 16000)
    }

    /// Resamples mono Int16 PCM via AVAudioConverter, mirroring the converter
    /// pattern already used by SystemVoiceProvider.encodeWAV.
    private static func resample(_ pcm: Data, fromRate srcRate: Double, toRate dstRate: Double) throws -> Data {
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: srcRate, channels: 1, interleaved: true),
              let dstFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: dstRate, channels: 1, interleaved: true) else {
            throw VoiceProviderError.parseError("SenseVoice: bad audio format for resample")
        }
        let frameCount = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw VoiceProviderError.parseError("SenseVoice: empty audio")
        }
        srcBuffer.frameLength = frameCount
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress,
                  let dst = srcBuffer.int16ChannelData?[0] else { return }
            dst.update(from: src, count: Int(frameCount))
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw VoiceProviderError.parseError("SenseVoice: could not create resampler")
        }
        var delivered = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if !delivered {
                delivered = true
                status.pointee = .haveData
                return srcBuffer
            }
            status.pointee = .endOfStream
            return nil
        }
        let ratio = dstRate / srcRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 4096
        var pcmOut = Data()
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
            if let convError { throw convError }
            if outBuffer.frameLength > 0, let ch = outBuffer.int16ChannelData {
                pcmOut.append(UnsafeBufferPointer(start: ch[0], count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
            if outBuffer.frameLength == 0 { break }
        }
        return pcmOut
    }
}

// MARK: - Virtual ModelEntry

extension ModelEntry {
    /// The one selectable SenseVoice ASR model — no online/offline/per-voice
    /// variants (single local model), unlike System's catalog.
    static let senseVoiceASR = ModelEntry(
        uuid: "sensevoice-asr",
        providerInstanceId: SenseVoiceProvider.builtinProviderId,
        model: LLMModel(
            id: "sensevoice-asr",
            displayName: String(localized: "SenseVoice (Offline)", comment: "Built-in local ASR option"),
            provider: SenseVoiceProvider.builtinProviderId,
            modalityOverride: [.audioInput]
        ),
        isHidden: true
    )
}

enum SenseVoiceCatalog {
    /// Resolve a SenseVoice composite id (bare sentinel or "<sentinel>/sensevoice-asr")
    /// to its virtual ModelEntry, or nil if the id isn't a SenseVoice id.
    static func entry(forCompositeId id: String) -> ModelEntry? {
        let sentinel = SenseVoiceProvider.builtinProviderId
        guard id == sentinel || id.hasPrefix(sentinel + "/") else { return nil }
        return .senseVoiceASR
    }
}
