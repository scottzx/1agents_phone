import XCTest

/// Conformance tests for the `pi --mode rpc` wire protocol encode/decode.
///
/// Shapes verified here were read from the locked pi_agent_rust commit
/// 44ddf80 (src/rpc.rs, src/agent.rs, src/model.rs):
///   request  {"type": <cmd>, "id": <str>, ...}
///   response {"type":"response","command":<cmd>,"success":<bool>,
///             "id"?:<str>,"data"?:<obj>,"error"?:<str>,"errorHints"?:[str]}
///   events   {"type":"<snake_case>", ...} with
///            assistantMessageEvent sub-type-tagged payloads.
final class PiRPCWireTests: XCTestCase {

    // MARK: - Helpers

    private func line(from object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func object(from line: String) -> [String: Any] {
        let data = line.data(using: .utf8)!
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func assertRequest(_ request: [String: Any],
                               type: String,
                               id: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertEqual(request["type"] as? String, type, file: file, line: line)
        XCTAssertEqual(request["id"] as? String, id, file: file, line: line)
    }

    // MARK: - Request encoding

    func testPromptRequestEncoding_basic() {
        let request = PiRPCRequestFactory.prompt(message: "Hello", id: "id-1")
        assertRequest(request, type: "prompt", id: "id-1")
        XCTAssertEqual(request["message"] as? String, "Hello")
        XCTAssertNil(request["images"])
        XCTAssertNil(request["streamingBehavior"])
    }

    func testPromptRequestEncoding_withImagesAndSteer() {
        let image = PiRPCImagePayload(mediaType: "image/png", base64Data: "aGVsbG8=")
        let request = PiRPCRequestFactory.prompt(
            message: "What is this?",
            images: [image],
            streamingBehavior: .steer,
            id: "id-2"
        )
        assertRequest(request, type: "prompt", id: "id-2")
        XCTAssertEqual(request["streamingBehavior"] as? String, "steer")

        let images = request["images"] as! [[String: Any]]
        XCTAssertEqual(images.count, 1)
        let source = images[0]["source"] as! [String: Any]
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "aGVsbG8=")
    }

    func testPromptRequestEncoding_followUp() {
        let request = PiRPCRequestFactory.prompt(
            message: "more", streamingBehavior: .followUp, id: "id-3"
        )
        XCTAssertEqual(request["streamingBehavior"] as? String, "followUp")
    }

    func testSetModelRequestEncoding() {
        let request = PiRPCRequestFactory.setModel(provider: "anthropic", modelId: "claude-sonnet-4-5", id: "id-4")
        assertRequest(request, type: "set_model", id: "id-4")
        XCTAssertEqual(request["provider"] as? String, "anthropic")
        XCTAssertEqual(request["modelId"] as? String, "claude-sonnet-4-5")
    }

    func testSetQueueModeEncoding() {
        let request = PiRPCRequestFactory.setQueueMode("set_steering_mode", mode: .oneAtATime, id: "id-5")
        assertRequest(request, type: "set_steering_mode", id: "id-5")
        XCTAssertEqual(request["mode"] as? String, "one-at-a-time")

        let followUp = PiRPCRequestFactory.setQueueMode("set_follow_up_mode", mode: .all, id: "id-6")
        XCTAssertEqual(followUp["mode"] as? String, "all")
    }

    func testSetAutoEncoding() {
        let compaction = PiRPCRequestFactory.setAuto("set_auto_compaction", enabled: false, id: "id-7")
        assertRequest(compaction, type: "set_auto_compaction", id: "id-7")
        XCTAssertEqual(compaction["enabled"] as? Bool, false)

        let retry = PiRPCRequestFactory.setAuto("set_auto_retry", enabled: true, id: "id-8")
        XCTAssertEqual(retry["enabled"] as? Bool, true)
    }

    func testSimpleCommandEncoding() {
        let request = PiRPCRequestFactory.simple("abort", id: "id-9")
        assertRequest(request, type: "abort", id: "id-9")
        XCTAssertEqual(request.count, 2)
    }

    // MARK: - Response decoding

    func testDecodeResponse_successWithData() {
        let line = line(from: [
            "type": "response",
            "command": "get_state",
            "success": true,
            "id": "id-1",
            "data": ["isStreaming": false, "sessionId": "sess-1"],
        ])
        let response = PiRPCLineParser.decodeResponse(line)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.command, "get_state")
        XCTAssertTrue(response?.success == true)
        XCTAssertEqual(response?.id, "id-1")
        XCTAssertEqual(response?.error, nil)
        XCTAssertEqual(response?.data?["sessionId"] as? String, "sess-1")
    }

