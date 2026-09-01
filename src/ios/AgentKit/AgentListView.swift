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
    case agentDetail(String)
    case groupDetail(String)
}

enum ChatListMode: String, CaseIterable, Identifiable {
    /// Long-lived conversations with agents and groups, shown together.
    case chats = "聊天"
    /// Standalone, historical sessions that do not belong to an agent/group.
    case sessions = "对话"
    /// Operational queue across every top-level and hidden execution session.
    case tasks = "任务"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .sessions: return "clock.arrow.circlepath"
        case .tasks: return "list.bullet.clipboard"
        }
    }
}

private enum TaskQueueTimeRange: String, CaseIterable, Identifiable {
    case recentSevenDays = "近 7 天"
    case all = "全部"

    var id: String { rawValue }
}

private enum AppRootTab: Hashable {
    case chats
    case contacts
    case discover
    case me
}

private enum UnifiedChatItem: Identifiable {
    case direct(AgentProfile)
    case group(GroupProfile)

    var id: String {
        switch self {
        case .direct(let agent): return "direct:\(agent.id)"
        case .group(let group): return "group:\(group.id)"
        }
    }

}

struct AgentListView: View {
    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var activity = SessionActivityTracker.shared
    @ObservedObject private var concurrency = SessionConcurrencyManager.shared
    /// Drives the unread dot. An agent's conversation can now gain a message
    /// the user never sent — another agent's `send_agent_message` lands there —
    /// so the roster has to be able to say "something arrived in here".
    @ObservedObject private var badges = SessionBadgeStore.shared
    @ObservedObject private var groups = GroupStore.shared

    @AppStorage("home.chatListMode") private var selectedMode: ChatListMode = .chats
    @AppStorage("home.taskQueueTimeRange") private var taskQueueTimeRange: TaskQueueTimeRange = .recentSevenDays
    @AppStorage("home.taskQueueStatus") private var selectedTaskStatus: TaskQueueStatus = .inProgress
    @State private var selectedRootTab: AppRootTab = .chats
    @State private var searchText = ""
    @State private var sessions: [ChatSession] = []
    @State private var sessionsById: [String: ChatSession] = [:]
    @State private var taskQueueEntries: [TaskQueueEntry] = []
    @State private var searchResults: [ChatStore.SearchResult] = []
    @State private var searchTask: Task<Void, Never>?

    @State private var chatPath: [AgentRoute] = []
    @State private var contactsPath: [AgentRoute] = []
    @State private var showingCreate = false
    @State private var showingCreateGroup = false
    @State private var isAgentsExpanded = true
    @State private var isGroupsExpanded = true
    /// Members per group, resolved once when the roster loads so each row can
    /// show who is in it without an async lookup per redraw.
    @State private var groupMembers: [String: [GroupMember]] = [:]
    var body: some View {
        TabView(selection: $selectedRootTab) {
            chatRoot
                .tabItem { Label(String(localized: "聊天"), systemImage: "bubble.left.and.bubble.right") }
                .tag(AppRootTab.chats)

            contactsRoot
                .tabItem { Label(String(localized: "通讯录"), systemImage: "person.2") }
                .tag(AppRootTab.contacts)

            DiscoveryHubView()
                .tabItem { Label(String(localized: "发现"), systemImage: "safari") }
                .tag(AppRootTab.discover)

            MySettingsHubView()
                .tabItem { Label(String(localized: "我的"), systemImage: "person.crop.circle") }
                .tag(AppRootTab.me)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSessionFromIntent)) { note in
            guard let sessionId = (note.userInfo as? [String: String])?["sessionId"] else { return }
            NotificationNavigationStore.shared.markHandled()
            selectedRootTab = .chats
            openSession(sessionId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidCreate)) { _ in
            Task { await loadSessions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidUpdate)) { _ in
            Task { await loadSessions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
            selectedRootTab = .chats
            startNewSession()
        }
        .onChange(of: groups.groups) { _ in
            Task { await resolveGroupMembers() }
        }
        .onChange(of: selectedRootTab) { _ in
            searchText = ""
            searchResults = []
        }
        .task {
            await store.bootstrap()
            await groups.bootstrap()
            await resolveGroupMembers()
            await loadSessions()
            if let pending = NotificationNavigationStore.shared.takePending() {
                selectedRootTab = .chats
                openSession(pending)
            }
        }
    }

