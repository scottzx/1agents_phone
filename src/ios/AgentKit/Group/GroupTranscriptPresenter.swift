import Foundation

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
        guard let vm = ViewModelCache.shared.get(for: sessionId) else { return }
        let message = ChatMessage(role: isUser ? .user : .assistant, content: isUser ? text : "")
        message.senderAgentId = senderAgentId
        if !isUser { message.blocks = [AssistantBlock(kind: .text, content: text)] }
        vm.messages.append(message)
    }

    func setBusy(sessionId: String, _ busy: Bool) {
        ViewModelCache.shared.get(for: sessionId)?.isProcessing = busy
    }
}
