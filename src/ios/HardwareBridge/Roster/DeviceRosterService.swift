import Combine
import Foundation

/// Builds the identity payload the hardware needs, and nothing else.
///
/// Deliberately knows nothing about BLE. HardwareBridgeCoordinator asks it for
/// a snapshot and hands the result to a transport; the DEBUG JSON-RPC server
/// can serve the same snapshot with no device attached, which is how the roster
/// path is exercised before the board implements `on_agent_list`.
///
/// Every snapshot carries two things:
///
///  - a **catalog** (`conversations`): every group and every one-to-one agent,
///    so the board can draw its chat list the moment the link comes up. This is
///    why the service no longer needs a bound conversation to produce anything
///    — a device that has just connected has no session yet, and a blank screen
///    until the user speaks was the old behavior, not a design.
///  - a **bound conversation** (`conversation`): the one `chat0` and `state0`
///    are scoped to. It follows whatever the user (or the device) selected.
///
/// There is no "main user" record here on purpose: the phone *is* the user side
/// of the conversation, so the device only ever needs the agents' identities.
/// `DeviceParticipantKind.user` stays in the wire vocabulary for a future group
/// that wants to mark the holder's own row, but nothing emits it today.
@MainActor
final class DeviceRosterService: ObservableObject {
    static let shared = DeviceRosterService()

    /// The roster as last computed. `nil` only before anything exists to list.
    @Published private(set) var snapshot: DeviceRosterSnapshot?

    /// The board reassembles a 0x37 roster into a buffer capped at 8 KiB
    /// (`kMaxRosterBytes` in agent_link.cpp) and rejects the whole transfer on
    /// overflow. A trimmed catalog beats a refused one, so the tail is dropped
    /// to fit with room to spare for framing.
    static let maxSnapshotBytes = 7 * 1024

    /// Monotonic across the process. Not persisted: a relaunch starting from
    /// rev 1 again is fine because the device treats any *different* rev as
    /// "redraw", and a fresh launch always pushes before the device can act.
    private var rev: UInt32 = 0

