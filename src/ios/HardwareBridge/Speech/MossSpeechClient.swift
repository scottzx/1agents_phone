@preconcurrency import AVFoundation
import Foundation

/// Minimal Moss adapter used only by the hardware bridge. It intentionally does
/// not participate in Minis's normal Voice Provider selection: the competition
/// demo can be configured and tested without changing the phone's existing ASR
/// or TTS behavior.
actor MossSpeechClient {
    static let shared = MossSpeechClient()

    static let apiKeyEnvironmentName = "MOSS_API_KEY"
    // Competition test environment only. Replace with server-issued credentials
    // before this hardware bridge is used outside the current demo build.
    static let bundledTestAPIKey = "sk-6c615d081e40bb8d42b628dfa206743f7f4f8f94b7c04c10"
    static let baseURL = URL(string: "https://api.mosi.cn")!
    static let transcriptionModel = "moss-transcribe-1.0"
    static let speechModel = "moss-tts-1.5-flash"
    static let voiceID = "94aa4989-c7e9-5007-ae42-ab401823e6c9"

    enum ClientError: LocalizedError {
        case invalidPCM
        case invalidResponse
        case emptyTranscript
        case http(Int, String?)
        case audioConversion(String)

        var errorDescription: String? {
            switch self {
            case .invalidPCM:
                return "设备录音不是有效的 PCM16 音频"
            case .invalidResponse:
                return "Moss 返回格式无效"
            case .emptyTranscript:
                return "Moss 没有识别出文字"
            case .http(let status, let detail):
                return detail.map { "Moss 请求失败（HTTP \(status)）：\($0)" }
                    ?? "Moss 请求失败（HTTP \(status)）"
            case .audioConversion(let message):
                return "TTS 音频转换失败：\(message)"
            }
        }
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private struct SpeechResponse: Decodable {
        let url: URL
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    /// Sends the device's raw little-endian PCM16/16 kHz/mono recording as a
    /// WAV multipart upload. Moss does not accept inline base64 audio.
    func transcribe(pcm16: Data, apiKey: String) async throws -> String {
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2) else {
            throw ClientError.invalidPCM
        }

        let boundary = "MossBoundary-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipart(
            boundary: boundary,
            name: "file",
            filename: "ojbadge-recording.wav",
            contentType: "audio/wav",
            data: Self.wavData(fromPCM16: pcm16)
        )
        body.appendMultipartField(boundary: boundary, name: "model", value: Self.transcriptionModel)
        body.appendMultipartField(boundary: boundary, name: "response_format", value: "json")
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: Self.baseURL.appending(path: "/v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data = try await execute(request)
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.emptyTranscript }
        return text
    }

    /// Generates Moss MP3 by URL delivery, downloads it, and converts it to the
    /// firmware wire format: headerless little-endian PCM16, 16 kHz, mono.
    func synthesizePCM16(text: String, apiKey: String) async throws -> Data {
        let payload: [String: Any] = [
            "model": Self.speechModel,
            "input": text,
            "voice_id": Self.voiceID,
            "response_format": "mp3",
            "delivery_method": "url",
        ]

        var request = URLRequest(url: Self.baseURL.appending(path: "/v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let responseData = try await execute(request)
        let speech = try JSONDecoder().decode(SpeechResponse.self, from: responseData)

        var download = URLRequest(url: speech.url)
        download.timeoutInterval = 180
        let encodedAudio = try await execute(download)
        guard !encodedAudio.isEmpty else { throw ClientError.invalidResponse }
        return try Self.convertToDevicePCM16(encodedAudio, fileExtension: "mp3")
    }

    /// Streams Moss's raw 48 kHz PCM response, downsamples it to the device's
    /// 16 kHz PCM16 format, and hands bounded chunks to the BLE sender. Waiting
    /// for `onChunk` provides real backpressure all the way to URLSession.
    @discardableResult
    func streamSynthesizePCM16(
        text: String,
        apiKey: String,
        onChunk: @Sendable (Data) async throws -> Void
    ) async throws -> Int {
        let payload: [String: Any] = [
            "model": Self.speechModel,
            "input": text,
            "voice_id": Self.voiceID,
            "stream": true,
            "response_format": "pcm",
        ]

        var request = URLRequest(url: Self.baseURL.appending(path: "/v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var errorBody = Data()
            for try await byte in bytes.prefix(64 * 1024) { errorBody.append(byte) }
            throw ClientError.http(http.statusCode, Self.serverMessage(from: errorBody))
        }

        // 12 KB at 48 kHz is 125 ms of audio and becomes a 4 KB device chunk.
        // This is large enough to avoid per-byte BLE overhead and small enough
        // for low first-audio latency.
        let sourceBatchBytes = 12 * 1024
        var source = Data()
        source.reserveCapacity(sourceBatchBytes + 6)
        var delivered = 0

        for try await byte in bytes {
            try Task.checkCancellation()
            source.append(byte)
            if source.count >= sourceBatchBytes {
                let consumable = source.count - source.count % 6
                guard consumable > 0 else { continue }
                let pcm16 = Self.downsamplePCM48kTo16k(source.prefix(consumable))
                source.removeFirst(consumable)
                if !pcm16.isEmpty {
                    try await onChunk(pcm16)
                    delivered += pcm16.count
                }
            }
        }

        let consumable = source.count - source.count % 6
        if consumable > 0 {
            let pcm16 = Self.downsamplePCM48kTo16k(source.prefix(consumable))
            if !pcm16.isEmpty {
                try await onChunk(pcm16)
                delivered += pcm16.count
            }
        }
        guard delivered > 0 else { throw ClientError.invalidResponse }
        return delivered
    }

    /// 48 kHz → 16 kHz mono decimator with a three-sample box filter. Moss
    /// returns signed little-endian PCM16, so every six source bytes produce
    /// one signed little-endian output sample.
    static func downsamplePCM48kTo16k(_ source: Data.SubSequence) -> Data {
        let sampleGroups = source.count / 6
        guard sampleGroups > 0 else { return Data() }
        let bytes = [UInt8](source)
        var output = Data(capacity: sampleGroups * 2)
        for group in 0..<sampleGroups {
            let base = group * 6
            var sum = 0
            for sample in 0..<3 {
                let offset = base + sample * 2
                let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                sum += Int(Int16(bitPattern: raw))
            }
            let averaged = Int16(clamping: sum / 3)
            let little = UInt16(bitPattern: averaged).littleEndian
            output.append(UInt8(truncatingIfNeeded: little))
            output.append(UInt8(truncatingIfNeeded: little >> 8))
        }
        return output
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, Self.serverMessage(from: data))
        }
        return data
    }

    /// Wrap raw device PCM in a canonical 44-byte WAV header for Moss ASR.
    static func wavData(fromPCM16 pcm16: Data, sampleRate: UInt32 = 16_000) -> Data {
        var wav = Data(capacity: 44 + pcm16.count)
        wav.append(Data("RIFF".utf8))
        wav.appendLittleEndian(UInt32(36 + pcm16.count))
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))       // Linear PCM
        wav.appendLittleEndian(UInt16(1))       // Mono
        wav.appendLittleEndian(sampleRate)
        wav.appendLittleEndian(sampleRate * 2)  // Byte rate
        wav.appendLittleEndian(UInt16(2))       // Block align
        wav.appendLittleEndian(UInt16(16))      // Bits per sample
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(UInt32(pcm16.count))
        wav.append(pcm16)
        return wav
    }

    private static func convertToDevicePCM16(_ encodedAudio: Data, fileExtension: String) throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moss-tts-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try encodedAudio.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            let inputFile = try AVAudioFile(forReading: temporaryURL)
            let inputFormat = inputFile.processingFormat
            guard inputFormat.sampleRate > 0,
                  let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: true
                  ),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw ClientError.audioConversion("无法创建 16 kHz 单声道转换器")
            }

            let inputCapacity = AVAudioFrameCount(min(inputFile.length, Int64(UInt32.max)))
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: max(inputCapacity, 1)
            ) else {
                throw ClientError.audioConversion("无法分配输入缓冲区")
            }
            try inputFile.read(into: inputBuffer)

            let estimatedFrames = ceil(Double(inputBuffer.frameLength) * 16_000 / inputFormat.sampleRate)
            let outputCapacity = AVAudioFrameCount(min(estimatedFrames + 4_096, Double(UInt32.max)))
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: max(outputCapacity, 1)
            ) else {
                throw ClientError.audioConversion("无法分配输出缓冲区")
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let conversionError { throw conversionError }
            guard status == .haveData || status == .endOfStream,
                  outputBuffer.frameLength > 0,
                  let audioData = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
                throw ClientError.audioConversion("转换器没有输出音频")
            }
            let byteCount = Int(outputBuffer.audioBufferList.pointee.mBuffers.mDataByteSize)
            return Data(bytes: audioData, count: byteCount)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.audioConversion(error.localizedDescription)
        }
    }

    private static func serverMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String { return message }
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.count <= 300 else { return nil }
        return text
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendMultipart(
        boundary: String,
        name: String,
        filename: String,
        contentType: String,
        data: Data
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }

    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }
}
