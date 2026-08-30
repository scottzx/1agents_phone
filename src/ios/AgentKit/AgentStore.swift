//
//  AgentStore.swift
//  Minis
//
//  The roster: which agents exist, which one you are talking to, and the
//  on-disk tree each of them owns.
//
//  Persistence lives in ChatStore (same minis.db, same actor) — see the note
//  above its "Agent CRUD" section for why there is no second SQLite
//  connection. This type is the @MainActor facade the UI binds to, matching
//  the shape SkillStore and MCPStore already established.
//

import Foundation
import SwiftUI

@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    fileprivate let logger = AppLogger(category: "AgentStore")

    /// Non-archived agents, in roster order.
    @Published private(set) var agents: [AgentProfile] = []
    /// True once `bootstrap()` has finished. The roster UI waits on this so it
    /// never flashes an empty state before migration has run.
    @Published private(set) var isReady = false

    private init() {}

    // MARK: - Launch

    /// Idempotent launch work: create the default agent if this is the first
    /// run on this build, and make sure each agent's directory tree exists.
    /// Existing sessions are left untouched — see the note below.
    ///
    /// Safe to call on every launch — each step is a no-op once done.
    func bootstrap() async {
        var roster = await ChatStore.shared.listAgents(includeArchived: true)
        logger.info("bootstrap start — existing agents=\(roster.count)")

        if roster.first(where: { $0.id == AgentProfile.defaultAgentId }) == nil {
            // Seed the default agent from the existing global SOUL.md so an
            // upgrading user's personality carries over untouched. Its persona
            // file stays at the legacy path (see SoulStore.fileURL(for:)), which
            // is also what the iCloud SoulV2 record and Settings → Soul point at.
            let soul = SoulStore.load()
            let name = soul?.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let seeded = AgentProfile(
                id: AgentProfile.defaultAgentId,
                name: (name?.isEmpty == false ? name! : "Minis"),
                emoji: "✨",
                title: "",
                summary: String(localized: "默认会话"),
                // Migrated sessions keep the historical behavior: full toolset,
                // no dispatching. Switching this agent to orchestrator would
                // silently strip shell/browser from conversations the user has
                // been relying on.
                toolPolicy: .standalone,
                sortOrder: 0
            )
            await ChatStore.shared.upsertAgent(seeded)
            roster.append(seeded)
            logger.info("seeded default agent")
        }

        // Pre-Agent sessions are deliberately NOT rewritten. Stamping agent_id
        // across a user's whole history is a write we do not need: the default
        // agent's history view simply reads unowned rows in as well (see
        // ContentView.applyingAgentFilter). Nothing is hidden, and nothing on
        // disk changes for existing conversations.
        for agent in roster { AgentProfile.ensureDirectories(for: agent.id) }

        await refresh()
        isReady = true
        logger.info("bootstrap done — roster=\(self.agents.count) isReady=true")

        // Age out finished scratch sessions. Deliberately after `isReady` and
        // off the bootstrap path: it touches the filesystem once per expired
        // task and the roster must not wait on it. Once per launch is enough —
        // the retention window is 30 days.
        Task.detached(priority: .utility) {
            let purged = await ChatStore.shared.purgeExpiredSubagentSessions()
            if purged > 0 {
                await MainActor.run { AgentStore.shared.logger.info("swept \(purged) expired subagent session(s)") }
            }
        }
    }

    // MARK: - Roster

    func refresh() async {
        agents = await ChatStore.shared.listAgents()
    }

    func agent(_ id: String) -> AgentProfile? {
        agents.first { $0.id == id }
    }

    /// Read-through for agents that may be archived (a task card can outlive
    /// its agent's presence in the roster).
    func loadAgent(_ id: String) async -> AgentProfile? {
        if let cached = agent(id) { return cached }
        return await ChatStore.shared.getAgent(id)
    }

    @discardableResult
    func create(
        name: String,
        emoji: String,
        title: String,
        summary: String,
        accentColor: String,
        toolPolicy: AgentToolPolicy,
        personaBody: String = ""
    ) async -> AgentProfile {
        let agent = AgentProfile(
            name: name,
            emoji: emoji.isEmpty ? "🤖" : emoji,
            title: title,
            summary: summary,
            accentColor: accentColor,
            toolPolicy: toolPolicy,
            sortOrder: (agents.map(\.sortOrder).max() ?? 0) + 1
        )
        AgentProfile.ensureDirectories(for: agent.id)
        try? SoulStore.save(
            SoulFile(metadata: SoulMetadata(name: name, emoji: "", style: "", lang: "auto"),
                     body: personaBody),
            for: agent.id
        )
        await ChatStore.shared.upsertAgent(agent)
        await refresh()
        return agent
    }

    func update(_ agent: AgentProfile) async {
        var next = agent
        next.updatedAt = Date()
        await ChatStore.shared.upsertAgent(next)
        await refresh()
    }

    func archive(_ agentId: String) async {
        guard agentId != AgentProfile.defaultAgentId,
              var target = await loadAgent(agentId) else { return }
        target.archivedAt = Date()
        target.updatedAt = Date()
        await ChatStore.shared.upsertAgent(target)
        await refresh()
    }

    func reorder(_ ordered: [AgentProfile]) async {
        for (index, agent) in ordered.enumerated() where agent.sortOrder != index {
            var next = agent
            next.sortOrder = index
            next.updatedAt = Date()
            await ChatStore.shared.upsertAgent(next)
        }
        await refresh()
    }

    // MARK: - Main session

    /// Resolve (creating on first open) the agent's single long-lived session.
    ///
    /// The session is created through the normal draft path so it picks up the
    /// same model resolution, binding and memory defaults as any other session
    /// — the only difference is the `linkSession` stamp afterwards.
    func openMainSession(for agentId: String) async -> String? {
        guard var target = await loadAgent(agentId) else { return nil }

        if let existing = target.mainSessionId,
           await ChatStore.shared.getSession(existing) != nil {
            return existing
        }

        let vm = ViewModelCache.shared.createDraft()
        vm.agentId = agentId
        vm.agentRole = .main
        // Seed the policy here, not just in loadSession(): a draft VM goes
        // straight from createDraft() to send() without ever loading, so
        // without this the agent's FIRST turn would assemble the standalone
        // prompt and the full toolset — exactly the leak this whole split
        // exists to prevent.
        vm.resolvedToolPolicy = target.toolPolicy
        let sid = await vm.ensureSessionReturningId()
        await ChatStore.shared.linkSession(sid, agentId: agentId, role: "main")
        // Session-level model override, installed the same way
        // SessionsOffloadBridge.sendPrompt does it: the binding can only be
        // written once the session has an id.
        if let entryId = target.defaultModelEntryId,
           ProviderConfigStore.shared.entry(for: entryId) != nil {
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(sessionId: sid, primarySource: .directEntry(modelEntryId: entryId)),
                for: sid
            )
        }
        ViewModelCache.shared.cacheDraft(vm, sessionId: sid)

        target.mainSessionId = sid
        target.updatedAt = Date()
        await ChatStore.shared.upsertAgent(target)
        await refresh()
        return sid
    }

    /// How many of this agent's dispatched tasks are still running. Drives the
    /// roster's "N 个任务运行中" line.
    func runningTaskCount(for agentId: String) async -> Int {
        guard let target = await loadAgent(agentId), let main = target.mainSessionId else { return 0 }
        let tasks = await ChatStore.shared.subagentSessions(parentSessionId: main)
        return tasks.filter { $0.spawnStatus == "running" }.count
    }
}
