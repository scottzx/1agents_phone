/// Converts a navigation route ID into the two IDs expected by `AIChatView`.
/// Draft IDs are UI-only placeholders and must never be installed as a real
/// session ID, otherwise the lazy persistence path assumes the session exists.
struct AgentSessionDestination: Equatable {
    private static let draftPrefix = "__new__"

    let sessionId: String?
    let draftId: String?

    init(routeId: String) {
        if routeId.hasPrefix(Self.draftPrefix) {
            sessionId = nil
            draftId = routeId
        } else {
            sessionId = routeId
            draftId = nil
        }
    }
}
