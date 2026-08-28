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

    func detach() {
        inputStream?.close()
        outputStream?.close()
        inputStream?.remove(from: .main, forMode: .common)
        outputStream?.remove(from: .main, forMode: .common)
        inputStream = nil
        outputStream = nil
        channel = nil
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
}
