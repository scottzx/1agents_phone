//
//  GroupStore.swift
//  Minis
//
//  The group roster: which groups exist, who is in them, and where each
//  member's private thread lives.
//
//  Same shape as AgentStore — a @MainActor facade the UI binds to, with all
//  persistence delegated to ChatStore's actor. It deliberately has no runtime
//  of its own: running a group turn is GroupChatOrchestrator's job, and
//  resolving what an agent IS remains AgentStore's.
//

import Foundation
import SwiftUI

@MainActor
final class GroupStore: ObservableObject {
    static let shared = GroupStore()

    private let logger = AppLogger(category: "GroupStore")

    /// Non-archived groups, most recently active first.
    @Published private(set) var groups: [GroupProfile] = []
    @Published private(set) var isReady = false

    private init() {}

    // MARK: - Roster

    func bootstrap() async {
        await refresh()
        isReady = true
    }

    func refresh() async {
        groups = await ChatStore.shared.listGroups()
    }

    func group(_ id: String) -> GroupProfile? {
        groups.first { $0.id == id }
    }

    /// Reads through to the store, so a group created or edited elsewhere in
    /// this launch is visible without waiting for a refresh.
    func loadGroup(_ id: String) async -> GroupProfile? {
        await ChatStore.shared.getGroup(id)
    }

    func groupForSession(_ sessionId: String) async -> GroupProfile? {
        await ChatStore.shared.groupForSession(sessionId)
    }

    // MARK: - Members

    /// Resolve a group's roster into the value type the router and the prompt
    /// builder work with.
    ///
    /// Members whose agent no longer exists are skipped rather than faked: a
    /// deleted agent should disappear from the room, and every line it already
    /// spoke still renders (GroupChatPrompt.formatLine names it "已退出的成员").
    func members(of group: GroupProfile) async -> [GroupMember] {
        var resolved: [GroupMember] = []
        for (index, agentId) in group.memberIds.enumerated() {
            guard let profile = await AgentStore.shared.loadAgent(agentId), !profile.isArchived else { continue }
            resolved.append(
                GroupMember(
                    id: profile.id,
                    name: profile.name,
                    title: profile.title,
                    emoji: profile.emoji,
                    accentColor: profile.accentColor,
                    summary: profile.summary,
                    slot: index
                )
            )
        }
        return resolved
    }

    // MARK: - Create / edit

    /// Create a group and the session that holds its transcript.
    ///
    /// The session goes through the normal draft path, exactly like
    /// AgentStore.openMainSession, so it inherits the same model resolution and
    /// defaults as any other conversation — the only difference is the
    /// `linkGroupSession` stamp, which leaves `agent_id` NULL.
    @discardableResult
    func create(
        title: String,
        emoji: String = "👥",
        accentColor: String = "#5B8DEF",
        mode: GroupChatMode = .freeform,
        ownerAgentId: String? = nil,
        memberIds: [String]
    ) async -> GroupProfile? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let vm = ViewModelCache.shared.createDraft()
        vm.sessionSource = "group"
        vm.isGroupTranscript = true
        let sessionId = await vm.ensureSessionReturningId()
        guard !sessionId.isEmpty else {
            logger.error("could not create a session for group \(trimmed)")
            return nil
        }
        await ChatStore.shared.linkGroupSession(sessionId, title: trimmed)

        let group = GroupProfile(
            sessionId: sessionId,
            title: trimmed,
            emoji: emoji.isEmpty ? "👥" : emoji,
            accentColor: accentColor,
            mode: mode,
            ownerAgentId: ownerAgentId,
            memberIds: Array(memberIds.prefix(GroupProfile.maxMembers))
        )
        await ChatStore.shared.upsertGroup(group)

        vm.groupId = group.id
        // Seeded before the vm is cached: this draft never runs loadSession(),
        // and without the roster the `@` picker in a just-created room falls
        // through to the file list — no members to pick at all.
        vm.groupMembers = await members(of: group)
        ViewModelCache.shared.cacheDraft(vm, sessionId: sessionId)

        await refresh()
        logger.info("created group \(group.id.prefix(8)) members=\(group.memberIds.count) mode=\(mode.rawValue)")
        return group
    }

    /// Persist an edited group. `updatedAt` is bumped here so callers never
    /// have to remember to — the roster diffs on it.
    func save(_ group: GroupProfile) async {
        var updated = group
        updated.memberIds = Array(group.memberIds.prefix(GroupProfile.maxMembers))
        updated.updatedAt = Date()
        await ChatStore.shared.upsertGroup(updated)
        await refresh()
    }

    func archive(_ id: String) async {
        guard var target = await loadGroup(id) else { return }
        target.archivedAt = Date()
        target.updatedAt = Date()
        await ChatStore.shared.upsertGroup(target)
        await refresh()
    }

    // MARK: - Member sessions

    /// Resolve (creating on first use) one member's private thread inside one
    /// group.
    ///
    /// This is where the "each member gets its own context, but keeps its own
    /// persona and memory" decision physically lives. The session is stamped
    /// with the member's `agent_id`, so SOUL.md, the memory directory and the
    /// tool policy all resolve to that agent exactly as they do in its 1:1
    /// conversation; only the transcript is separate.
    ///
    /// These sessions are never swept — see the note on
    /// ChatStore.purgeExpiredSubagentSessions.
    func openMemberSession(group: GroupProfile, agentId: String) async -> String? {
        if let existing = await ChatStore.shared.groupMemberSessionId(
            groupSessionId: group.sessionId, agentId: agentId
        ), await ChatStore.shared.getSession(existing) != nil {
            return existing
        }
        guard let profile = await AgentStore.shared.loadAgent(agentId) else { return nil }

        let vm = ViewModelCache.shared.createDraft()
        vm.sessionSource = "group"
        vm.agentId = agentId
        vm.agentRole = .main
        // Seeded before the first send() for the same reason AgentStore does
        // it: a draft vm never runs loadSession(), so without this its first
        // turn would assemble the wrong prompt and the wrong toolset.
        vm.resolvedToolPolicy = profile.toolPolicy
        vm.groupId = group.id

        let sessionId = await vm.ensureSessionReturningId()
        guard !sessionId.isEmpty else { return nil }

        await ChatStore.shared.linkSession(
            sessionId,
            agentId: agentId,
            role: GroupSessionRole.member,
            parentSessionId: group.sessionId,
            spawnTitle: group.title
        )
        // Inherit the member's own model binding, so an agent answers in a
        // group on the model the user picked for it.
        if let entryId = profile.defaultModelEntryId,
           ProviderConfigStore.shared.entry(for: entryId) != nil {
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(sessionId: sessionId, primarySource: .directEntry(modelEntryId: entryId)),
                for: sessionId
            )
        }
        ViewModelCache.shared.cacheDraft(vm, sessionId: sessionId)
        logger.info("opened group-member session \(sessionId.prefix(8)) agent=\(agentId.prefix(8)) group=\(group.id.prefix(8))")
        return sessionId
    }
}