    func testDecodeResponse_errorWithHints() {
        let line = line(from: [
            "type": "response",
            "command": "set_model",
            "success": false,
            "id": "id-2",
            "error": "Model not found: anthropic/nope",
            "errorHints": ["Check the model id"],
        ])
        let response = PiRPCLineParser.decodeResponse(line)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.command, "set_model")
        XCTAssertFalse(response?.success == true)
        XCTAssertEqual(response?.error, "Model not found: anthropic/nope")
        XCTAssertEqual(response?.errorHints, ["Check the model id"])
    }

    func testDecodeResponse_rejectsEventLines() {
        let line = line(from: ["type": "agent_start", "sessionId": "s1"])
        XCTAssertNil(PiRPCLineParser.decodeResponse(line))
    }

    func testLineParser_ignoresEmptyAndWhitespaceLines() {
        XCTAssertTrue(PiRPCLineParser.isIgnorable(""))
        XCTAssertTrue(PiRPCLineParser.isIgnorable("   \n"))
        XCTAssertFalse(PiRPCLineParser.isIgnorable("{}"))
    }

    // MARK: - Event decoding

    func testDecodeEvent_agentStart() {
        let line = line(from: ["type": "agent_start", "sessionId": "sess-abc"])
        guard case .agentStart(let sessionId)? = PiRPCLineParser.decodeEvent(line) else {
            return XCTFail("expected agentStart")
        }
        XCTAssertEqual(sessionId, "sess-abc")
    }

    func testDecodeEvent_agentEnd_withMessages() {
        let line = line(from: [
            "type": "agent_end",
            "sessionId": "sess-abc",
            "messages": [
                ["role": "user", "content": "hi"],
                ["role": "assistant", "content": [["type": "text", "text": "hello"]]],
            ],
        ])
        guard case .agentEnd(let sessionId, let messages, let error)? =
            PiRPCLineParser.decodeEvent(line) else {
            return XCTFail("expected agentEnd")
        }
        XCTAssertEqual(sessionId, "sess-abc")
        XCTAssertNil(error)
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "user")
        XCTAssertEqual(messages?[1]["role"] as? String, "assistant")
    }

    func testDecodeEvent_agentEnd_withError() {
        let line = line(from: [
            "type": "agent_end",
            "sessionId": "s",
            "error": "rate limited",
        ])
        guard case .agentEnd(_, _, let error)? = PiRPCLineParser.decodeEvent(line) else {
            return XCTFail("expected agentEnd")
        }
        XCTAssertEqual(error, "rate limited")
    }

    func testDecodeEvent_messageUpdate_textDelta() {
        let line = line(from: [
            "type": "message_update",
            "message": ["role": "assistant", "content": []],
            "assistantMessageEvent": [
                "type": "text_delta",
                "partial": ["content": [["type": "text", "text": "Hel"]]],
                "contentIndex": 0,
                "delta": "Hel",
            ],
        ])
        guard case .messageUpdate(let message, let sub)? =
            PiRPCLineParser.decodeEvent(line) else {
            return XCTFail("expected messageUpdate")
        }
        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertEqual(sub.kind, .textDelta)
        XCTAssertEqual(sub.delta, "Hel")
        XCTAssertEqual(sub.contentIndex, 0)
        let partialContent = sub.partial?["content"] as? [[String: Any]]
        XCTAssertEqual((partialContent?.first?["text"] as? String), "Hel")
    }

    func testDecodeEvent_messageUpdate_thinkingDelta() {
        let line = line(from: [
            "type": "message_update",
            "message": ["role": "assistant", "content": []],
            "assistantMessageEvent": ["type": "thinking_delta", "delta": "hmm"],
        ])
        guard case .messageUpdate(_, let sub)? = PiRPCLineParser.decodeEvent(line) else {
            return XCTFail("expected messageUpdate")
        }
        XCTAssertEqual(sub.kind, .thinkingDelta)
        XCTAssertEqual(sub.delta, "hmm")
    }

    func testDecodeEvent_messageUpdate_done() {
        let line = line(from: [
            "type": "message_update",
            "message": ["role": "assistant", "content": []],
            "assistantMessageEvent": ["type": "done", "reason": "stop"],
        ])
        guard case .messageUpdate(_, let sub)? = PiRPCLineParser.decodeEvent(line) else {
            return XCTFail("expected messageUpdate")
        }
        XCTAssertEqual(sub.kind, .done)
        XCTAssertEqual(sub.reason, "stop")
    }

    func testDecodeEvent_toolExecutionStart() {
        let line = line(from: [
            "type": "tool_execution_start",
            "toolCallId": "call-1",
            "toolName": "bash",
            "args": ["command": "ls -la"],
        ])
        guard case .toolExecutionStart(let toolCallId, let toolName, let args)? =
            PiRPCLineParser.decodeEvent(line) else {
            return XCTFail("expected toolExecutionStart")
        }
        XCTAssertEqual(toolCallId, "call-1")
        XCTAssertEqual(toolName, "bash")
        XCTAssertEqual(args["command"] as? String, "ls -la")
    }

    func testDecodeEvent_toolExecutionUpdateAndEnd() {
        let updateLine = line(from: [
            "type": "tool_execution_update",
            "toolCallId": "call-1",
            "toolName": "bash",
            "partialResult": "total 0",
        ])
        guard case .toolExecutionUpdate(_, _, let partial)? =
            PiRPCLineParser.decodeEvent(updateLine) else {
            return XCTFail("expected toolExecutionUpdate")
        }
        XCTAssertEqual(partial, "total 0")

        let endLine = line(from: [
            "type": "tool_execution_end",
            "toolCallId": "call-1",
            "toolName": "bash",
            "result": "ok",
            "isError": false,
        ])
        guard case .toolExecutionEnd(let toolCallId, _, let result, let isError)? =
            PiRPCLineParser.decodeEvent(endLine) else {
            return XCTFail("expected toolExecutionEnd")
        }
        XCTAssertEqual(toolCallId, "call-1")
        XCTAssertEqual(result, "ok")
        XCTAssertFalse(isError)
    }

    func testDecodeEvent_autoCompactionStart() {
        let line = line(from: ["type": "auto_compaction_start", "reason": "context window reached"])
        guard case .autoCompactionStart(let reason)? = PiRPCLineParser.decodeEvent(line) else {
            return XCTFail("expected autoCompactionStart")
        }
        XCTAssertEqual(reason, "context window reached")
    }

    func testDecodeEvent_unknownType() {
        let line = line(from: ["type": "something_new", "foo": "bar"])
        guard case .unknown(let type, let payload)? = PiRPCLineParser.decodeEvent(line) else {
            return XCTFail("expected unknown")
        }
        XCTAssertEqual(type, "something_new")
        XCTAssertEqual(payload["foo"] as? String, "bar")
    }

    func testDecodeEvent_rejectsResponseLines() {
        let line = line(from: ["type": "response", "command": "abort", "success": true])
        XCTAssertNil(PiRPCLineParser.decodeEvent(line))
    }

    // MARK: - Round trip (encode → decode)

    func testPromptRoundTrip() {
        let request = PiRPCRequestFactory.prompt(message: "ping", id: "rt-1")
        let encoded = line(from: request)
        let parsed = object(from: encoded)
        XCTAssertEqual(parsed["type"] as? String, "prompt")
        XCTAssertEqual(parsed["id"] as? String, "rt-1")
        XCTAssertEqual(parsed["message"] as? String, "ping")
    }
}
