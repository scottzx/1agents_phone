#if DEBUG
import Foundation
import XCTest
@testable import Minis

final class HardwareBridgeSpeechTests: XCTestCase {
    func testVoiceReplyStartFrameUsesLittleEndianSessionID() throws {
        let data = AgentLinkCodec.voiceReplyCommand(
            sessionID: 0x1234_ABCD,
            status: 2,
            sequence: 7
        )
        let frame = try AgentLinkCodec.decode(data)

        XCTAssertEqual(frame.type, .command)
        XCTAssertEqual(frame.identifier, 0x05)
        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(Array(frame.payload), [0xCD, 0xAB, 0x34, 0x12, 0x02])
    }

    func testVoiceReplyEndFrameUsesStatusThree() throws {
        let data = AgentLinkCodec.voiceReplyCommand(
            sessionID: 1,
            status: 3,
            sequence: 8
        )
        let frame = try AgentLinkCodec.decode(data)
        XCTAssertEqual(Array(frame.payload), [1, 0, 0, 0, 3])
    }

    func testMossWAVWrapsDevicePCMWithoutChangingSamples() {
        let pcm = Data([0x01, 0x02, 0xFE, 0xFF])
        let wav = MossSpeechClient.wavData(fromPCM16: pcm)

        XCTAssertEqual(wav.count, 48)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(Array(wav[40..<44]), [4, 0, 0, 0])
        XCTAssertEqual(Data(wav[44...]), pcm)
    }

    func testLocalASRSplitsLongPCMAtThirtySecondSampleBoundaries() {
        let thirtySeconds = 16_000 * 2 * 30
        let pcm = Data(repeating: 0x5A, count: thirtySeconds * 2 + 18)

        let segments = HardwareVoiceTranscriber.pcmSegments(pcm, seconds: 30)

        XCTAssertEqual(segments.map(\.count), [thirtySeconds, thirtySeconds, 18])
        XCTAssertEqual(segments.reduce(into: Data()) { $0.append($1) }, pcm)
        XCTAssertTrue(segments.allSatisfy { $0.count.isMultiple(of: 2) })
    }

    func testLocalASRTranscriptMergeKeepsChineseTightAndEnglishReadable() {
        XCTAssertEqual(
            HardwareVoiceTranscriber.mergeTranscriptSegments(["你好，", "世界。"]),
            "你好，世界。"
        )
        XCTAssertEqual(
            HardwareVoiceTranscriber.mergeTranscriptSegments(["hello", "world"]),
            "hello world"
        )
    }

    func testDeviceSampleRateMatchesTheBoardCodec() {
        // Everything handed to the board is converted to exactly this, so its
        // own resampler never runs — that resampler reported one output size
        // and wrote a much larger one, overrunning the buffer and panicking
        // playback a second in. The board's AUDIO_OUTPUT_SAMPLE_RATE is 24000.
        XCTAssertEqual(MossSpeechClient.deviceSampleRate, 24_000)
    }

    func testL2CAPOutputIsWritableOnlyAfterStreamFinishesOpening() {
        XCTAssertEqual(
            AgentLinkL2CAPReceiver.writeSideState(hasOutputStream: false, status: .notOpen),
            .detached
        )
        XCTAssertEqual(
            AgentLinkL2CAPReceiver.writeSideState(hasOutputStream: true, status: .opening),
            .opening
        )
        XCTAssertEqual(
            AgentLinkL2CAPReceiver.writeSideState(hasOutputStream: true, status: .open),
            .writable
        )
        XCTAssertEqual(
            AgentLinkL2CAPReceiver.writeSideState(hasOutputStream: true, status: .error),
            .failed
        )
    }
}
#endif
