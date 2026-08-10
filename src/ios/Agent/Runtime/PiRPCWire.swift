//
//  PiRPCWire.swift
//  Minis
//
//  Wire types for the `pi` agent runtime RPC protocol (`pi --mode rpc`).
//
//  This file is deliberately free of any app/iSH dependencies so it can be
//  compiled into both the app and the unit-test target. The transport that
//  owns the guest process lives in PiRuntimeBridge.swift.
//
//  Wire protocol (both directions, newline-delimited JSON on stdio):
//    → request   {"type": "<command>", "id": "<correlation-id>", ...args}
//    ← response  {"type": "response", "command": <cmd>, "success": true,
//                 "id"?: ..., "data"?: ...}
//    ← response  {"type": "response", "command": <cmd>, "success": false,
//                 "error": <msg>, "errorHints"?: [...]}
//    ← event     {"type": "<agent_event_snake_case>", ...}  (AgentEvent)
//
//  Commands: prompt / abort / get_state / get_messages / get_session_stats /
//  set_model / cycle_model / set_steering_mode / set_follow_up_mode /
//  set_auto_compaction / set_auto_retry / abort_retry / set_session_name.
//

import Foundation

// MARK: - Errors

/// Errors surfaced by the bridge itself (not by the pi process).
enum PiBridgeError: LocalizedError {
    case notRunning
    case launchFailed(String)
    case timedOut(command: String)
    case processExited(command: String, exitCode: Int)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "pi runtime is not running."
        case .launchFailed(let reason):
            return "Failed to launch pi runtime: \(reason)"
        case .timedOut(let command):
            return "Timed out waiting for pi response to \(command)."
        case .processExited(let command, let exitCode):
            return "pi exited (code \(exitCode)) while awaiting \(command)."
        case .malformedResponse(let detail):
            return "Malformed pi response: \(detail)"
        }
    }
}

/// A failed RPC command (pi responded `success: false`).
struct PiRPCCommandError: LocalizedError {
    let command: String
    let message: String
    let hints: [String]?

    init(response: PiRPCResponse) {
        self.command = response.command
        self.message = response.error ?? "Unknown error"
        self.hints = response.errorHints
    }

    var errorDescription: String? {
        message
    }
}

// MARK: - Responses

/// A decoded `{"type": "response", ...}` line from pi.
/// (Not `Equatable`: `data` is `[String: Any]?`, which cannot be synthesized.)
struct PiRPCResponse {
    let command: String
    let success: Bool
    let id: String?
    let data: [String: Any]?
    let error: String?
    let errorHints: [String]?
}

// MARK: - Agent events

/// The typed view of an AgentEvent stdout line that the mirror layer consumes.
///
/// The `raw` payload is kept so the mirror can extract nested data (messages,
/// tool args, usage) without every field being modeled as a Swift type.
enum PiAgentEvent {
    /// Sent once when the agent starts a new session/run.
    case agentStart(sessionId: String)
    /// Sent when the agent run finishes; `messages` is the full transcript,
    /// `error` is present when the run failed.
    case agentEnd(sessionId: String, messages: [[String: Any]]?, error: String?)
    case turnStart(sessionId: String, turnIndex: Int)
    case turnEnd(sessionId: String, turnIndex: Int)
    /// A message (user or assistant) was created or replaced. For assistant
    /// messages, `assistantMessageEvent` carries the delta sub-events.
    case messageStart(message: [String: Any])
    case messageUpdate(message: [String: Any], assistantMessageEvent: PiAssistantMessageEvent)
    case messageEnd(message: [String: Any])
    case toolExecutionStart(toolCallId: String, toolName: String, args: [String: Any])
    case toolExecutionUpdate(toolCallId: String, toolName: String, partialResult: String)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: String, isError: Bool)
    case autoCompactionStart(reason: String)
    case autoCompactionEnd(aborted: Bool, willRetry: Bool, errorMessage: String?)
    case autoRetryStart(attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
    case autoRetryEnd(success: Bool, attempt: Int, finalError: String?)
    case extensionError(extensionId: String?, event: String, error: String)
    /// Any event type pi emits that this build does not model yet. Kept so the
    /// mirror can still log/skip unknown types instead of dropping them.
    case unknown(type: String, payload: [String: Any])

    var typeName: String {
        switch self {
        case .agentStart: return "agent_start"
        case .agentEnd: return "agent_end"
        case .turnStart: return "turn_start"
        case .turnEnd: return "turn_end"
        case .messageStart: return "message_start"
        case .messageUpdate: return "message_update"
        case .messageEnd: return "message_end"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionUpdate: return "tool_execution_update"
        case .toolExecutionEnd: return "tool_execution_end"
        case .autoCompactionStart: return "auto_compaction_start"
        case .autoCompactionEnd: return "auto_compaction_end"
        case .autoRetryStart: return "auto_retry_start"
        case .autoRetryEnd: return "auto_retry_end"
        case .extensionError: return "extension_error"
        case .unknown(let type, _): return type
        }
    }
}