    private var chatRoot: some View {
        NavigationStack(path: $chatPath) {
            Group {
                if !store.isReady {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    roster
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                chatRootHeader
            }
            .navigationDestination(for: AgentRoute.self) { route in
                Group {
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
                    case .agentDetail(let agentId):
                        AgentDetailView(
                            agentId: agentId,
                            onSendMessage: { id in chatPath.append(.agent(id)) },
                            onOpenSession: { sid in chatPath.append(.session(sid)) },
                            onOpenGroup: { gid in chatPath.append(.group(gid)) }
                        )
                    case .groupDetail(let groupId):
                        GroupDetailView(
                            groupId: groupId,
                            onEnterGroupChat: { id in chatPath.append(.group(id)) },
                            onOpenAgentDetail: { aid in chatPath.append(.agentDetail(aid)) },
                            onOpenSession: { sid in chatPath.append(.session(sid)) }
                        )
                    }
                }
                .toolbar(.hidden, for: .tabBar)
            }
            .sheet(isPresented: $showingCreate) {
                AgentCreateView { newAgentId in
                    showingCreate = false
                    chatPath.append(.agent(newAgentId))
                }
            }
            .sheet(isPresented: $showingCreateGroup) {
                GroupCreateView { newGroupId in
                    showingCreateGroup = false
                    chatPath.append(.group(newGroupId))
                }
            }
        }
        .toolbar(chatPath.isEmpty ? .visible : .hidden, for: .tabBar)
    }

