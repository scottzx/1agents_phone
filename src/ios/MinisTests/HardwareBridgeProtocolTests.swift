#if DEBUG
import XCTest

/// Wire-format tests for the agent_link extensions: typed event decoding, the
/// generic 0x33 encoder, and 0x37 roster fragmentation.
///
/// Expected bytes are transcribed from the firmware's own encoders in
/// Agent_link/components/agent_link/src/agent_link.cpp rather than from this
/// app's decoders, so a drift on either side fails here instead of on a board.
final class HardwareBridgeProtocolTests: XCTestCase {

    // MARK: - Frame helpers

    /// Builds a device→App event frame the way `agentlink::BuildEvent` does:
    /// version, msg_type=Event(0x03), event id, sequence 0, LE length, payload.
    private func eventFrame(_ id: UInt8, _ payload: [UInt8]) -> Data {
        var frame = Data([0x01, 0x03, id, 0x00,
                          UInt8(payload.count & 0xff), UInt8((payload.count >> 8) & 0xff)])
        frame.append(contentsOf: payload)
        return frame
    }

    // MARK: - Event decoding

    func testPowerStatusEventDecodesStateAndLevel() throws {
        // agent_link.cpp:560 substitutes 0x02 on the low-battery edge instead
        // of the charging flag, so state is not a plain boolean.
        let event = try AgentLinkCodec.event(from: eventFrame(0x14, [0x02, 4]))
        XCTAssertEqual(event, .powerStatus(state: .lowBatteryEdge, level: 4))

        let charging = try AgentLinkCodec.event(from: eventFrame(0x14, [0x01, 87]))
        XCTAssertEqual(charging, .powerStatus(state: .charging, level: 87))
    }

    func testPowerStatusWithUnknownStateFallsBackRatherThanFailing() throws {
        // The level is the useful half; a future state byte must not cost us
        // the battery reading.
        let event = try AgentLinkCodec.event(from: eventFrame(0x14, [0x09, 55]))
        XCTAssertEqual(event, .powerStatus(state: .discharging, level: 55))
    }

    func testIoReadingDecodesFloatValueByEndpointId() throws {
        // [id_len][id][val_type][value] — agent_link.cpp:679-687. f32 = type 3.
        var payload: [UInt8] = [5]
        payload.append(contentsOf: Array("temp0".utf8))
        payload.append(3)
        payload.append(contentsOf: withUnsafeBytes(of: Float(21.5).bitPattern.littleEndian) { Array($0) })

        guard case .ioReading(let endpointId, let value) = try XCTUnwrap(AgentLinkCodec.event(from: eventFrame(0x19, payload))) else {
            return XCTFail("expected an ioReading event")
        }
        XCTAssertEqual(endpointId, "temp0")
        XCTAssertEqual(value, .float(21.5))
    }

    func testIoReadingDecodesVec3() throws {
        var payload: [UInt8] = [4]
        payload.append(contentsOf: Array("imu0".utf8))
        payload.append(5) // AGENT_VAL_VEC3
        for component in [Float(1), Float(-2), Float(0.5)] {
            payload.append(contentsOf: withUnsafeBytes(of: component.bitPattern.littleEndian) { Array($0) })
        }
        guard case .ioReading(_, let value) = try XCTUnwrap(AgentLinkCodec.event(from: eventFrame(0x19, payload))) else {
            return XCTFail("expected an ioReading event")
        }
        XCTAssertEqual(value, .vector3(1, -2, 0.5))
    }

    func testIoReadingWithUnknownValueTypeKeepsRawBytes() throws {
        var payload: [UInt8] = [3]
        payload.append(contentsOf: Array("new".utf8))
        payload.append(0x7f) // not an agent_val_t we know
        payload.append(contentsOf: [0xde, 0xad])
        guard case .ioReading(_, let value) = try XCTUnwrap(AgentLinkCodec.event(from: eventFrame(0x19, payload))) else {
            return XCTFail("expected an ioReading event")
        }
        XCTAssertEqual(value, .unsupported(type: 0x7f, raw: Data([0xde, 0xad])))
    }

