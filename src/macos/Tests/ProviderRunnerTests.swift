import Foundation
import XCTest
import MinisProviderDomain
@testable import MinisDesktopCore

final class ProviderRunnerTests: XCTestCase {
    func testAnthropicOrdinaryAndToolCallingWireContracts() async throws {
        let transport = QueueProviderTransport(responses: [
            #"{"content":[{"type":"text","text":"hello from claude"}]}"#,
            #"{"content":[{"type":"tool_use","id":"toolu_1","name":"file_read","input":{"path":"README.md"}},{"type":"tool_use","id":"toolu_2","name":"file_read","input":{"path":"CHANGELOG.md"}}]}"#,
            #"{"content":[{"type":"text","text":"read complete"}]}"#
        ])
        let credentials = InMemoryCredentialStore()
        await credentials.save("anthropic-secret", account: "anthropic-account")
        let runner = OpenAICompatibleProviderRunner(credentials: credentials, transport: transport)
        let configuration = ProviderConfiguration(
            id: "anthropic-account",
            displayName: "Anthropic",
            endpoint: URL(string: "https://api.anthropic.test/v1/messages")!,
            model: "claude-test",
            providerType: .anthropic
        )

        let ordinary = try await runner.respond(
            messages: [RuntimeMessageRecord(sessionID: "session", role: .user, text: "hello")],
            systemPrompt: "Be useful",
            configuration: configuration
        )
        XCTAssertEqual(ordinary, "hello from claude")

        let tool = Self.toolDefinition
        let firstTurn = try await runner.complete(
            messages: [ProviderConversationMessage(role: "user", content: "read the file")],
            systemPrompt: nil,
            tools: [tool],
            configuration: configuration
        )
        XCTAssertEqual(firstTurn.toolCalls, [
            ProviderToolCall(id: "toolu_1", name: "file_read", arguments: #"{"path":"README.md"}"#),
            ProviderToolCall(id: "toolu_2", name: "file_read", arguments: #"{"path":"CHANGELOG.md"}"#)
        ])

        let finalTurn = try await runner.complete(
            messages: [
                ProviderConversationMessage(role: "user", content: "read the file"),
                ProviderConversationMessage(role: "assistant", content: nil, toolCalls: firstTurn.toolCalls),
                ProviderConversationMessage(role: "tool", content: "contents", toolCallID: "toolu_1"),
                ProviderConversationMessage(role: "tool", content: "changes", toolCallID: "toolu_2")
            ],
            systemPrompt: nil,
            tools: [tool],
            configuration: configuration
        )
        XCTAssertEqual(finalTurn.content, "read complete")

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self).contains("anthropic-secret"))

        let ordinaryBody = try Self.jsonObject(requests[0])
        XCTAssertEqual(ordinaryBody["system"] as? String, "Be useful")
        XCTAssertEqual(ordinaryBody["model"] as? String, "claude-test")
        let toolBody = try Self.jsonObject(requests[1])
        let tools = try XCTUnwrap(toolBody["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "file_read")
        XCTAssertNotNil(tools.first?["input_schema"] as? [String: Any])
        let resultBody = try Self.jsonObject(requests[2])
        let resultMessages = try XCTUnwrap(resultBody["messages"] as? [[String: Any]])
        let resultBlocks = try XCTUnwrap(resultMessages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(resultBlocks.count, 2)
        XCTAssertEqual(resultBlocks.first?["type"] as? String, "tool_result")
        XCTAssertEqual(resultBlocks.first?["tool_use_id"] as? String, "toolu_1")
    }

    func testGeminiOrdinaryAndToolCallingWireContracts() async throws {
        let transport = QueueProviderTransport(responses: [
            #"{"candidates":[{"content":{"parts":[{"text":"hello from gemini"}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"file_read","args":{"path":"README.md"}}}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"read complete"}]}}]}"#
        ])
        let credentials = InMemoryCredentialStore()
        await credentials.save("gemini-secret", account: "gemini-account")
        let runner = OpenAICompatibleProviderRunner(credentials: credentials, transport: transport)
        let configuration = ProviderConfiguration(
            id: "gemini-account",
            displayName: "Gemini",
            endpoint: URL(string: "https://generativelanguage.test/v1beta/models/gemini-test:generateContent")!,
            model: "gemini-test",
            providerType: .gemini
        )

        let ordinary = try await runner.respond(
            messages: [RuntimeMessageRecord(sessionID: "session", role: .user, text: "hello")],
            systemPrompt: "Be useful",
            configuration: configuration
        )
        XCTAssertEqual(ordinary, "hello from gemini")

        let tool = Self.toolDefinition
        let firstTurn = try await runner.complete(
            messages: [ProviderConversationMessage(role: "user", content: "read the file")],
            systemPrompt: nil,
            tools: [tool],
            configuration: configuration
        )
        let call = try XCTUnwrap(firstTurn.toolCalls.first)
        XCTAssertEqual(call.name, "file_read")
        XCTAssertEqual(call.arguments, #"{"path":"README.md"}"#)
        XCTAssertFalse(call.id.isEmpty)

        let finalTurn = try await runner.complete(
            messages: [
                ProviderConversationMessage(role: "user", content: "read the file"),
                ProviderConversationMessage(role: "assistant", content: nil, toolCalls: [call]),
                ProviderConversationMessage(role: "tool", content: #"{"contents":"ok"}"#, toolCallID: call.id)
            ],
            systemPrompt: nil,
            tools: [tool],
            configuration: configuration
        )
        XCTAssertEqual(finalTurn.content, "read complete")

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-goog-api-key"), "gemini-secret")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self).contains("gemini-secret"))

        let ordinaryBody = try Self.jsonObject(requests[0])
        let instruction = try XCTUnwrap(ordinaryBody["systemInstruction"] as? [String: Any])
        XCTAssertNotNil(instruction["parts"] as? [[String: Any]])
        let toolBody = try Self.jsonObject(requests[1])
        let toolContainers = try XCTUnwrap(toolBody["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(toolContainers.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations.first?["name"] as? String, "file_read")
        let parameters = try XCTUnwrap(declarations.first?["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "OBJECT")
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertEqual((properties["path"] as? [String: Any])?["type"] as? String, "STRING")
        let resultBody = try Self.jsonObject(requests[2])
        let contents = try XCTUnwrap(resultBody["contents"] as? [[String: Any]])
        let resultParts = try XCTUnwrap(contents.last?["parts"] as? [[String: Any]])
        let functionResponse = try XCTUnwrap(resultParts.first?["functionResponse"] as? [String: Any])
        XCTAssertEqual(functionResponse["name"] as? String, "file_read")
        XCTAssertEqual((functionResponse["response"] as? [String: Any])?["contents"] as? String, "ok")
    }

    func testOAuthCredentialsUseBearerHeadersWithoutLeakingIntoBodies() async throws {
        let anthropicTransport = QueueProviderTransport(responses: [
            #"{"content":[{"type":"text","text":"ok"}]}"#
        ])
        let geminiTransport = QueueProviderTransport(responses: [
            #"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#
        ])
        let credentials = InMemoryCredentialStore()
        await credentials.save("oauth-secret", account: "oauth-account")

        let anthropic = OpenAICompatibleProviderRunner(credentials: credentials, transport: anthropicTransport)
        _ = try await anthropic.respond(
            messages: [RuntimeMessageRecord(sessionID: "session", role: .user, text: "hello")],
            systemPrompt: nil,
            configuration: ProviderConfiguration(
                id: "oauth-account",
                endpoint: URL(string: "https://api.anthropic.test/v1/messages")!,
                model: "claude-test",
                providerType: .anthropic,
                credentialType: .oauth
            )
        )

        let anthropicRequests = await anthropicTransport.recordedRequests()
        let anthropicRequest = try XCTUnwrap(anthropicRequests.first)
        XCTAssertEqual(anthropicRequest.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-secret")
        XCTAssertEqual(anthropicRequest.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNil(anthropicRequest.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertFalse(String(decoding: try XCTUnwrap(anthropicRequest.httpBody), as: UTF8.self).contains("oauth-secret"))

        let gemini = OpenAICompatibleProviderRunner(credentials: credentials, transport: geminiTransport)
        _ = try await gemini.respond(
            messages: [RuntimeMessageRecord(sessionID: "session", role: .user, text: "hello")],
            systemPrompt: nil,
            configuration: ProviderConfiguration(
                id: "oauth-account",
                endpoint: URL(string: "https://generativelanguage.test/generateContent")!,
                model: "gemini-test",
                providerType: .gemini,
                credentialType: .oauth
            )
        )

        let geminiRequests = await geminiTransport.recordedRequests()
        let geminiRequest = try XCTUnwrap(geminiRequests.first)
        XCTAssertEqual(geminiRequest.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-secret")
        XCTAssertNil(geminiRequest.value(forHTTPHeaderField: "x-goog-api-key"))
        XCTAssertFalse(String(decoding: try XCTUnwrap(geminiRequest.httpBody), as: UTF8.self).contains("oauth-secret"))
    }

    private static let toolDefinition = RuntimeToolDefinition(
        name: "file_read",
        description: "Read a file",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["path": .object(["type": .string("string")])]),
            "required": .array([.string("path")])
        ])
    )

    private static func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

private actor QueueProviderTransport: ProviderHTTPTransport {
    private var responses: [Data]
    private var requests: [URLRequest] = []

    init(responses: [String]) {
        self.responses = responses.map { Data($0.utf8) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw ProviderRunnerError.invalidResponse }
        let data = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