    private var chatRootHeader: some View {
        MinisCustomPageHeader(
            leading: {
                Color.clear.frame(width: 40, height: 40)
            },
            center: {
                Menu {
                    ForEach(ChatListMode.allCases) { mode in
                        Button {
                            selectedMode = mode
                            searchText = ""
                        } label: {
                            Label(mode.rawValue, systemImage: selectedMode == mode ? "checkmark" : mode.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedMode.rawValue)
                            .font(.headline)
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Color(UIColor.label))
                }
                .tint(Color(UIColor.label))
                .accessibilityLabel(String(localized: "切换聊天列表"))
            },
            trailing: {
                Menu {
                    Button {
                        startNewSession()
                    } label: {
                        Label(String(localized: "新建对话"), systemImage: "square.and.pencil")
                    }
                    Button {
                        showingCreate = true
                    } label: {
                        Label(String(localized: "新建智能体"), systemImage: "person.badge.plus")
                    }
                    Button {
                        showingCreateGroup = true
                    } label: {
                        Label(String(localized: "新建群聊"), systemImage: "person.2.badge.plus")
                    }
                    .disabled(displayAgents.count < 2)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(UIColor.label))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .tint(Color(UIColor.label))
                .accessibilityLabel(String(localized: "新建"))
            }
        )
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
                chatPath = [.agent(agentId)]
            } else {
                chatPath = [.session(sessionId)]
            }
        }
    }

    private var filterAndSearchBar: some View {
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
            if selectedMode == .tasks {
                Menu {
                    ForEach(TaskQueueTimeRange.allCases) { range in
                        Button {
                            taskQueueTimeRange = range
                        } label: {
                            Label(
                                range.rawValue,
                                systemImage: taskQueueTimeRange == range ? "checkmark" : "calendar"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                        Text(taskQueueTimeRange == .recentSevenDays ? "7天" : "全部")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel(String(localized: "任务时间范围"))
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
    }

    private var searchPlaceholder: String {
        switch selectedMode {
        case .chats: return String(localized: "搜索私聊和群聊...")
        case .sessions: return String(localized: "搜索对话...")
        case .tasks: return String(localized: "搜索任务和会话...")
        }
    }

    private var roster: some View {
        List {
            switch selectedMode {
            case .chats:
                Section {
                    chatsList
                } header: {
                    searchBarHeader
                }
            case .sessions:
                Section {
                    sessionsList
                } header: {
                    searchBarHeader
                }
            case .tasks:
                Section {
                    taskQueueSelectedContent
                } header: {
                    taskControlsHeader
                }
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

    private var searchBarHeader: some View {
        filterAndSearchBar
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .textCase(nil)
    }

    private var taskControlsHeader: some View {
        VStack(spacing: 8) {
            filterAndSearchBar
            taskStatusTabs
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .textCase(nil)
    }

    private var taskStatusTabs: some View {
        Picker(String(localized: "任务状态"), selection: $selectedTaskStatus) {
            ForEach(TaskQueueStatus.allCases) { status in
                Text("\(status.rawValue) \(taskEntries(for: status).count)")
                    .tag(status)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(String(localized: "切换任务状态"))
    }

    private var contactsRoot: some View {
        NavigationStack(path: $contactsPath) {
            List {
                Section {
                    contactsSearchBar
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)

                Section {
                    if isAgentsExpanded {
                        agentsList(path: $contactsPath)
                    }
                } header: {
                    collapsibleSectionHeader(
                        title: String(localized: "智能体"),
                        count: sortedFilteredAgents.count,
                        isExpanded: $isAgentsExpanded
                    )
                }

                Section {
                    if isGroupsExpanded {
                        groupsList(path: $contactsPath)
                    }
                } header: {
                    collapsibleSectionHeader(
                        title: String(localized: "群聊"),
                        count: sortedFilteredGroups.count,
                        isExpanded: $isGroupsExpanded
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "通讯录"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AgentRoute.self) { route in
                Group {
                    switch route {
                    case .agent(let agentId):
                        AgentMainSessionView(agentId: agentId)
                    case .session(let sessionId):
                        AIChatView(sessionId: sessionId)
                    case .group(let groupId):
                        GroupSessionView(groupId: groupId)
                    case .agentDetail(let agentId):
                        AgentDetailView(
                            agentId: agentId,
                            onSendMessage: { id in contactsPath.append(.agent(id)) },
                            onOpenSession: { sid in contactsPath.append(.session(sid)) },
                            onOpenGroup: { gid in contactsPath.append(.group(gid)) }
                        )
                    case .groupDetail(let groupId):
                        GroupDetailView(
                            groupId: groupId,
                            onEnterGroupChat: { id in contactsPath.append(.group(id)) },
                            onOpenAgentDetail: { aid in contactsPath.append(.agentDetail(aid)) },
                            onOpenSession: { sid in contactsPath.append(.session(sid)) }
                        )
                    }
                }
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .toolbar(contactsPath.isEmpty ? .visible : .hidden, for: .tabBar)
    }

    private var contactsSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField(String(localized: "搜索智能体和群聊..."), text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
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
    }

    private func collapsibleSectionHeader(
        title: String,
        count: Int,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack {
                Text("\(title) (\(count))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }

    // MARK: - Tab Views

    @ViewBuilder
    private var chatsList: some View {
        if unifiedChats.isEmpty {
            Text(searchText.isEmpty ? String(localized: "暂无聊天，点击右上角 + 创建") : String(localized: "未找到匹配聊天"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            ForEach(unifiedChats) { item in
                switch item {
                case .direct(let agent):
                    Button {
                        chatPath.append(.agent(agent.id))
                    } label: {
                        AgentRow(
                            agent: agent,
                            session: agent.mainSessionId.flatMap { sessionsById[$0] },
                            runningTasks: runningTasks(for: agent),
                            isRunning: isAgentRunning(agent),
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

                case .group(let group):
                    Button {
                        chatPath.append(.group(group.id))
                    } label: {
                        AgentGroupRow(
                            group: group,
                            session: sessionsById[group.sessionId],
                            members: groupMembers[group.id] ?? [],
                            isTalking: isGroupRunning(group),
                            hasUnread: badges.hasUnread(for: group.sessionId)
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
    }

    @ViewBuilder
    private var sessionsList: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            if searchResults.isEmpty {
                Text(String(localized: "未找到匹配对话"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(searchResults, id: \.session.id) { result in
                    Button {
                        chatPath.append(.session(result.session.id))
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
                Text(String(localized: "暂无对话，点击右上角 + 开始"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(sortedSessions) { session in
                    Button {
                        chatPath.append(.session(session.id))
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
    private var taskQueueSelectedContent: some View {
        let entries = taskEntries(for: selectedTaskStatus)
        if entries.isEmpty {
            Text(emptyTaskQueueLabel(for: selectedTaskStatus))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            ForEach(entries) { entry in
                Button {
                    openTaskQueueEntry(entry)
                } label: {
                    TaskQueueRow(
                        entry: entry,
                        status: selectedTaskStatus,
                        queuePosition: queuePosition(for: entry.session.id),
                        toolInfo: activity.sessionToolInfo[entry.session.id],
                        metadata: taskMetadata(for: entry)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func agentsList(path: Binding<[AgentRoute]>) -> some View {
        if sortedFilteredAgents.isEmpty {
            Text(String(localized: "暂无智能体"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            ForEach(sortedFilteredAgents) { agent in
                Button {
                    path.wrappedValue.append(.agentDetail(agent.id))
                } label: {
                    AgentRow(
                        agent: agent,
                        runningTasks: runningTasks(for: agent),
                        isRunning: isAgentRunning(agent),
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
    private func groupsList(path: Binding<[AgentRoute]>) -> some View {
        if sortedFilteredGroups.isEmpty {
            Text(String(localized: "暂无群聊"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            ForEach(sortedFilteredGroups) { group in
                Button {
                    path.wrappedValue.append(.groupDetail(group.id))
                } label: {
                    AgentGroupRow(
                        group: group,
                        members: groupMembers[group.id] ?? [],
                        isTalking: isGroupRunning(group),
                        hasUnread: badges.hasUnread(for: group.sessionId)
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

    private var visibleTaskQueueEntries: [TaskQueueEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        return taskQueueEntries.filter { entry in
            let status = taskStatus(for: entry.session.id)
            if taskQueueTimeRange == .recentSevenDays,
               status == .completed,
               entry.lastReplyAt.map({ $0 < sevenDaysAgo }) ?? true {
                return false
            }

            guard !query.isEmpty else { return true }
            let session = entry.session
            return ([session.spawnTitle, session.title, session.lastMessage, session.source, session.spawnRole]
                .compactMap { $0 }
                + [taskMetadata(for: entry).searchableText])
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func taskEntries(for status: TaskQueueStatus) -> [TaskQueueEntry] {
        visibleTaskQueueEntries
            .filter { taskStatus(for: $0.session.id) == status }
            .sorted { lhs, rhs in
                if status == .waiting {
                    return queuePosition(for: lhs.session.id) < queuePosition(for: rhs.session.id)
                }
                let leftDate = lhs.lastReplyAt ?? lhs.session.updatedAt
                let rightDate = rhs.lastReplyAt ?? rhs.session.updatedAt
                return leftDate > rightDate
            }
    }

    private func taskStatus(for sessionId: String) -> TaskQueueStatus {
        if concurrency.isSuspended(sessionId) { return .waiting }
        if activity.isActive(sessionId) || concurrency.runningSessions.contains(sessionId) {
            return .inProgress
        }
        return .completed
    }

    private func queuePosition(for sessionId: String) -> Int {
        (concurrency.suspendedSessions.firstIndex(of: sessionId) ?? Int.max - 1) + 1
    }

    private func taskMetadata(for entry: TaskQueueEntry) -> TaskQueueCardMetadata {
        let session = entry.session
        let parent = session.parentSessionId.flatMap { parentId in
            taskQueueEntries.first(where: { $0.session.id == parentId })?.session
        }
        // A subagent belongs to the conversation that launched it. For other
        // execution sessions the row itself is the conversation context.
        let contextSession = session.isSubagent ? (parent ?? session) : session

        let group = groups.groups.first { candidate in
            candidate.sessionId == contextSession.id
                || candidate.sessionId == contextSession.parentSessionId
        }

        let memberNames: [String]
        if let group {
            let members = groupMembers[group.id] ?? []
            if contextSession.spawnRole == GroupSessionRole.member,
               let memberId = contextSession.agentId,
               let member = members.first(where: { $0.id == memberId }) {
                memberNames = [member.displayName]
            } else {
                memberNames = members.map(\.displayName)
            }
        } else {
            memberNames = []
        }

        let initiatingAgentId: String? = {
            if session.isSubagent {
                return parent?.agentId ?? session.agentId
            }
            guard contextSession.agentId != AgentProfile.defaultAgentId else { return nil }
            return contextSession.agentId
        }()
        let initiatingAgentName = (session.isSubagent || group == nil)
            ? initiatingAgentId.flatMap { store.agent($0)?.name }
            : nil

        let conversationType: String
        if group != nil {
            conversationType = String(localized: "群聊")
        } else if initiatingAgentId != nil {
            conversationType = String(localized: "聊天")
        } else {
            conversationType = String(localized: "对话")
        }

        return TaskQueueCardMetadata(
            conversationType: conversationType,
            taskType: session.isSubagent ? String(localized: "子智能体") : nil,
            primaryAgentName: initiatingAgentName,
            groupMemberNames: memberNames
        )
    }

    private func openTaskQueueEntry(_ entry: TaskQueueEntry) {
        let session = entry.session
        if let group = groups.groups.first(where: { $0.sessionId == session.id }) {
            chatPath.append(.group(group.id))
            return
        }
        if let agentId = session.agentId,
           store.agent(agentId)?.mainSessionId == session.id {
            chatPath.append(.agent(agentId))
            return
        }
        chatPath.append(.session(session.id))
    }

    private func emptyTaskQueueLabel(for status: TaskQueueStatus) -> String {
        switch status {
        case .waiting: return String(localized: "暂无等待中的会话")
        case .inProgress: return String(localized: "暂无进行中的会话")
        case .completed:
            return taskQueueTimeRange == .recentSevenDays
                ? String(localized: "近 7 天暂无已完成会话")
                : String(localized: "暂无已完成会话")
        }
    }

    private var unifiedChats: [UnifiedChatItem] {
        let direct = filteredAgents.map(UnifiedChatItem.direct)
        let group = filteredGroups.map(UnifiedChatItem.group)
        return (direct + group).sorted { chatUpdatedAt($0) > chatUpdatedAt($1) }
    }

    private func chatUpdatedAt(_ item: UnifiedChatItem) -> Date {
        switch item {
        case .direct(let agent):
            return agent.mainSessionId.flatMap { sessionsById[$0]?.updatedAt } ?? agent.updatedAt
        case .group(let group):
            return sessionsById[group.sessionId]?.updatedAt ?? group.updatedAt
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

    private var sortedFilteredAgents: [AgentProfile] {
        AlphabetHelper.sortedByAlphabet(filteredAgents, by: \.name)
    }

    private var filteredGroups: [GroupProfile] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return groups.groups }
        return groups.groups.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || (groupMembers[$0.id]?.contains { $0.name.localizedCaseInsensitiveContains(q) } ?? false)
        }
    }

    private var sortedFilteredGroups: [GroupProfile] {
        AlphabetHelper.sortedByAlphabet(filteredGroups, by: \.title)
    }

    private func startNewSession() {
        selectedMode = .sessions
        let draftId = "__new__\(UUID().uuidString)"
        chatPath.append(.session(draftId))
    }

    private func loadSessions() async {
        let all = await ChatStore.shared.listSessions()
        let queueEntries = await ChatStore.shared.listTaskQueueEntries()
        sessionsById = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        taskQueueEntries = queueEntries
        sessions = all.filter { s in
            let isDefault = s.agentId == nil || s.agentId == AgentProfile.defaultAgentId
            let isNotGroup = s.spawnRole != GroupSessionRole.group
            return isDefault && isNotGroup
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedMode == .sessions, !query.isEmpty else {
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

    private func isAgentRunning(_ agent: AgentProfile) -> Bool {
        let mainIsRunning = agent.mainSessionId.map(activity.isActive) ?? false
        return mainIsRunning || runningTasks(for: agent) > 0
    }

    private func isGroupRunning(_ group: GroupProfile) -> Bool {
        activity.isActive(group.sessionId)
            || GroupChatOrchestrator.shared.isRunning(groupId: group.id)
    }
}

// MARK: - Session Row

private struct SessionRowView: View {
    let session: ChatSession
    let matchSnippet: String?

    @ObservedObject private var badges = SessionBadgeStore.shared
    @ObservedObject private var activity = SessionActivityTracker.shared

    private var isRunning: Bool { activity.isActive(session.id) }
    private var hasUnread: Bool { badges.hasUnread(for: session.id) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 19))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle().fill(Color.red)
                            .frame(width: 9, height: 9)
                            .offset(x: 2, y: -2)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .frame(width: 16, height: 16)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(session.title?.isEmpty == false ? session.title! : String(localized: "新会话"))
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(relativeDate(session.updatedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
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
    var session: ChatSession? = nil
    let runningTasks: Int
    let isRunning: Bool
    let hasUnread: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(agent.emoji.isEmpty ? "🤖" : agent.emoji)
                .font(.system(size: 22))
                .frame(width: 44, height: 44)
                .background(AgentAccent.color(agent.accentColor).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle().fill(Color.red)
                            .frame(width: 9, height: 9)
                            .offset(x: 2, y: -2)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .frame(width: 16, height: 16)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    if !agent.title.isEmpty {
                        Text(agent.title)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let date = session?.updatedAt {
                        ConversationTimestamp(date: date)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(runningTasks > 0 ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if runningTasks > 0 {
            return String(localized: "\(runningTasks) 个任务运行中")
        }
        if let lastMessage = session?.lastMessage, !lastMessage.isEmpty {
            return lastMessage
        }
        return agent.summary.isEmpty ? String(localized: "空闲") : agent.summary
    }
}

struct ConversationTimestamp: View {
    let date: Date

    var body: some View {
        Text(relativeDate)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
    }

    private var relativeDate: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "昨天")
        }
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
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