    func testManifestChangedDecodesLittleEndianRevision() throws {
        let event = try AgentLinkCodec.event(from: eventFrame(0x1A, [0x2A, 0x01, 0x00, 0x00]))
        XCTAssertEqual(event, .manifestChanged(rev: 298))
    }

    func testSelectedAgentDecodesIndexAndIdentifier() throws {
        var payload: [UInt8] = [2, 9]
        payload.append(contentsOf: Array("agent-abc".utf8))
        let event = try AgentLinkCodec.event(from: eventFrame(0x16, payload))
        XCTAssertEqual(event, .selectedAgent(index: 2, agentId: "agent-abc"))
    }

    func testCustomEventFloorIsRespected() throws {
        // AGENT_EVT_CUSTOM = 100 (0x64); everything at or above is board-private
        // and must not be mistaken for a protocol event.
        let custom = try AgentLinkCodec.event(from: eventFrame(0x64, [1, 2, 3]))
        XCTAssertEqual(custom, .custom(id: 0x64, payload: Data([1, 2, 3])))

        let unknown = try AgentLinkCodec.event(from: eventFrame(0x40, [9]))
        XCTAssertEqual(unknown, .unknown(id: 0x40, payload: Data([9])))
    }

    func testResponseFramesAreNotDecodedAsEvents() throws {
        // msg_type 0x02 = Response. The event decoder must decline these so a
        // command ACK never masquerades as device input.
        let response = Data([0x01, 0x02, 0x33, 0x07, 0x00, 0x00])
        XCTAssertNil(try AgentLinkCodec.event(from: response))
    }

    // MARK: - Generic 0x33 IoActuate

    func testGenericIoActuateMatchesScreenTextLayout() throws {
        // screenTextCommand is now one caller of the generic encoder; the bytes
        // it produces must not have changed, since a shipped board parses them.
        let generic = AgentLinkCodec.ioActuateCommand(
            endpointId: "screen0",
            args: Data("hi".utf8),
            sequence: 3,
            nulTerminate: true
        )
        XCTAssertEqual(generic, AgentLinkCodec.screenTextCommand("hi", sequence: 3))

        let frame = try AgentLinkCodec.decode(generic)
        XCTAssertEqual(frame.identifier, AgentLinkCodec.ioActuateCommandID)
        XCTAssertEqual(frame.type, .command)
        // [id_len][id][args][NUL]
        XCTAssertEqual([UInt8](frame.payload).first, 7)
        XCTAssertEqual([UInt8](frame.payload).last, 0)
    }

    func testScreenTextTrimsByCharacterSoEmojiSurvive() throws {
        // Trimming by byte would leave a partial UTF-8 sequence in a payload the
        // board reads as a C string.
        let long = String(repeating: "语", count: 400) // 1200 UTF-8 bytes
        let frame = try AgentLinkCodec.decode(AgentLinkCodec.screenTextCommand(long, sequence: 1))
        let body = frame.payload.dropFirst(1 + 7).dropLast() // id_len + id, minus NUL
        XCTAssertNotNil(String(data: Data(body), encoding: .utf8), "trimmed text must stay valid UTF-8")
        XCTAssertLessThanOrEqual(body.count, AgentLinkCodec.maximumScreenTextBytes)
    }

    // MARK: - 0x37 roster fragmentation

    func testRosterFragmentsCarryIndexAndLastFlag() throws {
        let json = Data(repeating: 0x41, count: 250)
        let frames = AgentLinkCodec.agentRosterCommands(json: json, fragmentBudget: 100, startingSequence: 0)
        XCTAssertEqual(frames.count, 3) // 100 + 100 + 50

        var reassembled = Data()
        for (offset, frame) in frames.enumerated() {
            let decoded = try AgentLinkCodec.decode(frame)
            XCTAssertEqual(decoded.identifier, AgentLinkCodec.setAgentRosterCommandID)
            XCTAssertEqual(decoded.type, .command)
            XCTAssertEqual(decoded.sequence, UInt8(offset), "sequence advances one per fragment")
            let bytes = [UInt8](decoded.payload)
            XCTAssertEqual(bytes[0], UInt8(offset))
            XCTAssertEqual(bytes[1], offset == frames.count - 1 ? 1 : 0)
            reassembled.append(decoded.payload.dropFirst(2))
        }
        XCTAssertEqual(reassembled, json)
    }