    private var boundConversationId: String?
    private var boundTitle: String?
    private var boundAgentIds: [String] = []
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // An agent renamed or recolored, or a group created or edited, must
        // reach a connected device without waiting for the next turn.
        AgentStore.shared.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        GroupStore.shared.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
    }

    /// Binds the roster to a conversation and the agents taking part.
    ///
    /// Passing several ids is what a roundtable does; passing one is a
    /// one-to-one session. Only the *bound* half of the snapshot changes — the
    /// catalog is rebuilt from the stores either way. Returns the snapshot when
    /// it actually changed, `nil` when it is byte-identical to what the device
    /// already has.
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

    /// Drops the binding when a link ends, so the next connection rebuilds
    /// rather than pushing a snapshot for a session that no longer exists.
    func unbind() {
        boundConversationId = nil
        boundTitle = nil
        boundAgentIds = []
        snapshot = nil
    }

    /// Recomputes catalog and binding, bumping `rev` only on a real change.
    @discardableResult
    func rebuild(title: String? = nil) -> DeviceRosterSnapshot? {
        if let title { boundTitle = title }

        var (entries, members) = buildCatalog()
        let conversation = boundConversation(entries: entries, members: &members)

        // Nothing to say yet — no agents, no groups, no binding. Pushing an
        // empty roster would only make the device clear a list it may already
        // have drawn from a previous, better snapshot.
        guard !entries.isEmpty || !members.isEmpty else { return nil }

        (entries, members) = trimToBudget(entries: entries, members: members, conversation: conversation)

        // Compare on content, ignoring rev, so a rebuild triggered by an
        // unrelated AgentStore write doesn't burn a rev and force a redraw.
        if let current = snapshot,
           current.conversation == conversation,
           current.members == members,
           current.conversations == entries {
            return nil
        }

        rev &+= 1
        let next = DeviceRosterSnapshot(
            rev: rev,
            conversation: conversation,
            members: members,
            conversations: entries
        )
        snapshot = next
        return next
    }

    /// Resolves the participant a reply should be attributed to. Falls back to
    /// the bound conversation's first member so a reply is never dropped for
    /// want of a sender.
    func sender(preferring agentId: String?) -> DeviceParticipant? {
        if let agentId, let match = snapshot?.member(agentId) { return match }
        guard let snapshot else { return nil }
        if let bound = snapshot.entry(snapshot.conversation.id),
           let first = bound.memberIds.lazy.compactMap({ snapshot.member($0) }).first {
            return first
        }
        return snapshot.members.first
    }

    // MARK: - Catalog

    /// Every group, then every agent's one-to-one chat.
    ///
    /// Groups lead because the round screen shows two rows at a time and the
    /// roundtable is the thing it was built for; a user with a dozen agents
    /// would otherwise have to swipe past all of them to reach a room.
    private func buildCatalog() -> ([DeviceConversationEntry], [DeviceParticipant]) {
        var entries: [DeviceConversationEntry] = []
        var members: [DeviceParticipant] = []
        var seen = Set<String>()

        func include(_ agentId: String) -> Bool {
            guard let profile = AgentStore.shared.agent(agentId) else { return false }
            if seen.insert(profile.id).inserted {
                members.append(
                    DeviceParticipant(
                        id: profile.id,
                        kind: .agent,
                        name: profile.name,
                        emoji: profile.emoji,
                        accentColor: profile.accentColor,
                        title: profile.title
                    )
                )
            }
            return true
        }

        for group in GroupStore.shared.groups {
            // `memberIds` goes down unfiltered even when a member no longer
            // resolves: its indices are the slots `speaking(slot:isOwner:)`
            // lights up, so compacting it here would light the wrong node. The
            // device skips ids it cannot resolve and keeps the position.
            let resolvable = group.memberIds.filter { include($0) }
            guard !resolvable.isEmpty else { continue }
            entries.append(
                DeviceConversationEntry(
                    id: group.id,
                    kind: .group,
                    title: group.title,
                    emoji: group.emoji,
                    accentColor: group.accentColor,
                    ownerId: group.ownerAgentId,
                    memberIds: group.memberIds
                )
            )
        }

        for agent in AgentStore.shared.agents {
            _ = include(agent.id)
            entries.append(
                DeviceConversationEntry(
                    id: agent.id,
                    kind: .direct,
                    title: agent.name,
                    emoji: agent.emoji,
                    accentColor: agent.accentColor,
                    ownerId: nil,
                    memberIds: [agent.id]
                )
            )
        }

        return (entries, members)
    }

    /// The conversation `chat0` and `state0` belong to.
    ///
    /// A bound session wins. With nothing bound — the state a device is in the
    /// instant it connects — the first catalog entry stands in, so the payload
    /// is well-formed and firmware that only reads `conv` still gets something
    /// sane. `members` gains any agent the binding names that the catalog did
    /// not already carry.
    private func boundConversation(
        entries: [DeviceConversationEntry],
        members: inout [DeviceParticipant]
    ) -> DeviceConversation {
        if let conversationId = boundConversationId {
            for agentId in boundAgentIds where !members.contains(where: { $0.id == agentId }) {
                guard let profile = AgentStore.shared.agent(agentId) else { continue }
                members.append(
                    DeviceParticipant(
                        id: profile.id,
                        kind: .agent,
                        name: profile.name,
                        emoji: profile.emoji,
                        accentColor: profile.accentColor,
                        title: profile.title
                    )
                )
            }
            return DeviceConversation(
                id: conversationId,
                // The roundtable is a group the moment it has more than one
                // speaker; nothing else in the app has to change for that.
                kind: boundAgentIds.count > 1 ? .group : .direct,
                title: boundTitle ?? boundAgentIds.first.flatMap { AgentStore.shared.agent($0)?.name } ?? ""
            )
        }

        guard let first = entries.first else {
            return DeviceConversation(id: "", kind: .direct, title: "")
        }
        return DeviceConversation(id: first.id, kind: first.kind, title: first.title)
    }

    /// Drops catalog entries from the tail until the encoded snapshot fits the
    /// board's reassembly buffer. The bound conversation is never dropped.
    private func trimToBudget(
        entries: [DeviceConversationEntry],
        members: [DeviceParticipant],
        conversation: DeviceConversation
    ) -> ([DeviceConversationEntry], [DeviceParticipant]) {
        var entries = entries
        while entries.count > 1 {
            let kept = prune(members: members, to: entries, keeping: conversation)
            let candidate = DeviceRosterSnapshot(
                rev: rev,
                conversation: conversation,
                members: kept,
                conversations: entries
            )
            guard let encoded = try? DeviceRosterJSON.encode(candidate),
                  encoded.count > Self.maxSnapshotBytes else {
                return (entries, kept)
            }
            // Drop the last entry that isn't the bound one.
            guard let index = entries.lastIndex(where: { $0.id != conversation.id }) else { break }
            entries.remove(at: index)
        }
        return (entries, prune(members: members, to: entries, keeping: conversation))
    }

    /// Keeps only members some surviving entry (or the binding) still names.
    private func prune(
        members: [DeviceParticipant],
        to entries: [DeviceConversationEntry],
        keeping conversation: DeviceConversation
    ) -> [DeviceParticipant] {
        var referenced = Set(entries.flatMap(\.memberIds))
        referenced.formUnion(boundAgentIds)
        referenced.insert(conversation.id)
        return members.filter { referenced.contains($0.id) }
    }
}
