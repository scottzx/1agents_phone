import CoreBluetooth
import Foundation

/// Pure buffering core for the agent_link record-stream (raw PCM16 audio, no
/// header) — deliberately CoreBluetooth-free so it can be unit tested with
/// synthetic byte chunks instead of a real CBL2CAPChannel.
actor AgentLinkAudioBuffer {
    private var buffer = Data()
    private var isActive = false

    func streamStarted() {
        buffer.removeAll(keepingCapacity: true)
        isActive = true
    }

    func append(_ chunk: Data) {
        guard isActive, !chunk.isEmpty else { return }
        buffer.append(chunk)
    }

    /// Finalizes on 0x53 StreamEnd: truncates to `validBytes` (the firmware's
    /// own count of bytes it successfully pushed) and clears the buffer.
    /// Returns nil if there was no active stream (e.g. a stray/duplicate
    /// StreamEnd with no matching StreamStart).
    func finish(validBytes: UInt32) -> Data? {
        guard isActive else { return nil }
        isActive = false
        defer { buffer.removeAll(keepingCapacity: false) }
        let cap = Int(min(UInt32(buffer.count), validBytes))
        return buffer.prefix(cap)
    }
}

/// Owns the agent_link record-stream L2CAP CoC (PSM 0x0081) and reads raw
/// PCM16 mono 16kHz audio out of it. StreamStart/StreamEnd (0x52/0x53) arrive
/// separately over the GATT event characteristic (see HardwareBLECentral) —
/// this class only owns the L2CAP byte stream itself, not the control events.
final class AgentLinkL2CAPReceiver: NSObject, StreamDelegate {
    static let psm: UInt16 = 0x0081

    let buffer = AgentLinkAudioBuffer()

    private var channel: CBL2CAPChannel?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private let readChunkSize = 4096
    private let writeChunkSize = 512
    private let playbackBytesPerSecond = 16_000 * MemoryLayout<Int16>.size
    private let playbackLeadBytes = 8_000 // 250 ms at 16 kHz PCM16 mono
    private var pacedWriteStartedAt: Date?
    private var pacedWriteBytes = 0

    func attach(_ channel: CBL2CAPChannel) {
        detach()
        self.channel = channel
        guard let input = channel.inputStream, let output = channel.outputStream else { return }
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        input.open()
        output.open()
        inputStream = input
        outputStream = output
    }

    /// True once the CoC is attached and its write side is usable. The audio
    /// route checks this before choosing the device over the phone speaker —
    /// a link whose GATT control channel is ready can still be missing this
    /// channel, and discovering that only at write time costs a whole turn.
    var isWritable: Bool {
        guard let outputStream else { return false }
        switch outputStream.streamStatus {
        case .notOpen, .closed, .error: return false
        default: return true
        }
    }

    func detach() {
        inputStream?.close()
        outputStream?.close()
        inputStream?.remove(from: .main, forMode: .common)
        outputStream?.remove(from: .main, forMode: .common)
        inputStream = nil
        outputStream = nil
        channel = nil
        pacedWriteStartedAt = nil
        pacedWriteBytes = 0
    }

    func streamStarted() {
        Task { await buffer.streamStarted() }
    }

    /// Drains any bytes already sitting in the input stream's OS buffer before
    /// finalizing. GATT (StreamEnd) and L2CAP (audio bytes) are separate
    /// channels with independent latency, so StreamEnd can in principle be
    /// delivered slightly ahead of the last in-flight audio chunk; this closes
    /// most of that race in practice, though real-hardware timing should be
    /// verified (see plan's verification section).
    func streamEnded(validBytes: UInt32) async -> Data? {
        drainAvailableBytes()
        return await buffer.finish(validBytes: validBytes)
    }

    /// Writes a complete TTS segment to the channel output stream. OutputStream
    /// can accept partial writes and temporarily run out of L2CAP credits, so
    /// this method yields until space is available instead of dropping bytes.
    @MainActor
    func writePCM16(_ data: Data, timeout: TimeInterval = 60) async throws {
        beginPacedWrite()
        defer { endPacedWrite() }
        try await writePCM16Chunk(data, timeout: timeout)
    }

    /// Starts one logical TTS stream. The L2CAP channel itself stays open for
    /// the whole BLE connection; this state only rate-limits bytes to the
    /// speaker's real consumption speed.
    @MainActor
    func beginPacedWrite() {
        pacedWriteStartedAt = Date()
        pacedWriteBytes = 0
    }

    @MainActor
    func endPacedWrite() {
        pacedWriteStartedAt = nil
        pacedWriteBytes = 0
    }

    /// Writes one streaming TTS chunk and applies end-to-end playback pacing.
    /// L2CAP credits only describe Bluetooth buffer space, not the board's I2S
    /// queue, so relying on `hasSpaceAvailable` alone can still overrun audio.
    @MainActor
    func writePCM16Chunk(_ data: Data, timeout: TimeInterval = 60) async throws {
        guard !data.isEmpty else { throw ChannelError.emptyAudio }
        guard let outputStream else { throw ChannelError.notOpen }

        if pacedWriteStartedAt == nil { beginPacedWrite() }

        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ChannelError.writeTimedOut }
            if let error = outputStream.streamError { throw ChannelError.stream(error.localizedDescription) }
            guard outputStream.streamStatus != .closed,
                  outputStream.streamStatus != .error else {
                throw ChannelError.notOpen
            }
            guard outputStream.hasSpaceAvailable else {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }

            let requested = min(writeChunkSize, data.count - offset)
            let written = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return outputStream.write(base.advanced(by: offset), maxLength: requested)
            }
            if written < 0 {
                throw ChannelError.stream(outputStream.streamError?.localizedDescription ?? "未知写入错误")
            }
            if written == 0 {
                try await Task.sleep(for: .milliseconds(5))
            } else {
                offset += written
            }
        }

        pacedWriteBytes += data.count
        if let startedAt = pacedWriteStartedAt {
            let pacedBytes = max(0, pacedWriteBytes - playbackLeadBytes)
            let targetElapsed = Double(pacedBytes) / Double(playbackBytesPerSecond)
            let elapsed = Date().timeIntervalSince(startedAt)
            if targetElapsed > elapsed {
                try await Task.sleep(for: .seconds(targetElapsed - elapsed))
            }
        }
    }

    private func drainAvailableBytes() {
        guard let inputStream else { return }
        var iterations = 0
        while inputStream.hasBytesAvailable, iterations < 16 {
            readAvailableBytes(from: inputStream)
            iterations += 1
        }
    }

    private func readAvailableBytes(from stream: InputStream) {
        var chunk = [UInt8](repeating: 0, count: readChunkSize)
        let bytesRead = stream.read(&chunk, maxLength: readChunkSize)
        guard bytesRead > 0 else { return }
        let data = Data(chunk[0..<bytesRead])
        Task { await buffer.append(data) }
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard let inputStream, aStream === inputStream else { return }
            readAvailableBytes(from: inputStream)
        case .errorOccurred, .endEncountered:
            // The channel closing mid-stream is reported to the coordinator via
            // the BLE disconnect/StreamEnd(status=1) path, not from here.
            break
        default:
            break
        }
    }

    enum ChannelError: LocalizedError {
        case notOpen
        case emptyAudio
        case writeTimedOut
        case stream(String)

        var errorDescription: String? {
            switch self {
            case .notOpen: return "L2CAP 音频通道尚未打开"
            case .emptyAudio: return "TTS 音频为空"
            case .writeTimedOut: return "L2CAP 音频发送超时"
            case .stream(let message): return "L2CAP 音频发送失败：\(message)"
            }
        }
    }
}