/// Sub-events of an assistant message stream (`assistantMessageEvent` inside
/// `message_update`). `type` is the `#[serde(tag = "type")]` discriminator;
/// `partial` is a full snapshot of the message so far.
struct PiAssistantMessageEvent {
    enum Kind: String, Equatable {
        case start
        case textStart = "text_start"
        case textDelta = "text_delta"
        case textEnd = "text_end"
        case thinkingStart = "thinking_start"
        case thinkingDelta = "thinking_delta"
        case thinkingEnd = "thinking_end"
        case toolCallStart = "toolcall_start"
        case toolCallDelta = "toolcall_delta"
        case toolCallEnd = "toolcall_end"
        case done
        case error
    }

    let kind: Kind
    let partial: [String: Any]?
    let contentIndex: Int?
    let delta: String?
    let content: String?
    let toolCall: [String: Any]?
    let reason: String?
    let message: String?
}

// MARK: - Request building

/// Builds request payloads for the pi RPC protocol.
enum PiRPCRequestFactory {
    /// `{"type":"prompt","message":...,"images"?:...,"streamingBehavior"?:...}`
    static func prompt(message: String,
                       images: [PiRPCImagePayload] = [],
                       streamingBehavior: PiStreamingBehavior? = nil,
                       id: String) -> [String: Any] {
        var request: [String: Any] = ["type": "prompt", "id": id, "message": message]
        if !images.isEmpty {
            request["images"] = images.map { $0.asDictionary }
        }
        if let streamingBehavior {
            request["streamingBehavior"] = streamingBehavior.rawValue
        }
        return request
    }

    static func simple(_ command: String, id: String) -> [String: Any] {
        ["type": command, "id": id]
    }

    static func setModel(provider: String, modelId: String, id: String) -> [String: Any] {
        ["type": "set_model", "id": id, "provider": provider, "modelId": modelId]
    }

    static func setQueueMode(_ command: String, mode: PiQueueMode, id: String) -> [String: Any] {
        ["type": command, "id": id, "mode": mode.rawValue]
    }

    static func setAuto(_ command: String, enabled: Bool, id: String) -> [String: Any] {
        ["type": command, "id": id, "enabled": enabled]
    }
}

/// Base64 image attachment for `prompt` requests.
/// Wire shape (matches pi `ImageContent`):
///   {"type":"image","source":{"type":"base64","media_type":<mime>,"data":<b64>}}
struct PiRPCImagePayload {
    let mediaType: String
    let base64Data: String

    var asDictionary: [String: Any] {
        [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mediaType,
                "data": base64Data,
            ],
        ]
    }
}

/// `streamingBehavior` values for prompt while the agent is busy.
enum PiStreamingBehavior: String {
    case steer = "steer"
    case followUp = "followUp"
}

/// Queue modes for `set_steering_mode` / `set_follow_up_mode`.
enum PiQueueMode: String {
    case all = "all"
    case oneAtATime = "one-at-a-time"
}

// MARK: - Line parsing

/// Decodes stdout lines into responses/events.
enum PiRPCLineParser {
    /// True for lines that are not part of the protocol (empty lines, stray
    /// warnings) and can be skipped.
    static func isIgnorable(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
    }

    static func decodeResponse(_ line: String) -> PiRPCResponse? {
        guard let object = parseJSONObject(line),
              let type = object["type"] as? String, type == "response" else {
            return nil
        }
        guard let command = object["command"] as? String else {
            return nil
        }
        let success = (object["success"] as? Bool) ?? false
        return PiRPCResponse(
            command: command,
            success: success,
            id: object["id"] as? String,
            data: object["data"] as? [String: Any],
            error: object["error"] as? String,
            errorHints: object["errorHints"] as? [String]
        )
    }

    static func decodeEvent(_ line: String) -> PiAgentEvent? {
        guard let object = parseJSONObject(line),
              let type = object["type"] as? String else {
            return nil
        }
        return PiEventDecoder.decode(type: type, payload: object)
    }

