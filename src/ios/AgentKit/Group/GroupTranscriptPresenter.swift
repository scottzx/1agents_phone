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

    /// A structured tool call is projected before its readable public line.
    /// Remember that line briefly so `append` does not also create a legacy
    /// mention-fallback receipt for the same delivery.
    private var structuredA2AMessages: [String: Int] = [:]

    private init() {}

    func append(sessionId: String, senderAgentId: String?, text: String, isUser: Bool) {
        if let vm = ViewModelCache.shared.get(for: sessionId) {
            let message = ChatMessage(role: isUser ? .user : .assistant, content: isUser ? text : "")
            message.senderAgentId = senderAgentId
            if !isUser { message.blocks = [AssistantBlock(kind: .text, content: text)] }
            vm.messages.append(message)
        }

        guard !isUser, let senderAgentId else { return }
        let key = a2aKey(sessionId: sessionId, senderAgentId: senderAgentId, message: text)
        if let count = structuredA2AMessages[key], count > 0 {
            structuredA2AMessages[key] = count == 1 ? nil : count - 1
            return
        }

        // Compatibility path for models which ignore the tool requirement and
        // emit plain @name text. The router already honors that text; surface
        // the same delivery as a debuggable card instead of making it look as
        // though nothing happened.
        Task { await appendMentionFallbackIfNeeded(
            groupSessionId: sessionId,
            senderAgentId: senderAgentId,
            message: text
        ) }
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
        deliveryMode: String = "tool",
        projectedMessage: String? = nil
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
        if let projectedMessage {
            let key = a2aKey(
                sessionId: groupSessionId,
                senderAgentId: senderAgentId,
                message: projectedMessage
            )
            structuredA2AMessages[key, default: 0] += 1
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

    private func appendMentionFallbackIfNeeded(
        groupSessionId: String,
        senderAgentId: String,
        message: String
    ) async {
        guard let group = await GroupStore.shared.groupForSession(groupSessionId) else { return }
        let members = await GroupStore.shared.members(of: group)
        let scan = GroupMentionRouter.parseMentions(in: message, members: members)
        let targetIds: [String]
        let requestedIds: [String]
        if scan.isEveryone, senderAgentId == group.ownerAgentId {
            targetIds = members.map(\.id).filter { $0 != senderAgentId }
            requestedIds = [GroupMentionRouter.everyoneId]
        } else {
            targetIds = scan.memberIds.filter { $0 != senderAgentId }
            requestedIds = targetIds
        }
        guard !targetIds.isEmpty else { return }

        let targetSet = Set(targetIds)
        var destinations: [GroupA2ADeliveryDestination] = []
        for recipient in members where targetSet.contains(recipient.id) {
            let sessionId = await GroupStore.shared.openMemberSession(group: group, agentId: recipient.id)
            destinations.append(GroupA2ADeliveryDestination(
                agentId: recipient.id,
                name: recipient.name,
                sessionId: sessionId
            ))
        }
        await appendA2ADelivery(
            groupSessionId: groupSessionId,
            senderAgentId: senderAgentId,
            groupId: group.id,
            recipients: destinations,
            message: message,
            requestedAgentIds: requestedIds,
            deliveryMode: "mention_fallback"
        )
    }

    private func a2aKey(sessionId: String, senderAgentId: String, message: String) -> String {
        "\(sessionId)|\(senderAgentId)|\(message)"
    }

    func setBusy(sessionId: String, _ busy: Bool) {
        ViewModelCache.shared.get(for: sessionId)?.isProcessing = busy
    }
}
