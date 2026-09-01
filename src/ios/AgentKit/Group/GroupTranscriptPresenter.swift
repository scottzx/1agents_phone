import Foundation

struct GroupA2ADeliveryDestination: Codable, Equatable {
    let agentId: String
    let name: String
    let sessionId: String?
}

/// Persisted inside the synthetic group transcript tool call. Keeping the
/// destinations in the tool input means the card still navigates after an app
/// restart and gives debugging a direct path into each hidden member session.
struct GroupA2ADeliveryPayload: Codable, Equatable {
    let toolTitle: String
    let isGroup: Bool
    let groupId: String
    let agentIds: [String]
    let message: String
    let deliveryMode: String
    let destinations: [GroupA2ADeliveryDestination]

    private enum CodingKeys: String, CodingKey {
        case toolTitle = "tool_title"
        case isGroup = "is_group"
        case groupId = "group_id"
        case agentIds = "agent_id"
        case message
        case deliveryMode = "delivery_mode"
        case destinations = "delivery_destinations"
    }

    func jsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> Self? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Presentation-only projection for a group transcript. The orchestrator owns
/// ordering and persistence; platform UI adapters decide how a visible session
/// reflects the appended line and busy state.
@MainActor
protocol GroupTranscriptPresenting: AnyObject {
    func append(sessionId: String, senderAgentId: String?, text: String, isUser: Bool)
    func setBusy(sessionId: String, _ busy: Bool)
}

@MainActor
final class IOSGroupTranscriptPresenter: GroupTranscriptPresenting {
    static let shared = IOSGroupTranscriptPresenter()

    private init() {}

    func append(sessionId: String, senderAgentId: String?, text: String, isUser: Bool) {
        if let vm = ViewModelCache.shared.get(for: sessionId) {
            let message = ChatMessage(role: isUser ? .user : .assistant, content: isUser ? text : "")
            message.senderAgentId = senderAgentId
            if !isUser { message.blocks = [AssistantBlock(kind: .text, content: text)] }
            vm.messages.append(message)
        }
    }

    /// Add a user-visible delivery receipt to the shared room. The actual
    /// model tool block lives in the sender's hidden member session; this
    /// projection is the room-level audit trail the user can inspect.
    func appendA2ADelivery(
        groupSessionId: String,
        senderAgentId: String,
        groupId: String,
        recipients: [GroupA2ADeliveryDestination],
        message: String,
        requestedAgentIds: [String],
        deliveryMode: String = "tool"
    ) async {
        let names = recipients.map(\.name).joined(separator: "、")
        let title = names.isEmpty ? "发送群聊消息" : "发送给 \(names)"
        let payload = GroupA2ADeliveryPayload(
            toolTitle: title,
            isGroup: true,
            groupId: groupId,
            agentIds: requestedAgentIds,
            message: message,
            deliveryMode: deliveryMode,
            destinations: recipients
        )
        guard let input = payload.jsonString() else { return }

        let toolUseId = "group-a2a-\(UUID().uuidString)"
        let output: String
        if names.isEmpty {
            output = "群聊消息已接受，等待路由。"
        } else if deliveryMode == "mention_fallback" {
            output = "检测到普通 @ 文本，已按兼容路由投递给 \(names)。点击卡片可查看对应成员会话。"
        } else {
            output = "已投递给 \(names)。点击卡片可查看对应成员会话。"
        }
        var raw = RawMessage(
            id: UUID().uuidString,
            sessionId: groupSessionId,
            role: .assistant,
            parts: [
                .toolUse(ToolUse(
                    toolUseId: toolUseId,
                    name: "send_agent_message",
                    input: input,
                    description: title
                )),
                .toolResult(ToolResult(
                    toolUseId: toolUseId,
                    output: output,
                    success: true,
                    status: "success"
                )),
            ],
            createdAt: Date()
        )
        raw.senderAgentId = senderAgentId
        await ChatStore.shared.appendMessage(raw)

        guard let vm = ViewModelCache.shared.get(for: groupSessionId) else { return }
        let block = AssistantBlock(
            kind: .subagentTool(action: "send_agent_message", taskTitle: title),
            content: output,
            toolStatus: .success,
            toolUseId: toolUseId
        )
        block.toolSummary = title
        block.toolInputArgs = input
        let visible = ChatMessage(role: .assistant, content: "")
        visible.senderAgentId = senderAgentId
        visible.blocks = [block]
        vm.messages.append(visible)
    }

    func setBusy(sessionId: String, _ busy: Bool) {
        ViewModelCache.shared.get(for: sessionId)?.isProcessing = busy
    }
}