    private static func parseJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

/// Maps raw AgentEvent JSON onto the typed `PiAgentEvent` enum.
enum PiEventDecoder {
    static func decode(type: String, payload: [String: Any]) -> PiAgentEvent {
        switch type {
        case "agent_start":
            return .agentStart(sessionId: payload["sessionId"] as? String ?? "")
        case "agent_end":
            let error = payload["error"] as? String
            let messages = payload["messages"] as? [[String: Any]]
            return .agentEnd(sessionId: payload["sessionId"] as? String ?? "",
                             messages: messages,
                             error: error)
        case "turn_start":
            return .turnStart(sessionId: payload["sessionId"] as? String ?? "",
                              turnIndex: payload["turnIndex"] as? Int ?? 0)
        case "turn_end":
            return .turnEnd(sessionId: payload["sessionId"] as? String ?? "",
                            turnIndex: payload["turnIndex"] as? Int ?? 0)
        case "message_start":
            return .messageStart(message: payload["message"] as? [String: Any] ?? [:])
        case "message_update":
            let message = payload["message"] as? [String: Any] ?? [:]
            let subEvent = PiAssistantMessageEventDecoder.decode(
                payload["assistantMessageEvent"] as? [String: Any]
            )
            return .messageUpdate(message: message, assistantMessageEvent: subEvent)
        case "message_end":
            return .messageEnd(message: payload["message"] as? [String: Any] ?? [:])
        case "tool_execution_start":
            return .toolExecutionStart(
                toolCallId: payload["toolCallId"] as? String ?? "",
                toolName: payload["toolName"] as? String ?? "",
                args: payload["args"] as? [String: Any] ?? [:]
            )
        case "tool_execution_update":
            return .toolExecutionUpdate(
                toolCallId: payload["toolCallId"] as? String ?? "",
                toolName: payload["toolName"] as? String ?? "",
                partialResult: payload["partialResult"] as? String ?? ""
            )
        case "tool_execution_end":
            return .toolExecutionEnd(
                toolCallId: payload["toolCallId"] as? String ?? "",
                toolName: payload["toolName"] as? String ?? "",
                result: payload["result"] as? String ?? "",
                isError: payload["isError"] as? Bool ?? false
            )
        case "auto_compaction_start":
            return .autoCompactionStart(reason: payload["reason"] as? String ?? "")
        case "auto_compaction_end":
            return .autoCompactionEnd(
                aborted: payload["aborted"] as? Bool ?? false,
                willRetry: payload["willRetry"] as? Bool ?? false,
                errorMessage: payload["errorMessage"] as? String
            )
        case "auto_retry_start":
            return .autoRetryStart(
                attempt: payload["attempt"] as? Int ?? 0,
                maxAttempts: payload["maxAttempts"] as? Int ?? 0,
                delayMs: payload["delayMs"] as? Int ?? 0,
                errorMessage: payload["errorMessage"] as? String ?? ""
            )
        case "auto_retry_end":
            return .autoRetryEnd(
                success: payload["success"] as? Bool ?? false,
                attempt: payload["attempt"] as? Int ?? 0,
                finalError: payload["finalError"] as? String
            )
        case "extension_error":
            return .extensionError(
                extensionId: payload["extensionId"] as? String,
                event: payload["event"] as? String ?? "",
                error: payload["error"] as? String ?? ""
            )
        default:
            return .unknown(type: type, payload: payload)
        }
    }
}

/// Maps the `assistantMessageEvent` sub-object of `message_update`.
enum PiAssistantMessageEventDecoder {
    static func decode(_ object: [String: Any]?) -> PiAssistantMessageEvent {
        guard let object else {
            return PiAssistantMessageEvent(kind: .error, partial: nil, contentIndex: nil,
                                           delta: nil, content: nil, toolCall: nil,
                                           reason: nil, message: "missing assistantMessageEvent")
        }
        let type = object["type"] as? String ?? ""
        let kind = PiAssistantMessageEvent.Kind(rawValue: type) ?? .error
        return PiAssistantMessageEvent(
            kind: kind,
            partial: object["partial"] as? [String: Any],
            contentIndex: object["contentIndex"] as? Int,
            delta: object["delta"] as? String,
            content: object["content"] as? String,
            toolCall: object["toolCall"] as? [String: Any],
            reason: object["reason"] as? String,
            message: object["message"] as? String
        )
    }
}