    func testRosterExactlyFillingBudgetDoesNotEmitEmptyTrailingFragment() throws {
        // The classic off-by-one: a payload that is an exact multiple of the
        // budget must still mark its final fragment `last`, not append an empty
        // one, or the device waits forever for a terminator.
        let json = Data(repeating: 0x42, count: 200)
        let frames = AgentLinkCodec.agentRosterCommands(json: json, fragmentBudget: 100, startingSequence: 0)
        XCTAssertEqual(frames.count, 2)
        let final = try AgentLinkCodec.decode(frames[1])
        XCTAssertEqual([UInt8](final.payload)[1], 1)
        XCTAssertEqual(final.payload.count, 2 + 100)
    }

    func testEmptyRosterStillEmitsOneTerminatingFragment() throws {
        // "No agents configured" is a real state the device must be able to
        // reach; dropping the push would leave a stale roster on screen.
        let frames = AgentLinkCodec.agentRosterCommands(json: Data(), fragmentBudget: 100, startingSequence: 5)
        XCTAssertEqual(frames.count, 1)
        let only = try AgentLinkCodec.decode(frames[0])
        XCTAssertEqual([UInt8](only.payload), [0, 1])
    }

    func testFragmentBudgetMatchesFirmwareArithmetic() {
        // agent_link.cpp:269-276: mtu - 3 - 8, clamped to [16, 480].
        XCTAssertEqual(AgentLinkCodec.fragmentBudget(attMTU: 247), 247 - 3 - 8)
        XCTAssertEqual(AgentLinkCodec.fragmentBudget(attMTU: 2000), 480, "clamped to the firmware ceiling")
        XCTAssertEqual(AgentLinkCodec.fragmentBudget(attMTU: 20), 150, "below the guard, firmware falls back to 150")
    }

    // MARK: - Manifest reassembly

