import Foundation
import MinisProviderDomain

/// Compatibility name for callers compiled against the initial macOS preview.
/// The value itself now has one Foundation-only source in MinisProviderDomain.
public typealias RuntimeProviderConfiguration = ProviderConfiguration

public enum ProviderRunnerError: LocalizedError, Sendable {
    case notConfigured
    case unsupportedProtocol(String)
    case invalidResponse
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Configure a model provider in Settings before sending messages."
        case .unsupportedProtocol(let provider): "The provider protocol for \(provider) is not implemented on macOS yet."
        case .invalidResponse: "The provider returned an invalid response."
        case .http(let status, let body): "Provider request failed (HTTP \(status)): \(body)"
        }
    }
}

public protocol ProviderRunner: Sendable {
    func respond(messages: [RuntimeMessageRecord], systemPrompt: String?, configuration: ProviderConfiguration) async throws -> String
}

/// Small transport seam used by provider backends. Production requests still
/// use URLSession, while tests can capture the exact wire contract without
/// touching the network or exposing credentials through process state.
public protocol ProviderHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionProviderHTTPTransport: ProviderHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public actor OpenAICompatibleProviderRunner: ToolCallingProviderRunner {
    private let credentials: any CredentialStore
    private let transport: any ProviderHTTPTransport
    private let kimiOAuth: KimiOAuthManager

    public init(credentials: any CredentialStore = KeychainCredentialStore(), session: URLSession = .shared) {
        self.credentials = credentials
        self.transport = URLSessionProviderHTTPTransport(session: session)
        self.kimiOAuth = KimiOAuthManager(credentials: credentials, transport: self.transport)
    }

    public init(credentials: any CredentialStore, transport: any ProviderHTTPTransport) {
        self.credentials = credentials
        self.transport = transport
        self.kimiOAuth = KimiOAuthManager(credentials: credentials, transport: transport)
    }

    public func respond(messages: [RuntimeMessageRecord], systemPrompt: String?, configuration: ProviderConfiguration) async throws -> String {
        let conversation = messages.filter { $0.role != .system }.map {
            ProviderConversationMessage(role: $0.role.rawValue, content: $0.text)
        }
        let turn = try await complete(messages: conversation, systemPrompt: systemPrompt, tools: [], configuration: configuration)
        guard let text = turn.content, !text.isEmpty else { throw ProviderRunnerError.invalidResponse }
        return text
    }

    public func complete(messages: [ProviderConversationMessage], systemPrompt: String?, tools: [RuntimeToolDefinition], configuration: ProviderConfiguration) async throws -> ProviderTurn {
        let key: String
        if configuration.providerType == .kimiCode, configuration.credentialType == .oauth {
            key = try await kimiOAuth.validAccessToken(account: configuration.id)
        } else {
            key = try await credentials.load(account: configuration.id)
        }
        switch configuration.providerType {
        case .anthropic:
            return try await completeAnthropic(messages: messages, systemPrompt: systemPrompt, tools: tools, configuration: configuration, key: key)
        case .gemini:
            return try await completeGemini(messages: messages, systemPrompt: systemPrompt, tools: tools, configuration: configuration, key: key)
        case .openAI, .openRouter, .xAI, .kimiCode:
            return try await completeOpenAI(messages: messages, systemPrompt: systemPrompt, tools: tools, configuration: configuration, key: key)
        case .openAIResponses, .antigravity, .unsupported:
            // Responses and Antigravity are distinct wire protocols. Refuse
            // them until their native implementations and OAuth refresh paths
            // exist instead of presenting a false successful configuration.
            throw ProviderRunnerError.unsupportedProtocol(configuration.unknownProviderTypeRaw ?? configuration.providerType.rawValue)
        }
    }

    private func completeOpenAI(messages: [ProviderConversationMessage], systemPrompt: String?, tools: [RuntimeToolDefinition], configuration: ProviderConfiguration, key: String) async throws -> ProviderTurn {
        var wireMessages: [WireMessage] = []
        if let systemPrompt, !systemPrompt.isEmpty { wireMessages.append(WireMessage(role: "system", content: systemPrompt)) }
        wireMessages.append(contentsOf: messages.map(WireMessage.init))
        let body = ChatRequest(model: configuration.model.id, messages: wireMessages, tools: tools.isEmpty ? nil : tools.map(WireTool.init))
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        for (name, value) in configuration.additionalHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await send(request)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let message = decoded.choices.first?.message else { throw ProviderRunnerError.invalidResponse }
        let calls = (message.toolCalls ?? []).map {
            ProviderToolCall(id: $0.id, name: $0.function.name, arguments: $0.function.arguments)
        }
        guard !(message.content ?? "").isEmpty || !calls.isEmpty else { throw ProviderRunnerError.invalidResponse }
        return ProviderTurn(content: message.content, toolCalls: calls)
    }

