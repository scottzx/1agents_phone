//
//  AgentListView.swift
//  Minis
//
//  The root screen: your agents, not your sessions.
//
//  Opening an agent does not start a new conversation — it drops you back into
//  the one it has always had. That single long-lived session is what makes an
//  agent feel continuous instead of amnesiac, and it is why the heavy work is
//  pushed out to subagents (see OrchestratorPrompt).
//

import SwiftUI

/// Where the roster can navigate to.
///
/// Two cases, because the roster is now the app root and therefore inherits
/// ContentView's old job of answering deep links: `minis://` URLs, notification
/// taps, Shortcuts intents and `minis-sessions-cli` all post
/// `.openSessionFromIntent` with a bare session id that belongs to no
/// particular agent screen.
enum AgentRoute: Hashable {
    case agent(String)
    case session(String)
}

struct AgentListView: View {
    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var activity = SessionActivityTracker.shared
    /// Drives the unread dot. An agent's conversation can now gain a message
    /// the user never sent — another agent's `send_agent_message` lands there —
    /// so the roster has to be able to say "something arrived in here".
    @ObservedObject private var badges = SessionBadgeStore.shared

    @State private var path: [AgentRoute] = []
    @State private var showingCreate = false
    @State private var showingSettings = false
    /// Owned here because SettingsSheet can hand control to the iSH terminal,
    /// the same way ContentView drives it.
    @State private var showTerminal = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !store.isReady {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    roster
                }
            }
            .navigationTitle("一芥伙伴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Settings used to live several taps deep inside the session
                // list. The roster is the app root now, so it owns the shortcut.
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel(String(localized: "设置"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "新建 Agent"))
                }
            }
            .navigationDestination(for: AgentRoute.self) { route in
                switch route {
                case .agent(let agentId):
                    AgentMainSessionView(agentId: agentId)
                case .session(let sessionId):
                    AIChatView(sessionId: sessionId)
                }
            }
            .sheet(isPresented: $showingCreate) {
                AgentCreateView { newAgentId in
                    showingCreate = false
                    path.append(.agent(newAgentId))
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet(showTerminal: $showTerminal)
            }
            .fullScreenCover(isPresented: $showTerminal) {
                NavigationStack {
                    ISHTerminalView(showCloseButton: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSessionFromIntent)) { note in
            guard let sessionId = (note.userInfo as? [String: String])?["sessionId"] else { return }
            NotificationNavigationStore.shared.markHandled()
            openSession(sessionId)
        }
        .task {
            await store.bootstrap()
            // Cold launch: the tap that started the app posted its event before
            // this view existed, so the id was buffered instead. Drain it.
            if let pending = NotificationNavigationStore.shared.takePending() {
                openSession(pending)
            }
        }
    }

    /// Navigate to a session that arrived from outside the roster. Routed
    /// through the agent when we know which one owns it, so the user lands
    /// somewhere they can navigate back out of sensibly.
    private func openSession(_ sessionId: String) {
        Task {
            let row = await ChatStore.shared.getSession(sessionId)
            if let agentId = row?.agentId,
               let agent = await store.loadAgent(agentId),
               agent.mainSessionId == sessionId {
                path = [.agent(agentId)]
            } else {
                path = [.session(sessionId)]
            }
        }
    }

    private var roster: some View {
        List {
            ForEach(store.agents) { agent in
                Button {
                    path.append(.agent(agent.id))
                } label: {
                    AgentRow(
                        agent: agent,
                        runningTasks: runningTasks(for: agent),
                        hasUnread: agent.mainSessionId.map { badges.hasUnread(for: $0) } ?? false
                    )
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    if agent.id != AgentProfile.defaultAgentId {
                        Button(role: .destructive) {
                            Task { await store.archive(agent.id) }
                        } label: {
                            Label(String(localized: "归档"), systemImage: "archivebox")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    /// Live count of this agent's in-flight tasks, derived from the activity
    /// tracker rather than the DB so it updates while a turn is running.
    private func runningTasks(for agent: AgentProfile) -> Int {
        guard let main = agent.mainSessionId else { return 0 }
        return activity.sessionToolInfo.keys.filter { sid in
            activity.activeSessions.contains(sid) && sid != main
        }.count
    }
}

// MARK: - Row

private struct AgentRow: View {
    let agent: AgentProfile
    let runningTasks: Int
    let hasUnread: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(agent.emoji.isEmpty ? "🤖" : agent.emoji)
                .font(.system(size: 26))
                .frame(width: 46, height: 46)
                .background(AgentAccent.color(agent.accentColor).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                // Same top-trailing red dot SessionRow uses, for the same
                // meaning: unread content, cleared the moment it is opened.
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                            .offset(x: 3, y: -3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.headline).lineLimit(1)
                    if !agent.title.isEmpty {
                        Text(agent.title)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(runningTasks > 0 ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if runningTasks > 0 {
            return String(localized: "\(runningTasks) 个任务运行中")
        }
        return agent.summary.isEmpty ? String(localized: "空闲") : agent.summary
    }
}

// MARK: - Main session container

/// Wraps the agent's one conversation and hangs its settings off the toolbar.
struct AgentMainSessionView: View {
    let agentId: String

    @ObservedObject private var store = AgentStore.shared
    @State private var sessionId: String?
    @State private var showingHome = false

    var body: some View {
        Group {
            if let sessionId {
                AIChatView(sessionId: sessionId)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingHome = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel(String(localized: "Agent 设置"))
            }
        }
        .sheet(isPresented: $showingHome) {
            NavigationStack { AgentHomeView(agentId: agentId) }
        }
        .task {
            // Resolving creates the session on first open and reuses it every
            // time after — an agent never accumulates a second main session.
            sessionId = await store.openMainSession(for: agentId)
        }
    }
}

// MARK: - Create

struct AgentCreateView: View {
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = "🤖"
    @State private var title = ""
    @State private var summary = ""
    @State private var persona = ""
    @State private var policy: AgentToolPolicy = .orchestrator

    private let palette = ["#5B8DEF", "#E0A33E", "#4CAF7D", "#C46BC4", "#E4694E", "#5AA9C4"]
    @State private var accent = "#5B8DEF"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "名字"), text: $name)
                    TextField(String(localized: "头衔，如「总管」"), text: $title)
                    TextField(String(localized: "一句话介绍"), text: $summary)
                }
                Section(String(localized: "头像")) {
                    TextField(String(localized: "Emoji"), text: $emoji)
                    HStack(spacing: 10) {
                        ForEach(palette, id: \.self) { hex in
                            Circle()
                                .fill(AgentAccent.color(hex))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().stroke(Color.primary, lineWidth: accent == hex ? 2 : 0)
                                )
                                .onTapGesture { accent = hex }
                        }
                    }
                }
                Section {
                    Picker(String(localized: "工作方式"), selection: $policy) {
                        ForEach(AgentToolPolicy.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(policy.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "工具权限"))
                }
                Section {
                    TextEditor(text: $persona).frame(minHeight: 120)
                } header: {
                    Text(String(localized: "人设（写进它的 SOUL.md）"))
                } footer: {
                    Text(String(localized: "描述它是谁、说话风格、在意什么。留空则使用默认人格。"))
                }
            }
            .navigationTitle(String(localized: "新建 Agent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "创建")) {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            let agent = await AgentStore.shared.create(
                                name: trimmed,
                                emoji: emoji,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                accentColor: accent,
                                toolPolicy: policy,
                                personaBody: persona.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            onCreated(agent.id)
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
