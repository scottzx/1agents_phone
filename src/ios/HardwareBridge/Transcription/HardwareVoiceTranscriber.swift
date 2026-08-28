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