    private func completeAnthropic(messages: [ProviderConversationMessage], systemPrompt: String?, tools: [RuntimeToolDefinition], configuration: ProviderConfiguration, key: String) async throws -> ProviderTurn {
        var body: [String: JSONValue] = [
            "model": .string(configuration.model.id),
            "max_tokens": .int(4_096),
            "messages": .array(try Self.anthropicMessages(messages))
        ]
        if let systemPrompt, !systemPrompt.isEmpty { body["system"] = .string(systemPrompt) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters
                ])
            })
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if configuration.credentialType == .oauth {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (name, value) in configuration.additionalHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let data = try await send(request)
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = root,
              case .array(let blocks)? = object["content"] else {
            throw ProviderRunnerError.invalidResponse
        }
        var textParts: [String] = []
        var calls: [ProviderToolCall] = []
        for block in blocks {
            guard case .object(let value) = block, case .string(let type)? = value["type"] else { continue }
            if type == "text", case .string(let text)? = value["text"], !text.isEmpty {
                textParts.append(text)
            } else if type == "tool_use",
                      case .string(let id)? = value["id"],
                      case .string(let name)? = value["name"],
                      let input = value["input"] {
                calls.append(ProviderToolCall(id: id, name: name, arguments: try Self.jsonString(input)))
            }
        }
        let content = textParts.isEmpty ? nil : textParts.joined()
        guard content != nil || !calls.isEmpty else { throw ProviderRunnerError.invalidResponse }
        return ProviderTurn(content: content, toolCalls: calls)
    }

    private func completeGemini(messages: [ProviderConversationMessage], systemPrompt: String?, tools: [RuntimeToolDefinition], configuration: ProviderConfiguration, key: String) async throws -> ProviderTurn {
        let toolNames = Self.toolNamesByID(messages)
        var body: [String: JSONValue] = [
            "contents": .array(try messages.map { try Self.geminiMessage($0, toolNames: toolNames) })
        ]
        if let systemPrompt, !systemPrompt.isEmpty {
            body["systemInstruction"] = .object(["parts": .array([.object(["text": .string(systemPrompt)])])])
        }
        if !tools.isEmpty {
            body["tools"] = .array([.object([
                "functionDeclarations": .array(tools.map { tool in
                    .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": Self.geminiSchema(tool.parameters)
                    ])
                })
            ])])
            body["toolConfig"] = .object([
                "functionCallingConfig": .object(["mode": .string("AUTO")])
            ])
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if configuration.credentialType == .oauth {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        for (name, value) in configuration.additionalHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let data = try await send(request)
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = root,
              case .array(let candidates)? = object["candidates"],
              case .object(let candidate)? = candidates.first,
              case .object(let responseContent)? = candidate["content"],
              case .array(let parts)? = responseContent["parts"] else {
            throw ProviderRunnerError.invalidResponse
        }
        var textParts: [String] = []
        var calls: [ProviderToolCall] = []
        for (index, part) in parts.enumerated() {
            guard case .object(let value) = part else { continue }
            if case .string(let text)? = value["text"], !text.isEmpty {
                textParts.append(text)
            }
            if case .object(let function)? = value["functionCall"],
               case .string(let name)? = function["name"] {
                let arguments = function["args"] ?? .object([:])
                let id: String
                if case .string(let providedID)? = function["id"], !providedID.isEmpty {
                    id = providedID
                } else {
                    id = "gemini-\(index)-\(UUID().uuidString)"
                }
                calls.append(ProviderToolCall(id: id, name: name, arguments: try Self.jsonString(arguments)))
            }
        }
        let content = textParts.isEmpty ? nil : textParts.joined()
        guard content != nil || !calls.isEmpty else { throw ProviderRunnerError.invalidResponse }
        return ProviderTurn(content: content, toolCalls: calls)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderRunnerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderRunnerError.http(http.statusCode, String(decoding: data.prefix(2_048), as: UTF8.self))
        }
        return data
    }

    private static func anthropicMessage(_ message: ProviderConversationMessage) throws -> JSONValue {
        if message.role == "tool" {
            guard let id = message.toolCallID else { throw ProviderRunnerError.invalidResponse }
            return .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(id),
                    "content": .string(message.content ?? "")
                ])])
            ])
        }

        var blocks: [JSONValue] = []
        if let content = message.content, !content.isEmpty {
            blocks.append(.object(["type": .string("text"), "text": .string(content)]))
        }
        for call in message.toolCalls ?? [] {
            blocks.append(.object([
                "type": .string("tool_use"),
                "id": .string(call.id),
                "name": .string(call.name),
                "input": try jsonArguments(call.arguments)
            ]))
        }
        if blocks.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string("(empty)")])) }
        return .object([
            "role": .string(message.role == "assistant" ? "assistant" : "user"),
            "content": .array(blocks)
        ])
    }

    /// Anthropic treats consecutive messages with the same role as one turn.
    /// Explicitly merge them so parallel tool results are sent as multiple
    /// `tool_result` blocks in the single user turn immediately following the
    /// assistant's tool uses.
    private static func anthropicMessages(_ messages: [ProviderConversationMessage]) throws -> [JSONValue] {
        var result: [JSONValue] = []
        for message in messages {
            let encoded = try anthropicMessage(message)
            guard case .object(let object) = encoded,
                  case .string(let role)? = object["role"],
                  case .array(let blocks)? = object["content"] else {
                throw ProviderRunnerError.invalidResponse
            }
            if let lastIndex = result.indices.last,
               case .object(var previous) = result[lastIndex],
               case .string(let previousRole)? = previous["role"], previousRole == role,
               case .array(let previousBlocks)? = previous["content"] {
                previous["content"] = .array(previousBlocks + blocks)
                result[lastIndex] = .object(previous)
            } else {
                result.append(encoded)
            }
        }
        return result
    }

    private static func geminiMessage(_ message: ProviderConversationMessage, toolNames: [String: String]) throws -> JSONValue {
        var parts: [JSONValue] = []
        if message.role == "tool" {
            guard let id = message.toolCallID, let name = toolNames[id] else { throw ProviderRunnerError.invalidResponse }
            let resultValue: JSONValue
            if let content = message.content,
               let data = content.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
               case .object = parsed {
                resultValue = parsed
            } else {
                resultValue = .object(["result": .string(message.content ?? "")])
            }
            parts.append(.object([
                "functionResponse": .object([
                    "name": .string(name),
                    "response": resultValue
                ])
            ]))
        } else {
            if let content = message.content, !content.isEmpty {
                parts.append(.object(["text": .string(content)]))
            }
            for call in message.toolCalls ?? [] {
                parts.append(.object([
                    "functionCall": .object([
                        "name": .string(call.name),
                        "args": try jsonArguments(call.arguments)
                    ])
                ]))
            }
        }
        if parts.isEmpty { parts.append(.object(["text": .string("(empty)")])) }
        return .object([
            "role": .string(message.role == "assistant" ? "model" : "user"),
            "parts": .array(parts)
        ])
    }

    private static func toolNamesByID(_ messages: [ProviderConversationMessage]) -> [String: String] {
        var result: [String: String] = [:]
        for message in messages {
            for call in message.toolCalls ?? [] { result[call.id] = call.name }
        }
        return result
    }

    /// Gemini's REST Schema uses upper-case enum spellings, while the shared
    /// runtime tool catalog intentionally stores portable JSON Schema values.
    private static func geminiSchema(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var normalized = object.mapValues(geminiSchema)
            if case .string(let type)? = object["type"] {
                normalized["type"] = .string(type.uppercased())
            }
            return .object(normalized)
        case .array(let values):
            return .array(values.map(geminiSchema))
        default:
            return value
        }
    }

    private static func jsonArguments(_ value: String) throws -> JSONValue {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ProviderRunnerError.invalidResponse
        }
        return decoded
    }

    private static func jsonString(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let tools: [WireTool]?
    let stream = false
}

private struct WireMessage: Codable {
    struct ToolCall: Codable {
        struct Function: Codable { let name: String; let arguments: String }
        let id: String
        let type: String
        let function: Function
    }

    let role: String
    let content: String?
    let toolCallID: String?
    let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    init(role: String, content: String?, toolCallID: String? = nil, toolCalls: [ToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    init(_ value: ProviderConversationMessage) {
        role = value.role
        content = value.content
        toolCallID = value.toolCallID
        toolCalls = value.toolCalls?.map {
            ToolCall(id: $0.id, type: "function", function: .init(name: $0.name, arguments: $0.arguments))
        }
    }
}

private struct WireTool: Encodable {
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
    }
    let type = "function"
    let function: Function

    init(_ value: RuntimeToolDefinition) {
        function = Function(name: value.name, description: value.description, parameters: value.parameters)
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let toolCalls: [WireMessage.ToolCall]?
            enum CodingKeys: String, CodingKey { case content; case toolCalls = "tool_calls" }
        }
        let message: Message
    }
    let choices: [Choice]
}
