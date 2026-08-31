import XCTest
import MinisAppleDomain

final class AgentRunEngineTests: XCTestCase {
    func testProviderToolProviderLoopCarriesToolOutputAndEvents() async throws {
        let provider = ScriptedProvider()
        let tools = ToolRecorder()
        let events = EventRecorder()
        let engine = AgentRunEngine(dependencies: .init(
            provider: { request in try await provider.complete(request) },
            executeTool: { call in try await tools.execute(call) },
            emit: { event in await events.append(event) }
        ))

        let result = try await engine.run(
            messages: [.init(role: .user, content: "Find the answer")],
            tools: [.init(name: "lookup", description: "Look up a value")]
        )

        XCTAssertEqual(result.text, "The answer is 42.")
        XCTAssertEqual(result.toolRounds, 1)
        let toolOutput = await provider.toolOutputSeen()
        let executedTools = await tools.calls()
        let recordedEvents = await events.values()
        XCTAssertEqual(toolOutput, "lookup result")
        XCTAssertEqual(executedTools, ["lookup"])
        XCTAssertEqual(recordedEvents, [
            .started,
            .providerRequested(round: 0),
            .providerResponded(round: 0, toolCallCount: 1),
            .toolStarted(.init(id: "call-1", name: "lookup", argumentsJSON: "{\"query\":\"answer\"}")),
            .toolOutput(callID: "call-1", toolName: "lookup", output: "lookup result"),
            .providerRequested(round: 1),
            .providerResponded(round: 1, toolCallCount: 0),
            .completed(text: "The answer is 42.", toolRounds: 1)
        ])
    }

    func testCancellationProbePreventsProviderAndEmitsCancelled() async {
        let provider = ScriptedProvider()
        let events = EventRecorder()
        let engine = AgentRunEngine(dependencies: .init(
            provider: { request in try await provider.complete(request) },
            executeTool: { _ in "unused" },
            emit: { event in await events.append(event) },
            isCancelled: { true }
        ))

        do {
            _ = try await engine.run(messages: [.init(role: .user, content: "Stop")])
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await provider.requestCount()
        let recordedEvents = await events.values()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(recordedEvents, [.started, .cancelled])
    }

    func testUnavailableToolBecomesToolMessageAndLoopContinues() async throws {
        let provider = UnavailableToolProvider()
        let events = EventRecorder()
        let engine = AgentRunEngine(dependencies: .init(
            provider: { request in await provider.complete(request) },
            executeTool: { _ in XCTFail("Unavailable tool must not execute"); return "" },
            emit: { event in await events.append(event) }
        ))

        let result = try await engine.run(messages: [.init(role: .user, content: "Try it")])

        XCTAssertEqual(result.text, "Recovered")
        let toolMessage = await provider.lastToolMessage()
        XCTAssertEqual(toolMessage, "Tool error: Tool is unavailable: missing")
        let seenEvents = await events.values()
        XCTAssertTrue(seenEvents.contains(.toolFailed(callID: "missing-1", toolName: "missing", message: "Tool is unavailable: missing")))
    }
}

private actor ScriptedProvider {
    private var requests = 0
    private var output: String?

    func complete(_ request: AgentRunProviderRequest) throws -> AgentRunProviderTurn {
        requests += 1
        if requests == 1 {
            return .init(text: "", toolCalls: [.init(id: "call-1", name: "lookup", argumentsJSON: "{\"query\":\"answer\"}")])
        }
        output = request.messages.last?.content
        return .init(text: "The answer is 42.")
    }

    func requestCount() -> Int { requests }
    func toolOutputSeen() -> String? { output }
}

private actor ToolRecorder {
    private var values: [String] = []

    func execute(_ call: AgentRunToolCall) throws -> String {
        values.append(call.name)
        return "lookup result"
    }

    func calls() -> [String] { values }
}

private actor UnavailableToolProvider {
    private var requests = 0
    private var toolMessage: String?

    func complete(_ request: AgentRunProviderRequest) -> AgentRunProviderTurn {
        requests += 1
        if requests == 1 {
            return .init(text: nil, toolCalls: [.init(id: "missing-1", name: "missing", argumentsJSON: "{}")])
        }
        toolMessage = request.messages.last?.content
        return .init(text: "Recovered")
    }

    func lastToolMessage() -> String? { toolMessage }
}

private actor EventRecorder {
    private var recorded: [AgentRunEvent] = []

    func append(_ event: AgentRunEvent) { recorded.append(event) }
    func values() -> [AgentRunEvent] { recorded }
}