    func testManifestAssemblerJoinsFragmentsSplitInsideACodepoint() throws {
        // The firmware splits manifest JSON at arbitrary byte offsets, so a
        // fragment boundary can land inside a multi-byte character. Decoding a
        // fragment on its own would corrupt it; only the join may be decoded.
        let json = Data(#"{"proto":1,"rev":2,"caps":4,"io":[{"id":"温度","dir":"in","kind":"temperature","value":"f32"}]}"#.utf8)
        // Cut one byte into the first "温" so the boundary is guaranteed to fall
        // mid-codepoint regardless of how the literal above is later edited.
        let firstHanzi = try XCTUnwrap(json.range(of: Data("温".utf8)))
        let split = firstHanzi.lowerBound + 1
        XCTAssertNil(String(data: json.prefix(split), encoding: .utf8), "test is only meaningful if the split breaks a codepoint")

        var assembler = IoManifestAssembler()
        XCTAssertEqual(assembler.accept(index: 0, isLast: false, fragment: json.prefix(split)), .incomplete)
        let result = assembler.accept(index: 1, isLast: true, fragment: json.suffix(from: split))
        guard case .complete(let joined) = result else { return XCTFail("expected a complete manifest") }

        let manifest = IoManifestAssembler.parse(joined)
        XCTAssertEqual(manifest?.rev, 2)
        XCTAssertEqual(manifest?.endpoints.first?.id, "温度")
        XCTAssertEqual(manifest?.endpoints.first?.value, "f32")
        XCTAssertTrue(manifest?.hasCapability(.screen) ?? false, "caps 4 is AGENT_CAP_SCREEN")
    }

    func testManifestAssemblerDropsBufferOnOutOfOrderFragment() {
        var assembler = IoManifestAssembler()
        _ = assembler.accept(index: 0, isLast: false, fragment: Data("{".utf8))
        XCTAssertEqual(
            assembler.accept(index: 3, isLast: false, fragment: Data("}".utf8)),
            .desynchronized(expected: 1, received: 3)
        )
        // After a desync the buffer must be empty, so a re-fetch starting at 0
        // produces clean JSON rather than concatenating onto the old partial.
        let result = assembler.accept(index: 0, isLast: true, fragment: Data(#"{"io":[]}"#.utf8))
        guard case .complete(let json) = result else { return XCTFail("expected a complete manifest") }
        XCTAssertEqual(IoManifestAssembler.parse(json)?.endpoints.count, 0)
    }

    func testManifestRestartsWhenBoardResendsFromZero() {
        // A board that retries its send starts again at index 0 mid-stream;
        // that must reset rather than read as a desync.
        var assembler = IoManifestAssembler()
        _ = assembler.accept(index: 0, isLast: false, fragment: Data("garbage".utf8))
        let result = assembler.accept(index: 0, isLast: true, fragment: Data(#"{"io":[]}"#.utf8))
        guard case .complete(let json) = result else { return XCTFail("expected a complete manifest") }
        XCTAssertEqual(String(data: json, encoding: .utf8), #"{"io":[]}"#)
    }

    func testManifestEndpointAudienceHidesUserOnlyEndpointsFromTheModel() {
        let json = Data(#"{"io":[{"id":"reboot","dir":"out","kind":"system","value":"bool","audience":"user"}]}"#.utf8)
        let endpoint = IoManifestAssembler.parse(json)?.endpoints.first
        XCTAssertEqual(endpoint?.isActuator, true)
        XCTAssertEqual(endpoint?.isLLMVisible, false)
    }

    // MARK: - Roster payloads

    func testRosterSnapshotRoundTripsThroughItsCompactKeys() throws {
        let snapshot = DeviceRosterSnapshot(
            rev: 7,
            conversation: DeviceConversation(id: "s-1", kind: .direct, title: "教练"),
            members: [
                DeviceParticipant(id: "a1", kind: .agent, name: "教练", emoji: "💪",
                                  accentColor: "#5B8DEF", title: "健身教练"),
            ]
        )
        let json = try DeviceRosterJSON.encode(snapshot)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertTrue(text.contains(#""n":"教练""#), "member keys stay single-letter to fit the GATT budget")
        XCTAssertTrue(text.contains(#""conv""#))
        XCTAssertEqual(try DeviceRosterJSON.decode(DeviceRosterSnapshot.self, from: json), snapshot)
    }

    func testRosterWithoutACatalogLeavesConvsOffTheWire() throws {
        // A bound single-agent push has no chat list to send, and the bytes it
        // puts on the link must not grow just because the catalog exists.
        let snapshot = DeviceRosterSnapshot(
            rev: 1,
            conversation: DeviceConversation(id: "a1", kind: .direct, title: "教练"),
            members: [
                DeviceParticipant(id: "a1", kind: .agent, name: "教练", emoji: "💪",
                                  accentColor: "#5B8DEF", title: "健身教练"),
            ]
        )
        let text = try XCTUnwrap(String(data: try DeviceRosterJSON.encode(snapshot), encoding: .utf8))
        XCTAssertFalse(text.contains(#""convs""#))
    }

    func testCatalogCarriesGroupsAndOneToOneRowsInOnePayload() throws {
        // What goes down the moment the link comes up: every group and every
        // agent, so the board can draw its chat list before any turn has run.
        let snapshot = DeviceRosterSnapshot(
            rev: 3,
            conversation: DeviceConversation(id: "g1", kind: .group, title: "研讨群"),
            members: [
                DeviceParticipant(id: "a1", kind: .agent, name: "小翠", emoji: "✨",
                                  accentColor: "#00B8A9", title: "总管"),
                DeviceParticipant(id: "a2", kind: .agent, name: "市场", emoji: "📈",
                                  accentColor: "#F5A623", title: "市场专家"),
            ],
            conversations: [
                DeviceConversationEntry(id: "g1", kind: .group, title: "研讨群", emoji: "👥",
                                        accentColor: "#5B8DEF", ownerId: "a1",
                                        memberIds: ["a1", "a2"]),
                DeviceConversationEntry(id: "a1", kind: .direct, title: "小翠", emoji: "✨",
                                        accentColor: "#00B8A9", ownerId: nil, memberIds: ["a1"]),
                DeviceConversationEntry(id: "a2", kind: .direct, title: "市场", emoji: "📈",
                                        accentColor: "#F5A623", ownerId: nil, memberIds: ["a2"]),
            ]
        )

        let json = try DeviceRosterJSON.encode(snapshot)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertTrue(text.contains(#""convs""#))
        XCTAssertTrue(text.contains(#""own":"a1""#))
        XCTAssertTrue(text.contains(#""m":["a1","a2"]"#), "member ids ride as a list of ids, not copies")
        // A member in two rows is still one record: the catalog references
        // members by id precisely so it stays inside the board's 8 KiB buffer.
        XCTAssertEqual(text.components(separatedBy: #""n":"小翠""#).count - 1, 1)
        XCTAssertEqual(try DeviceRosterJSON.decode(DeviceRosterSnapshot.self, from: json), snapshot)
    }

    func testRosterFromPreCatalogFirmwareDecodesWithAnEmptyCatalog() throws {
        let json = Data(#"{"conv":{"id":"s-1","kind":"direct","title":"教练"},"members":[],"rev":2}"#.utf8)
        let snapshot = try DeviceRosterJSON.decode(DeviceRosterSnapshot.self, from: json)
        XCTAssertTrue(snapshot.conversations.isEmpty)
    }

    func testCatalogEntryLookupResolvesWhatTheDeviceEchoesBack() throws {
        // The board reports the row it opened by id (0x16); the phone has to be
        // able to turn that back into the conversation it pushed.
        let entry = DeviceConversationEntry(id: "g1", kind: .group, title: "研讨群", emoji: "👥",
                                            accentColor: "#5B8DEF", ownerId: nil, memberIds: ["a1"])
        let snapshot = DeviceRosterSnapshot(
            rev: 1,
            conversation: DeviceConversation(id: "g1", kind: .group, title: "研讨群"),
            members: [
                DeviceParticipant(id: "a1", kind: .agent, name: "小翠", emoji: "✨",
                                  accentColor: "#00B8A9", title: "总管"),
            ],
            conversations: [entry]
        )
        XCTAssertEqual(snapshot.entry("g1"), entry)
        XCTAssertNil(snapshot.entry("nope"))
    }

    func testChatMessageCarriesSenderSoGroupChatNeedsNoFirmwareChange() throws {
        let message = DeviceChatMessage(conversationId: "s-1", from: "a1", sequence: 12, text: "你好")
        let text = try XCTUnwrap(String(data: try DeviceRosterJSON.encode(message), encoding: .utf8))
        XCTAssertTrue(text.contains(#""from":"a1""#))
        XCTAssertTrue(text.contains(#""seq":12"#))
    }

    func testStateEventMatchesTheShapeInTheDemoPRD() throws {
        // DEMO_PRD.md §5 pins these key names and state strings; work package B
        // is building the LVGL state machine against them.
        let event = DeviceStateEvent(state: .marketSpeaking, name: "市场专家", textBrief: "正在评估市场空间...")
        let text = try XCTUnwrap(String(data: try DeviceRosterJSON.encode(event), encoding: .utf8))
        XCTAssertTrue(text.contains(#""type":"state""#))
        XCTAssertTrue(text.contains(#""state":"market_speaking""#))
        XCTAssertTrue(text.contains(#""text_brief""#))
    }
}
#endif
