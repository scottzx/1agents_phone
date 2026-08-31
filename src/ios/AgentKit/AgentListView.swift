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
    case group(String)
}

enum HomeTab: String, CaseIterable, Identifiable {
    case sessions = "会话"
    case agents = "伙伴"
    case groups = "群聊"

    var id: String { rawValue }
}

struct AgentListView: View {
    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var activity = SessionActivityTracker.shared
    /// Drives the unread dot. An agent's conversation can now gain a message
    /// the user never sent — another agent's `send_agent_message` lands there —
    /// so the roster has to be able to say "something arrived in here".
    @ObservedObject private var badges = SessionBadgeStore.shared
    @ObservedObject private var groups = GroupStore.shared

    @AppStorage("home.selectedTab") private var selectedTab: HomeTab = .sessions
    @State private var searchText = ""
    @State private var sessions: [ChatSession] = []
    @State private var searchResults: [ChatStore.SearchResult] = []
    @State private var searchTask: Task<Void, Never>?

    @State private var path: [AgentRoute] = []
    @State private var showingCreate = false
    @State private var showingCreateGroup = false
    /// Members per group, resolved once when the roster loads so each row can
    /// show who is in it without an async lookup per redraw.
    @State private var groupMembers: [String: [GroupMember]] = [:]
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    MinisNavigationHeader(title: String(localized: "一芥伙伴"))
                }
                // Settings used to live several taps deep inside the session
                // list. The roster is the app root now, so it owns the shortcut.
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel(String(localized: "设置"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            startNewSession()
                        } label: {
                            Label(String(localized: "新建会话"), systemImage: "square.and.pencil")
                        }
                        Button {
                            showingCreate = true
                        } label: {
                            Label(String(localized: "新建伙伴"), systemImage: "person.badge.plus")
                        }
                        Button {
                            showingCreateGroup = true
                        } label: {
                            Label(String(localized: "新建群聊"), systemImage: "person.2.badge.plus")
                        }
                        .disabled(displayAgents.count < 2)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "新建"))
                }
            }
            .navigationDestination(for: AgentRoute.self) { route in
                switch route {
                case .agent(let agentId):
                    AgentMainSessionView(agentId: agentId)
                case .session(let sessionId):
                    let destination = AgentSessionDestination(routeId: sessionId)
                    AIChatView(
                        sessionId: destination.sessionId,
                        draftId: destination.draftId,
                        initialSession: destination.sessionId.flatMap { id in
                            sessions.first(where: { $0.id == id })
                        }
                    )
                case .group(let groupId):
                    GroupSessionView(groupId: groupId)
                }
            }
            .sheet(isPresented: $showingCreate) {
                AgentCreateView { newAgentId in
                    showingCreate = false
                    path.append(.agent(newAgentId))
                }
            }
            .sheet(isPresented: $showingCreateGroup) {
                GroupCreateView { newGroupId in
                    showingCreateGroup = false
                    path.append(.group(newGroupId))
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
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidCreate)) { _ in
            Task { await loadSessions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidUpdate)) { _ in
            Task { await loadSessions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
            startNewSession()
        }
        .onChange(of: groups.groups) { _ in
            // A group created or edited elsewhere in this launch changes the
            // roster, and each row's subtitle is its member list.
            Task { await resolveGroupMembers() }
        }
        .task {
            await store.bootstrap()
            await groups.bootstrap()
            await resolveGroupMembers()
            await loadSessions()
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
               agentId != AgentProfile.defaultAgentId,
               let agent = await store.loadAgent(agentId),
               agent.mainSessionId == sessionId {
                path = [.agent(agentId)]
            } else {
                path = [.session(sessionId)]
            }
        }
    }

    private var filterAndSearchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) { _ in
                        scheduleSearch()
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        scheduleSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor.secondarySystemGroupedBackground : UIColor.white }))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Menu {
                ForEach(HomeTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack {
                            Text(tab.rawValue)
                            if selectedTab == tab {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: 38, height: 38)
                    .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor.secondarySystemGroupedBackground : UIColor.white }))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel(String(localized: "切换模式"))
        }
    }

    private var searchPlaceholder: String {
        switch selectedTab {
        case .sessions: return String(localized: "搜索会话...")
        case .agents:   return String(localized: "搜索伙伴...")
        case .groups:   return String(localized: "搜索群聊...")
        }
    }

    private var roster: some View {
        List {
            Section {
                switch selectedTab {
                case .sessions:
                    sessionsList
                case .agents:
                    agentsList
                case .groups:
                    groupsList
                }
            } header: {
                filterAndSearchBar
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await store.refresh()
            await groups.refresh()
            await resolveGroupMembers()
            await loadSessions()
        }
    }

    // MARK: - Tab Views

    @ViewBuilder
    private var sessionsList: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            if searchResults.isEmpty {
                Text(String(localized: "未找到匹配会话"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(searchResults, id: \.session.id) { result in
                    Button {
                        path.append(.session(result.session.id))
                    } label: {
                        SessionRowView(
                            session: result.session,
                            matchSnippet: result.matchSnippet
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteSession(result.session)
                        } label: {
                            Label(String(localized: "删除"), systemImage: "trash")
                        }
                    }
                }
            }
        } else {
            if sortedSessions.isEmpty {
                Text(String(localized: "暂无会话，点击右上角 + 开始新对话"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(sortedSessions) { session in
                    Button {
                        path.append(.session(session.id))
                    } label: {
                        SessionRowView(
                            session: session,
                            matchSnippet: nil
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteSession(session)
                        } label: {
                            Label(String(localized: "删除"), systemImage: "trash")
                        }
                        Button {
                            togglePin(session)
                        } label: {
                            Label(session.isPinned ? String(localized: "取消置顶") : String(localized: "置顶"),
                                  systemImage: session.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var agentsList: some View {
        if filteredAgents.isEmpty {
            Text(searchText.isEmpty ? String(localized: "暂无伙伴，点击右上角 + 创建") : String(localized: "未找到匹配伙伴"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            ForEach(filteredAgents) { agent in
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
                    Button(role: .destructive) {
                        Task { await store.archive(agent.id) }
                    } label: {
                        Label(String(localized: "归档"), systemImage: "archivebox")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var groupsList: some View {
        if filteredGroups.isEmpty {
            Text(searchText.isEmpty ? String(localized: "暂无群聊，点击右上角 + 创建") : String(localized: "未找到匹配群聊"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            ForEach(filteredGroups) { group in
                Button {
                    path.append(.group(group.id))
                } label: {
                    AgentGroupRow(
                        group: group,
                        members: groupMembers[group.id] ?? [],
                        isTalking: GroupChatOrchestrator.shared.isRunning(groupId: group.id)
                    )
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await groups.archive(group.id) }
                    } label: {
                        Label(String(localized: "归档"), systemImage: "archivebox")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var displayAgents: [AgentProfile] {
        store.agents.filter { $0.id != AgentProfile.defaultAgentId }
    }

    private var sortedSessions: [ChatSession] {
        sessions.sorted { s1, s2 in
            if s1.isPinned != s2.isPinned {
                return s1.isPinned && !s2.isPinned
            }
            return s1.updatedAt > s2.updatedAt
        }
    }

    private var filteredAgents: [AgentProfile] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return displayAgents }
        return displayAgents.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.title.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredGroups: [GroupProfile] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return groups.groups }
        return groups.groups.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || (groupMembers[$0.id]?.contains { $0.name.localizedCaseInsensitiveContains(q) } ?? false)
        }
    }

    private func startNewSession() {
        selectedTab = .sessions
        let draftId = "__new__\(UUID().uuidString)"
        path.append(.session(draftId))
    }

    private func loadSessions() async {
        let all = await ChatStore.shared.listSessions()
        sessions = all.filter { s in
            let isDefault = s.agentId == nil || s.agentId == AgentProfile.defaultAgentId
            let isNotGroup = s.spawnRole != GroupSessionRole.group
            return isDefault && isNotGroup
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let results = await ChatStore.shared.searchSessions(query: query)
            guard !Task.isCancelled else { return }
            let validIds = Set(self.sessions.map(\.id))
            self.searchResults = results.filter { validIds.contains($0.session.id) }
        }
    }

    private func deleteSession(_ session: ChatSession) {
        Task {
            await ChatStore.shared.deleteSession(session.id)
            deleteSessionFiles(session.id)
            await loadSessions()
        }
    }

    private func deleteSessionFiles(_ sessionId: String) {
        let fm = FileManager.default
        let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MinisChat/minis", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try? fm.removeItem(at: base)
        BrowserTabPool.deletePersistedData(for: sessionId)
    }

    private func togglePin(_ session: ChatSession) {
        Task {
            await ChatStore.shared.toggleSessionPin(session.id)
            await loadSessions()
        }
    }

    private func resolveGroupMembers() async {
        var resolved: [String: [GroupMember]] = [:]
        for group in groups.groups {
            resolved[group.id] = await groups.members(of: group)
        }
        groupMembers = resolved
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

// MARK: - Session Row

private struct SessionRowView: View {
    let session: ChatSession
    let matchSnippet: String?

    @ObservedObject private var badges = SessionBadgeStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 46, height: 46)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if badges.hasUnread(for: session.id) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                            .offset(x: 3, y: -3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title?.isEmpty == false ? session.title! : String(localized: "新会话"))
                        .font(.headline)
                        .lineLimit(1)
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text(relativeDate(session.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if let matchSnippet, !matchSnippet.isEmpty {
            return matchSnippet
        }
        if let last = session.lastMessage, !last.isEmpty {
            return last
        }
        return String(localized: "暂无消息")
    }

    private func relativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return String(localized: "昨天")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
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
                AIChatView(
                    sessionId: sessionId,
                    initialHeaderTitle: store.agent(agentId)?.name,
                    headerActionSystemImage: "slider.horizontal.3",
                    headerActionAccessibilityLabel: String(localized: "Agent 设置"),
                    onHeaderAction: { showingHome = true }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
