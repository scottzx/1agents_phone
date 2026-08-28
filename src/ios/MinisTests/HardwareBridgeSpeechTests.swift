#if DEBUG
import XCTest

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

    func testMossPCMDownsamplerAveragesEachThreeSamples() {
        func pcm(_ samples: [Int16]) -> Data {
            var data = Data()
            for sample in samples {
                let value = UInt16(bitPattern: sample).littleEndian
                data.append(UInt8(truncatingIfNeeded: value))
                data.append(UInt8(truncatingIfNeeded: value >> 8))
            }
            return data
        }

        let source = pcm([300, 600, 900, -300, -600, -900])
        let result = MossSpeechClient.downsamplePCM48kTo16k(source[...])

        XCTAssertEqual(result, pcm([600, -600]))
    }
}
#endif
