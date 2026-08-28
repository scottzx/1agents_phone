import Combine
import Foundation

/// Builds the identity snapshot the hardware needs, and nothing else.
///
/// Deliberately knows nothing about BLE. HardwareBridgeCoordinator asks it for
/// a snapshot and hands the result to a transport; the DEBUG JSON-RPC server
/// can serve the same snapshot with no device attached, which is how the roster
/// path is exercised before the board implements `on_agent_list`.
///
/// There is no "main user" record here on purpose: the phone *is* the user side
/// of the conversation, so the device only ever needs the agents' identities.
/// `DeviceParticipantKind.user` stays in the wire vocabulary for a future group
/// that wants to mark the holder's own row, but nothing emits it today.
@MainActor
final class DeviceRosterService: ObservableObject {
    static let shared = DeviceRosterService()

    /// The roster as last computed. `nil` until a conversation is bound, which
    /// is what stops the bridge pushing an empty roster on a bare connect.
    @Published private(set) var snapshot: DeviceRosterSnapshot?

    /// Monotonic across the process. Not persisted: a relaunch starting from
    /// rev 1 again is fine because the device treats any *different* rev as
    /// "redraw", and a fresh launch always pushes before the device can act.
    private var rev: UInt32 = 0

    private var boundConversationId: String?
    private var boundAgentIds: [String] = []
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // An agent renamed or recolored in the roster UI must reach a connected
        // device without waiting for the next turn.
        AgentStore.shared.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
    }

    /// Binds the roster to a conversation and the agents taking part.
    ///
    /// Passing several ids is what a roundtable does; passing one is today's
    /// hardware session. Same code path, so the group case is not a rewrite.
    /// Returns the snapshot when it actually changed, `nil` when the roster is
    /// byte-identical to what the device already has.
    @discardableResult
    func bind(
        conversationId: String,
        title: String,
        agentIds: [String]
    ) -> DeviceRosterSnapshot? {
        boundConversationId = conversationId
        boundAgentIds = agentIds
        return rebuild(title: title)
    }

    /// Drops the roster when a link ends, so the next connection rebuilds
    /// rather than pushing a snapshot for a session that no longer exists.
    func unbind() {
        boundConversationId = nil
        boundAgentIds = []
        snapshot = nil
    }

    /// Recomputes from AgentStore, bumping `rev` only on a real change.
    @discardableResult
    func rebuild(title: String? = nil) -> DeviceRosterSnapshot? {
        guard let conversationId = boundConversationId else { return nil }

        let members = boundAgentIds.compactMap { agentId -> DeviceParticipant? in
            guard let profile = AgentStore.shared.agent(agentId) else { return nil }
            return DeviceParticipant(
                id: profile.id,
                kind: .agent,
                name: profile.name,
                emoji: profile.emoji,
                accentColor: profile.accentColor,
                title: profile.title
            )
        }

        let conversation = DeviceConversation(
            id: conversationId,
            // The roundtable is a group the moment it has more than one
            // speaker; nothing else in the app has to change for that.
            kind: members.count > 1 ? .group : .direct,
            title: title ?? snapshot?.conversation.title ?? members.first?.name ?? ""
        )

        // Compare on content, ignoring rev, so a rebuild triggered by an
        // unrelated AgentStore write doesn't burn a rev and force a redraw.
        if let current = snapshot,
           current.conversation == conversation,
           current.members == members {
            return nil
        }

        rev &+= 1
        let next = DeviceRosterSnapshot(rev: rev, conversation: conversation, members: members)
        snapshot = next
        return next
    }

    /// Resolves the participant a reply should be attributed to. Falls back to
    /// the first member so a reply is never dropped for want of a sender.
    func sender(preferring agentId: String?) -> DeviceParticipant? {
        if let agentId, let match = snapshot?.member(agentId) { return match }
        return snapshot?.members.first
    }
}
