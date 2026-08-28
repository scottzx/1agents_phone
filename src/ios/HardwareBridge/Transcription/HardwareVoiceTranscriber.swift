import CTranscribe
import Foundation

/// Slim, direct wrapper over the CTranscribe C API (TranscribeCpp.xcframework,
/// vendored from the voice_type/VoiceContext project) for single-utterance
/// offline transcription of hardware-streamed audio.
///
/// Deliberately NOT a port of VoiceContext's SenseVoiceInferenceService: that
/// service's file-based API pulls in a VAD + speaker-diarization pipeline
/// (SherpaOnnx/OnnxRuntime + 2 more model files) needed for meeting
/// transcription, none of which applies here — the device's long-press
/// button already delimits the utterance, so there's no need for
/// client-side VAD. This wrapper calls transcribe_open/transcribe_run/
/// transcribe_full_text directly, mirroring the call sequence in
/// SenseVoiceInferenceService.swift's private `run(samples:...)` (voice_type
/// repo) but without its VAD/segmentation/diarization scaffolding.
actor HardwareVoiceTranscriber {
    /// Shared across every caller (hardware bridge + composer voice input) so the
    /// 241MB model loads once, not once per feature.
    static let shared = HardwareVoiceTranscriber()

    enum TranscriberError: LocalizedError {
        case modelResourceMissing
        case openFailed(String)
        case runFailed(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .modelResourceMissing: return "找不到 SenseVoiceSmall-Q8_0.gguf"
            case .openFailed(let message): return "模型加载失败：\(message)"
            case .runFailed(let message): return "转写失败：\(message)"
            case .emptyTranscript: return "转写结果为空"
            }
        }
    }

    private var session: OpaquePointer?

    /// SenseVoice is a fast single-utterance recognizer rather than a stateful
    /// streaming decoder. Keep transport chunks small, but coalesce them into
    /// bounded inference windows so long device recordings never require one
    /// unbounded model call. At 16 kHz PCM16 mono, 30 seconds is 960,000 bytes.
    static let defaultSegmentSeconds = 30

    deinit {
        if let session {
            transcribe_session_free(session)
        }
    }

    /// Converts raw little-endian PCM16 mono 16kHz bytes (as streamed by the
    /// device over L2CAP) to text.
    func transcribe(pcm16: Data) async throws -> String {
        let samples = Self.floatSamples(fromLittleEndianPCM16: pcm16)
        guard !samples.isEmpty else { throw TranscriberError.emptyTranscript }

        let session = try openSessionIfNeeded()

        var runParams = transcribe_run_params()
        transcribe_run_params_init(&runParams)
        // SenseVoice couples punctuation output to its ITN prefix; enable ITN
        // to get sentence-final punctuation. Language left nil = autodetect.
        runParams.itn = TRANSCRIBE_ITN_MODE_ON
        runParams.language = nil

        let runStatus = samples.withUnsafeBufferPointer { buffer in
            transcribe_run(session, buffer.baseAddress, Int32(buffer.count), &runParams)
        }
        guard runStatus == TRANSCRIBE_OK else {
            throw TranscriberError.runFailed(Self.statusDescription(runStatus))
        }

        let text = String(cString: transcribe_full_text(session))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriberError.emptyTranscript }
        return text
    }

    /// Transcribes an arbitrary-length device recording as ordered, bounded
    /// SenseVoice calls. The shared actor keeps one model session warm and also
    /// guarantees that segment results cannot complete out of order.
    func transcribeSegmented(
        pcm16: Data,
        segmentSeconds: Int = defaultSegmentSeconds
    ) async throws -> String {
        let segments = Self.pcmSegments(pcm16, seconds: segmentSeconds)
        guard !segments.isEmpty else { throw TranscriberError.emptyTranscript }

        var transcripts: [String] = []
        transcripts.reserveCapacity(segments.count)
        for segment in segments {
            do {
                transcripts.append(try await transcribe(pcm16: segment))
            } catch TranscriberError.emptyTranscript {
                // A silent/noisy window should not discard valid text from the
                // rest of a long recording.
                continue
            }
        }

        let merged = Self.mergeTranscriptSegments(transcripts)
        guard !merged.isEmpty else { throw TranscriberError.emptyTranscript }
        return merged
    }

    /// Splits only on complete Int16 samples. This helper is intentionally
    /// model-independent so it can be covered with tiny deterministic tests.
    nonisolated static func pcmSegments(_ pcm16: Data, seconds: Int) -> [Data] {
        guard seconds > 0, !pcm16.isEmpty else { return [] }
        let bytesPerWindow = 16_000 * MemoryLayout<Int16>.size * seconds
        guard bytesPerWindow > 0 else { return [] }

        var result: [Data] = []
        result.reserveCapacity((pcm16.count + bytesPerWindow - 1) / bytesPerWindow)
        var offset = 0
        while offset < pcm16.count {
            var end = min(offset + bytesPerWindow, pcm16.count)
            if end < pcm16.count && !end.isMultiple(of: MemoryLayout<Int16>.size) {
                end -= end % MemoryLayout<Int16>.size
            }
            guard end > offset else { break }
            result.append(pcm16.subdata(in: offset..<end))
            offset = end
        }
        return result
    }

    nonisolated static func mergeTranscriptSegments(_ segments: [String]) -> String {
        var merged = ""
        for raw in segments {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previous = merged.last, let next = text.first,
               previous.isASCII, next.isASCII,
               previous.isLetter || previous.isNumber,
               next.isLetter || next.isNumber {
                merged.append(" ")
            }
            merged.append(text)
        }
        return merged
    }

    private func openSessionIfNeeded() throws -> OpaquePointer {
        if let session { return session }

        guard let modelURL = Bundle.main.url(forResource: "SenseVoiceSmall-Q8_0", withExtension: "gguf") else {
            throw TranscriberError.modelResourceMissing
        }

        var loadParams = transcribe_model_load_params()
        transcribe_model_load_params_init(&loadParams)
        loadParams.backend = TRANSCRIBE_BACKEND_METAL

        var newSession: OpaquePointer?
        let openStatus = modelURL.path.withCString { path in
            transcribe_open(path, &loadParams, nil, &newSession)
        }
        guard openStatus == TRANSCRIBE_OK, let newSession else {
            throw TranscriberError.openFailed(Self.statusDescription(openStatus))
        }
        session = newSession
        return newSession
    }

    private static func floatSamples(fromLittleEndianPCM16 data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            for index in 0..<sampleCount {
                let offset = index * MemoryLayout<Int16>.size
                let low = UInt16(rawBuffer[offset])
                let high = UInt16(rawBuffer[offset + 1])
                let raw = Int16(bitPattern: low | (high << 8))
                samples.append(Float(raw) / 32768.0)
            }
        }
        return samples
    }

    private static func statusDescription(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }
}
