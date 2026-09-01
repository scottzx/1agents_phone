import SwiftUI
import MinisDesktopCore
import UniformTypeIdentifiers

// MARK: - Root Navigation Tab Definition (Matching iPhone 4 Navigation Tabs)

enum AppRootTab: String, CaseIterable, Identifiable {
    case chats = "聊天"
    case contacts = "通讯录"
    case discover = "发现"
    case me = "我的"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .contacts: return "person.2.fill"
        case .discover: return "safari.fill"
        case .me: return "person.crop.circle.fill"
        }
    }
}

// MARK: - Root View (iPhone/iPad 4-Tab Navigation on macOS)

struct DesktopRootView: View {
    @ObservedObject var model: DesktopViewModel
    @State private var selectedTab: AppRootTab = .chats
    @State private var showingAgent = false
    @State private var showingGroup = false
    @State private var showingSettings = false
    @State private var showingInspector = false
    @State private var isDropTargeted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                model: model,
                selectedTab: $selectedTab,
                columnVisibility: $columnVisibility,
                showingAgent: $showingAgent,
                showingGroup: $showingGroup,
                showingSettings: $showingSettings
            )
        } detail: {
            Group {
                switch selectedTab {
                case .chats:
                    ChatDetailView(
                        model: model,
                        showingInspector: $showingInspector,
                        showingSettings: $showingSettings
                    )
                case .contacts:
                    ContactsDetailView(
                        model: model,
                        showingAgent: $showingAgent,
                        showingGroup: $showingGroup
                    )
                case .discover:
                    DiscoveryHubDesktopView(
                        model: model,
                        showingInspector: $showingInspector
                    )
                case .me:
                    MySettingsDesktopView(
                        model: model,
                        showingInspector: $showingInspector
                    )
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom) {
            bottomStatusBar
        }
        .sheet(isPresented: $showingAgent) {
            NewAgentView(model: model, isPresented: $showingAgent)
        }
        .sheet(isPresented: $showingGroup) {
            NewGroupView(model: model, isPresented: $showingGroup)
        }
        .sheet(isPresented: $showingSettings) {
            ProviderSettingsView(model: model)
                .frame(width: 620, height: 520)
        }
        .sheet(isPresented: $showingInspector) {
            SessionInspectorSheet(model: model, isPresented: $showingInspector)
        }
        .sheet(item: $model.pendingShellApproval) { approval in
            ShellApprovalView(model: model, approval: approval)
        }
        .sheet(item: $model.pendingWorkspaceDrop) { workspaceDrop in
            WorkspaceDropConfirmation(model: model, workspaceDrop: workspaceDrop)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: acceptDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(8)
                    .allowsHitTesting(false)
                    .overlay {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Drop to switch workspace or add file context")
                                    .font(.headline)
                                Text("Folders set the active workspace · Files become path context")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                        .allowsHitTesting(false)
                    }
            }
        }
    }

    private var bottomStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.status.localizedCaseInsensitiveContains("error") ? Color.red : (model.isRunning ? Color.blue : Color.green))
                .frame(width: 7, height: 7)
            Text(model.status)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if model.workspacePath != "No workspace selected" {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.caption2)
                    Text(URL(fileURLWithPath: model.workspacePath).lastPathComponent)
                        .font(.caption2.monospaced())
                }
                .foregroundStyle(.tertiary)
            }
            Text("Minis")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in matching {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let itemURL = item as? URL {
                    resolvedURL = itemURL
                } else if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    resolvedURL = nil
                }
                guard let resolvedURL else { return }
                Task { @MainActor in model.receiveDroppedURLs([resolvedURL]) }
            }
        }
        return !matching.isEmpty
    }
}

// MARK: - iPadOS/iPhone-Style Sidebar with 4 Navigation Tabs

private struct SidebarView: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var selectedTab: AppRootTab
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var showingAgent: Bool
    @Binding var showingGroup: Bool
    @Binding var showingSettings: Bool

    @State private var searchText = ""
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            // Top Minis Header Bar
            sidebarHeader

            // 4 Navigation Tabs Bar (聊天 · 通讯录 · 发现 · 我的)
            navigationTabsBar

            // Tab Content (Chats, Contacts, Discover, Me)
            switch selectedTab {
            case .chats:
                chatsRosterList
            case .contacts:
                contactsRosterList
            case .discover:
                discoverSidebarList
            case .me:
                meSidebarList
            }

            // Bottom Floating Bar (Search + New Chat FAB when on chats tab)
            if selectedTab == .chats {
                bottomFloatingBar
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: model.selectedSessionID) { _, id in
            if let id { Task { await model.open(id) } }
        }
    }

    private var navigationTabsBar: some View {
        HStack(spacing: 4) {
            ForEach(AppRootTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 14, weight: selectedTab == tab ? .bold : .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        selectedTab == tab
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 12) {
            // Left avatar / settings button
            Button {
                selectedTab = .me
            } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .help("My Settings & Providers")

            Spacer()

            // Center Minis title
            Text("Minis")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            // Right New Chat / Item button
            Menu {
                Button {
                    selectedTab = .chats
                    Task { await model.createConversation() }
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    showingAgent = true
                } label: {
                    Label("新建智能体…", systemImage: "person.badge.plus")
                }

                Button {
                    showingGroup = true
                } label: {
                    Label("新建群聊…", systemImage: "person.2.badge.plus")
                }

                Divider()

                Button {
                    model.selectWorkspace()
                } label: {
                    Label("选择工作区…", systemImage: "folder")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .help("新建 (⌘N)")

            // Sidebar Toggle
            Button {
                withAnimation {
                    columnVisibility = (columnVisibility == .detailOnly ? .all : .detailOnly)
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Chats Tab Roster

    private var chatsRosterList: some View {
        VStack(spacing: 0) {
            if isSearching {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索会话与消息…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            List(selection: $model.selectedSessionID) {
                if !searchText.isEmpty {
                    Section("搜索结果") {
                        ForEach(filteredConversations) { item in
                            SessionRow(model: model, item: item)
                                .tag(item.id)
                                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .listRowSeparator(.hidden)
                        }
                    }
                } else {
                    let todayItems = conversationsForBucket(.today)
                    let yesterdayItems = conversationsForBucket(.yesterday)
                    let last7DaysItems = conversationsForBucket(.previous7Days)
                    let olderItems = conversationsForBucket(.older)

                    if !todayItems.isEmpty {
                        Section("今天") {
                            ForEach(todayItems) { item in
                                SessionRow(model: model, item: item)
                                    .tag(item.id)
                                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }

                    if !yesterdayItems.isEmpty {
                        Section("昨天") {
                            ForEach(yesterdayItems) { item in
                                SessionRow(model: model, item: item)
                                    .tag(item.id)
                                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }

                    if !last7DaysItems.isEmpty {
                        Section("过去 7 天") {
                            ForEach(last7DaysItems) { item in
                                SessionRow(model: model, item: item)
                                    .tag(item.id)
                                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }

                    if !olderItems.isEmpty {
                        Section("更早") {
                            ForEach(olderItems) { item in
                                SessionRow(model: model, item: item)
                                    .tag(item.id)
                                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Contacts Tab Roster

    private var contactsRosterList: some View {
        List(selection: $model.selectedSessionID) {
            Section {
                Button {
                    showingAgent = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32, height: 32)
                            .background(Color.accentColor.opacity(0.15), in: Circle())
                        Text("新建智能体")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)

                Button {
                    showingGroup = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.indigo)
                            .frame(width: 32, height: 32)
                            .background(Color.indigo.opacity(0.15), in: Circle())
                        Text("新建群聊")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            } header: {
                Text("快捷操作")
            }

            if !model.agents.isEmpty {
                Section("智能体 (\(model.agents.count))") {
                    ForEach(model.agents) { agent in
                        if let session = model.conversations.first(where: { $0.agentID == agent.id && $0.groupID == nil }) {
                            SessionRow(model: model, item: session, customEmoji: agent.emoji)
                                .tag(session.id)
                                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }

            if !model.groups.isEmpty {
                Section("群聊 (\(model.groups.count))") {
                    ForEach(model.groups) { group in
                        if let session = model.conversations.first(where: { $0.id == group.sessionID }) {
                            SessionRow(model: model, item: session, isGroup: true)
                                .tag(session.id)
                                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Discover Sidebar

    private var discoverSidebarList: some View {
        List {
            Section("智能体运行时") {
                Label("Skills 技能库", systemImage: "puzzlepiece.extension")
                Label("Soul 人设与记忆", systemImage: "sparkles")
                Label("MCP 工具集成", systemImage: "square.stack.3d.up")
                Label("环境变量配置", systemImage: "terminal")
            }

            Section("存储与同步") {
                Label("工作区与目录挂载", systemImage: "folder.badge.gearshape")
                Label("iCloud 云同步", systemImage: "icloud")
            }

            Section("硬件与扩展") {
                Label("硬件设备桥接", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Me Sidebar

    private var meSidebarList: some View {
        List {
            Section("模型与服务商") {
                Label("服务提供商管理", systemImage: "key.fill")
                    .foregroundStyle(Color.accentColor)
                Label("模型组配置", systemImage: "gearshape.circle.fill")
                Label("Token 消耗统计", systemImage: "chart.line.uptrend.xyaxis")
            }

            Section("系统偏好") {
                Label("macOS Shell 执行权限", systemImage: "terminal.fill")
                Label("外观与主题", systemImage: "paintbrush.fill")
                Label("运行日志与诊断", systemImage: "doc.text")
                Label("关于 Minis", systemImage: "info.circle")
            }
        }
        .listStyle(.sidebar)
    }

    private var bottomFloatingBar: some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isSearching.toggle()
                }
            } label: {
                Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .help("搜索会话 (⌘F)")

            Spacer()

            Button {
                Task { await model.createConversation() }
            } label: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .help("新建会话 (⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var filteredConversations: [RuntimeConversation] {
        model.conversations.filter { conversation in
            if searchText.isEmpty { return true }
            return conversation.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private enum DateBucket {
        case today, yesterday, previous7Days, older
    }

    private func conversationsForBucket(_ bucket: DateBucket) -> [RuntimeConversation] {
        let calendar = Calendar.current
        let now = Date()
        let directChats = model.conversations.filter { $0.kind == .conversation }

        return directChats.filter { item in
            switch bucket {
            case .today:
                return calendar.isDateInToday(item.updatedAt)
            case .yesterday:
                return calendar.isDateInYesterday(item.updatedAt)
            case .previous7Days:
                let daysAgo = calendar.dateComponents([.day], from: item.updatedAt, to: now).day ?? 0
                return daysAgo >= 2 && daysAgo <= 7
            case .older:
                let daysAgo = calendar.dateComponents([.day], from: item.updatedAt, to: now).day ?? 0
                return daysAgo > 7
            }
        }
    }
}

// MARK: - iPadOS-Style Session Row (44x44 Circle Icon + Title + Subtitle + Time)

private struct SessionRow: View {
    @ObservedObject var model: DesktopViewModel
    let item: RuntimeConversation
    var customEmoji: String? = nil
    var isGroup: Bool = false

    private var isSelected: Bool {
        model.selectedSessionID == item.id
    }

    private var categoryInfo: (systemName: String, color: Color) {
        if isGroup { return ("person.3.fill", .indigo) }
        let titleLower = item.title.lowercased()
        if titleLower.contains("code") || titleLower.contains("devops") || titleLower.contains("git") || titleLower.contains("terminal") || titleLower.contains("build") {
            return ("terminal.fill", .orange)
        } else if titleLower.contains("research") || titleLower.contains("claude") || titleLower.contains("karpathy") || titleLower.contains("web") || titleLower.contains("github") {
            return ("globe.americas.fill", .teal)
        } else if titleLower.contains("weather") || titleLower.contains("trip") || titleLower.contains("travel") || titleLower.contains("itinerary") {
            return ("map.fill", .orange)
        } else if titleLower.contains("photo") || titleLower.contains("image") || titleLower.contains("design") || titleLower.contains("post") {
            return ("photo.fill", .pink)
        } else if titleLower.contains("email") || titleLower.contains("calendar") || titleLower.contains("action") || titleLower.contains("task") {
            return ("calendar.badge.checkmark", .yellow)
        } else if titleLower.contains("bill") || titleLower.contains("finance") || titleLower.contains("usd") || titleLower.contains("split") {
            return ("banknote.fill", .mint)
        } else if titleLower.contains("book") || titleLower.contains("summary") || titleLower.contains("notes") || titleLower.contains("reading") {
            return ("book.closed.fill", .blue)
        } else if titleLower.contains("sleep") || titleLower.contains("health") || titleLower.contains("fitness") {
            return ("heart.fill", .red)
        }
        return ("bubble.left.fill", .green)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 44x44 circular category avatar
            ZStack {
                Circle()
                    .fill(categoryInfo.color.opacity(isSelected ? 0.30 : 0.18))
                    .frame(width: 44, height: 44)

                if let emoji = customEmoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: 22))
                } else {
                    Image(systemName: categoryInfo.systemName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(categoryInfo.color)
                }
            }

            // Title + Subtitle
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Trailing relative timestamp
            VStack(alignment: .trailing, spacing: 4) {
                Text(formatRelativeTime(item.updatedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                if model.isRunning && isSelected {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.14)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(Rectangle())
        .contextMenu {
            Menu("Bind Provider") {
                Button("Default Provider") {
                    Task { await model.bindSelectedSession(to: nil) }
                }
                ForEach(model.providerConfigurations, id: \.id) { config in
                    Button(config.displayName) {
                        Task { await model.bindSelectedSession(to: config.id) }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                Task { await model.deleteConversation(item.id) }
            } label: {
                Label("Delete Conversation", systemImage: "trash")
            }
        }
    }

    private var subtitleText: String {
        if let providerID = item.providerConfigurationID,
           let config = model.providerConfigurations.first(where: { $0.id == providerID }) {
            return config.displayName
        }
        return "Conversation"
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let now = Date()
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        let hours = seconds / 3600
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}

// MARK: - iPadOS-Style Chat Detail View

private struct ChatDetailView: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var showingInspector: Bool
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Centered Top Header Bar
            detailHeader

            if model.selectedConversation == nil {
                emptySelectionState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            if model.messages.isEmpty {
                                welcomeGreeting
                            } else {
                                ForEach(model.messages) { message in
                                    MessageRowView(
                                        message: message,
                                        senderName: senderName(message),
                                        senderEmoji: senderEmoji(message)
                                    )
                                    .id(message.id)
                                }
                            }

                            if model.isRunning {
                                runningActivityIndicator
                                    .id("running_activity_bottom")
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 880)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.messages.count) { _, _ in
                        if let lastID = model.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: model.isRunning) { _, isRunning in
                        if isRunning {
                            withAnimation { proxy.scrollTo("running_activity_bottom", anchor: .bottom) }
                        }
                    }
                }

                // Floating Composer Bar
                composerArea
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Spacer()

            // Centered Title + Provider/Model Subtitle
            VStack(spacing: 3) {
                Text(model.selectedConversation?.title ?? "Minis")
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)

                if model.selectedConversation != nil {
                    Menu {
                        Button("Default Models") {
                            Task { await model.bindSelectedSession(to: nil) }
                        }
                        ForEach(model.providerConfigurations, id: \.id) { config in
                            Button(config.displayName) {
                                Task { await model.bindSelectedSession(to: config.id) }
                            }
                        }
                        Divider()
                        Button("Provider Settings…") {
                            showingSettings = true
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(model.isRunning ? Color.blue : Color.green)
                                .frame(width: 6, height: 6)
                            Text(currentProviderTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Right Action Menu (`...`)
            if model.selectedConversation != nil {
                Menu {
                    Button {
                        model.selectWorkspace()
                    } label: {
                        Label("Choose Workspace…", systemImage: "folder")
                    }

                    Button {
                        showingInspector = true
                    } label: {
                        Label("Session Tools & Shell…", systemImage: "slider.horizontal.3")
                    }

                    Divider()

                    Button(role: .destructive) {
                        if let id = model.selectedSessionID {
                            Task { await model.deleteConversation(id) }
                        }
                    } label: {
                        Label("Delete Conversation", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help("Session options")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var currentProviderTitle: String {
        guard let conv = model.selectedConversation else { return "Default Models" }
        if let providerID = conv.providerConfigurationID,
           let config = model.providerConfigurations.first(where: { $0.id == providerID }) {
            return config.displayName
        }
        return "Default Models · OpenAI · GPT-5.1"
    }

    private var emptySelectionState: some View {
        ContentUnavailableView {
            Label("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Select a chat from the sidebar or start a new conversation to begin.")
        } actions: {
            Button("New Conversation") {
                Task { await model.createConversation() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeGreeting: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 42))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(.top, 20)

            VStack(spacing: 6) {
                Text("What would you like to build today?")
                    .font(.title2.weight(.bold))
                Text("Give Minis a task, add file context, or drop a repository folder anywhere in the window.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            VStack(spacing: 10) {
                quickPromptButton(title: "Explore workspace code", icon: "doc.text.magnifyingglass") {
                    model.composer = "Please inspect the current workspace structure and summarize key components."
                }
                quickPromptButton(title: "Run diagnostic terminal command", icon: "terminal") {
                    model.composer = "Can you run `git status` and check if there are uncommitted changes in the repository?"
                }
                quickPromptButton(title: "Select or switch workspace folder", icon: "folder.badge.plus") {
                    model.selectWorkspace()
                }
            }
            .frame(maxWidth: 460)
            .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func quickPromptButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var runningActivityIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(model.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var composerArea: some View {
        VStack(spacing: 6) {
            if !model.fileContextURLs.isEmpty {
                FileContextBar(model: model)
            }

            VStack(spacing: 0) {
                TextEditor(text: $model.composer)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 130)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .overlay(alignment: .topLeading) {
                        if model.composer.isEmpty {
                            Text("Message Minis (@ to mention files)")
                                .font(.system(size: 15))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 18)
                                .padding(.top, 10)
                                .allowsHitTesting(false)
                        }
                    }

                // Inner Toolbar: + / cpu / mic / send
                HStack(alignment: .center, spacing: 10) {
                    // Attachment '+' Button
                    Menu {
                        Button {
                            model.selectWorkspace()
                        } label: {
                            Label("Add Folder / Workspace…", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(.quaternary.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)

                    // Slash command '/' Button
                    Button {
                        if model.composer.isEmpty {
                            model.composer = "/"
                        }
                    } label: {
                        Text("/")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(.quaternary.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)

                    // Model / Provider Selector 'cpu' Button
                    Menu {
                        ForEach(model.providerConfigurations, id: \.id) { config in
                            Button(config.displayName) {
                                Task { await model.bindSelectedSession(to: config.id) }
                            }
                        }
                    } label: {
                        Image(systemName: "cpu")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(.quaternary.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Voice / Mic button
                    Button {
                        // voice simulation toggle
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(.quaternary.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)

                    // Send / Stop Arrow Button
                    if model.isRunning {
                        Button {
                            Task { await model.cancel() }
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(Color.red)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            Task { await model.send() }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(model.canSend ? Color.accentColor : Color.gray.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func senderName(_ message: RuntimeMessageRecord) -> String {
        guard let id = message.senderAgentID else { return "Minis" }
        return model.agents.first(where: { $0.id == id })?.name ?? "Minis"
    }

    private func senderEmoji(_ message: RuntimeMessageRecord) -> String? {
        guard let id = message.senderAgentID else { return nil }
        return model.agents.first(where: { $0.id == id })?.emoji
    }
}

// MARK: - Contacts Detail View (智能体与群聊详情)

private struct ContactsDetailView: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var showingAgent: Bool
    @Binding var showingGroup: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack {
                Text("通讯录")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Menu {
                    Button {
                        showingAgent = true
                    } label: {
                        Label("新建智能体", systemImage: "person.badge.plus")
                    }
                    Button {
                        showingGroup = true
                    } label: {
                        Label("新建群聊", systemImage: "person.2.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(.quaternary.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            if let selected = model.selectedConversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Contact Card Header
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.18))
                                    .frame(width: 64, height: 64)
                                if let agentID = selected.agentID,
                                   let agent = model.agents.first(where: { $0.id == agentID }),
                                   !agent.emoji.isEmpty {
                                    Text(agent.emoji)
                                        .font(.system(size: 32))
                                } else {
                                    Image(systemName: selected.kind == .group ? "person.3.fill" : "person.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(selected.title)
                                    .font(.title2.weight(.bold))
                                Text(selected.kind == .group ? "群聊会话" : "智能体助手")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            Button {
                                // Already selected, switch to chats tab or send message
                            } label: {
                                Label("发消息", systemImage: "bubble.left.fill")
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // Configuration & Details
                        VStack(alignment: .leading, spacing: 14) {
                            Text("基础属性")
                                .font(.headline)

                            HStack {
                                Text("会话 ID")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(selected.id)
                                    .font(.caption.monospaced())
                            }
                            Divider()

                            HStack {
                                Text("绑定模型服务商")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(selected.providerConfigurationID ?? "默认提供商 (OpenAI / GPT-5.1)")
                                    .font(.subheadline.weight(.medium))
                            }
                            Divider()

                            HStack {
                                Text("创建/更新时间")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(selected.updatedAt, style: .date)
                                    .font(.subheadline)
                            }
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(28)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView {
                    Label("选择智能体或群聊", systemImage: "person.2")
                } description: {
                    Text("在左侧列表中选择联系人，或点击右上角加号创建新的智能体与群聊。")
                } actions: {
                    HStack(spacing: 12) {
                        Button("新建智能体") { showingAgent = true }
                            .buttonStyle(.borderedProminent)
                        Button("新建群聊") { showingGroup = true }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Discovery Hub Desktop View (发现)

private struct DiscoveryHubDesktopView: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var showingInspector: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack {
                Text("发现")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Agent Runtime Section
                    discoverySectionHeader(title: "智能体运行时 (Agent Runtime)", icon: "cpu")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        discoveryCard(title: "Skills 技能库", subtitle: "管理内置与自定义扩展工具能力", icon: "puzzlepiece.extension.fill", color: .blue) {
                            showingInspector = true
                        }
                        discoveryCard(title: "Soul 人设配置", subtitle: "定制智能体性格、系统提示词与原则", icon: "sparkles", color: .pink) {
                            showingInspector = true
                        }
                        discoveryCard(title: "Memory 记忆管理", subtitle: "跨会话长期记忆存储与检索", icon: "brain.head.profile", color: .purple) {
                            showingInspector = true
                        }
                        discoveryCard(title: "MCP 工具集成", subtitle: "Model Context Protocol 标准服务接入", icon: "square.stack.3d.up.fill", color: .teal) {
                            showingInspector = true
                        }
                        discoveryCard(title: "环境变量配置", subtitle: "配置 API 密钥与第三方环境变量", icon: "terminal.fill", color: .green) {
                            showingInspector = true
                        }
                    }

                    // Storage & Sync Section
                    discoverySectionHeader(title: "存储与工作区 (Storage & Sync)", icon: "folder.fill")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        discoveryCard(title: "工作区目录挂载", subtitle: model.workspacePath == "No workspace selected" ? "未选择工作区" : URL(fileURLWithPath: model.workspacePath).lastPathComponent, icon: "folder.badge.gearshape.fill", color: .orange) {
                            model.selectWorkspace()
                        }
                        discoveryCard(title: "iCloud 云同步", subtitle: model.cloudSyncMessage, icon: "icloud.fill", color: .cyan) {
                            Task { await model.synchronizeNow() }
                        }
                    }

                    // Hardware Section
                    discoverySectionHeader(title: "硬件与终端 (Hardware & Terminal)", icon: "antenna.radiowaves.left.and.right")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        discoveryCard(title: "macOS 终端面板", subtitle: "运行本地 Shell 命令与构建脚本", icon: "terminal.fill", color: .indigo) {
                            showingInspector = true
                        }
                        discoveryCard(title: "硬件设备桥接", subtitle: "蓝牙与本地硬件外设通信支持", icon: "antenna.radiowaves.left.and.right", color: .mint) {
                            showingInspector = true
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func discoverySectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
        }
        .padding(.top, 6)
    }

    private func discoveryCard(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - My Settings Desktop View (我的 · 服务提供商管理 · 模型组 · 权限)

private struct MySettingsDesktopView: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var showingInspector: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack {
                Text("我的")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // LLM Provider Management Card
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.18))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "key.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("服务提供商管理 (LLM Providers)")
                                    .font(.system(size: 16, weight: .bold))
                                Text("配置 OpenAI, Anthropic, Gemini, DeepSeek, OpenRouter 与自定义模型接口")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            Button("新建配置") {
                                model.createProviderConfiguration()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Divider()

                        // Configured Providers List
                        if model.providerConfigurations.isEmpty {
                            Text("暂无配置的 Provider，点击上方“新建配置”添加。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(model.providerConfigurations, id: \.id) { config in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(config.displayName)
                                                    .font(.system(size: 14, weight: .semibold))
                                                Text("(\(config.providerType.rawValue))")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            let modelId = config.model.id
                                            let endpointStr = config.endpoint.absoluteString
                                            Text("Model: \(modelId) · Endpoint: \(endpointStr)")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Button("编辑") { model.editProvider(config) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                        Button("测试连接") {
                                            Task { await model.testProvider(config.id) }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(model.isProviderTesting)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }

                        // Provider Edit Form
                        VStack(alignment: .leading, spacing: 10) {
                            Text("编辑 / 保存提供商信息")
                                .font(.system(size: 13, weight: .bold))

                            HStack(spacing: 12) {
                                TextField("配置 ID", text: $model.providerConfigurationID)
                                    .textFieldStyle(.roundedBorder)
                                Picker("类型", selection: Binding(
                                    get: { model.providerKind },
                                    set: { model.selectProviderKind($0) }
                                )) {
                                    ForEach(DesktopProviderKind.allCases) { kind in
                                        Text(kind.displayName).tag(kind)
                                    }
                                }
                                .frame(width: 160)
                            }

                            HStack(spacing: 12) {
                                TextField("显示名称 (Display Name)", text: $model.providerDisplayName)
                                    .textFieldStyle(.roundedBorder)
                                TextField("模型 ID (e.g. gpt-5.1, claude-sonnet-4-5)", text: $model.providerModel)
                                    .textFieldStyle(.roundedBorder)
                            }

                            TextField("API 接口地址 (Endpoint URL)", text: $model.providerEndpoint)
                                .textFieldStyle(.roundedBorder)

                            SecureField("API Key 密钥", text: $model.providerKey)
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                Button("保存此配置") {
                                    Task { await model.saveProvider() }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.providerConfigurationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                Button(model.isProviderTesting ? "测试中…" : "测试当前配置") {
                                    Task { await model.testProvider() }
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isProviderTesting)

                                if model.providerKind == .openRouter {
                                    Button(model.isProviderAuthenticating ? "登录中…" : "OpenRouter 一键登录") {
                                        Task { await model.signInWithOpenRouter() }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isProviderAuthenticating)
                                }
                            }

                            if !model.providerTestStatus.isEmpty {
                                Text(model.providerTestStatus)
                                    .font(.caption)
                                    .foregroundStyle(model.providerTestStatus.contains("Success") ? Color.green : Color.orange)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(14)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // Model Groups & Token Usage
                    VStack(alignment: .leading, spacing: 14) {
                        Text("模型组与消耗统计 (Model Groups & Usage)")
                            .font(.headline)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("默认模型组")
                                    .font(.subheadline.weight(.semibold))
                                Text("智能轮询与故障回退 (Fallback)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("GPT-5.1 · Claude 4.5 · Kimi")
                                .font(.caption.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                        Divider()

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Token 消耗统计")
                                    .font(.subheadline.weight(.semibold))
                                Text("实时监控会话与智能体上下文消耗")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("已记录 \(model.messages.count) 条消息")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // Permissions & macOS Shell
                    VStack(alignment: .leading, spacing: 14) {
                        Text("系统权限与 macOS Shell 执行")
                            .font(.headline)

                        Toggle("允许智能体执行 macOS Shell 命令", isOn: Binding(
                            get: { model.selectedConversation?.agentShellAccess == true },
                            set: { enabled in Task { await model.setAgentShellAccess(enabled) } }
                        ))
                        .help("开启后，智能体执行本地终端命令时会触发安全审批弹窗。")

                        HStack {
                            Button("打开终端工具抽屉…") { showingInspector = true }
                                .buttonStyle(.bordered)
                            Button("同步当前数据库…") { Task { await model.synchronizeNow() } }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // About
                    VStack(alignment: .leading, spacing: 8) {
                        Text("关于 Minis")
                            .font(.headline)
                        Text("Minis 桌面端（已对齐 iPhone/iPadOS 4-Tab 交互与服务提供商管理）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(28)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Rich Message Row with Markdown Table & Tool Cards Support

private struct MessageRowView: View {
    let message: RuntimeMessageRecord
    let senderName: String
    let senderEmoji: String?

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !isUser {
                avatar
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                if !isUser {
                    HStack(spacing: 6) {
                        Text(senderName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                        Text(message.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Parsed Message Body (Tables, Tool Cards, Images, Text)
                VStack(alignment: .leading, spacing: 12) {
                    if isUser {
                        Text(message.text)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .lineSpacing(4)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .foregroundStyle(Color.white)
                    } else {
                        AssistantMessageContent(text: message.text)
                    }
                }
                .frame(maxWidth: 780, alignment: isUser ? .trailing : .leading)

                // Message Actions (Copy)
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy text")
                }
                .padding(.horizontal, 4)
            }

            if isUser {
                avatar
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(isUser ? Color.accentColor.opacity(0.15) : Color.accentColor.opacity(0.2))
                .frame(width: 34, height: 34)

            if isUser {
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            } else if let emoji = senderEmoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 18))
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Assistant Message Content (Markdown Headings, Tables, Tool Pills, Images)

private struct AssistantMessageContent: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let blocks = parseContentBlocks(text)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(content)
                        .font(level == 1 ? .system(size: 20, weight: .bold) : (level == 2 ? .system(size: 17, weight: .bold) : .system(size: 15, weight: .semibold)))
                        .foregroundStyle(.primary)
                        .padding(.top, 4)

                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows)

                case .toolPill(let toolName, let status):
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(toolName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(status)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                case .imagePoster(let title, let subtitle, let fileName):
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .center, spacing: 6) {
                            Text(title)
                                .font(.system(size: 18, weight: .heavy))
                                .foregroundStyle(.white)
                            Text(subtitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .background(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )

                        if let fileName {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text("Download / Open: \(fileName)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .padding(.horizontal, 4)
                        }
                    }

                case .paragraph(let content):
                    Text(content)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private enum ContentBlock {
        case heading(level: Int, content: String)
        case table(headers: [String], rows: [[String]])
        case toolPill(toolName: String, status: String)
        case imagePoster(title: String, subtitle: String, fileName: String?)
        case paragraph(content: String)
    }

    private func parseContentBlocks(_ raw: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                i += 1
                continue
            }

            // Headings (#, ##, ###)
            if line.hasPrefix("### ") {
                blocks.append(.heading(level: 3, content: String(line.dropFirst(4))))
                i += 1
                continue
            } else if line.hasPrefix("## ") {
                blocks.append(.heading(level: 2, content: String(line.dropFirst(3))))
                i += 1
                continue
            } else if line.hasPrefix("# ") {
                blocks.append(.heading(level: 1, content: String(line.dropFirst(2))))
                i += 1
                continue
            }

            // Markdown Table Detection (| Col 1 | Col 2 |)
            if line.hasPrefix("|") && line.hasSuffix("|") && i + 1 < lines.count && lines[i + 1].contains("---") {
                let headerLine = line
                let headers = headerLine.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                i += 2 // skip header + divider line
                var tableRows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    guard rowLine.hasPrefix("|") && rowLine.hasSuffix("|") else { break }
                    let cells = rowLine.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    tableRows.append(cells)
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: tableRows))
                continue
            }

            // Tool Execution Pill Detection ([tool: ...])
            if line.lowercased().contains("search results") || line.lowercased().contains("tool execution") {
                blocks.append(.toolPill(toolName: "Read izakaya search results", status: "< 4/4 >"))
                i += 1
                continue
            }

            // General Paragraph
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty ||
                    next.hasPrefix("#") ||
                    (next.hasPrefix("|") && next.hasSuffix("|")) {
                    break
                }
                paragraphLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(content: paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }
}

// MARK: - Beautiful Markdown Table View

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            // Table Header Row
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
                    Text(header)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    if idx < headers.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Table Rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(headers.indices), id: \.self) { colIdx in
                        let cellText = colIdx < row.count ? row[colIdx] : ""
                        Text(cellText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        if colIdx < headers.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(rowIdx % 2 == 0 ? Color(NSColor.textBackgroundColor).opacity(0.4) : Color.clear)
                if rowIdx < rows.count - 1 {
                    Divider()
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        }
    }
}

// MARK: - Attached File Context Bar

private struct FileContextBar: View {
    @ObservedObject var model: DesktopViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.fileContextURLs, id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(systemName: "doc.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Text(url.lastPathComponent)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Button {
                            model.revealInFinder(url)
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                        Button {
                            model.removeFileContext(url)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("Remove file")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.7), in: Capsule())
                }
            }
        }
    }
}

// MARK: - Session Inspector Sheet (Tools, Workspace, Terminal, Providers)

struct SessionInspectorSheet: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.workspacePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        HStack {
                            Button("Choose Folder…") { model.selectWorkspace() }
                            Button("Reveal in Finder") { model.revealWorkspaceInFinder() }
                                .disabled(model.workspacePath == "No workspace selected")
                        }
                    }
                }

                Section("macOS Shell Execution") {
                    Toggle("Allow Agent to execute macOS Shell commands", isOn: Binding(
                        get: { model.selectedConversation?.agentShellAccess == true },
                        set: { enabled in Task { await model.setAgentShellAccess(enabled) } }
                    ))
                    .help("When enabled, model shell commands require explicit approval.")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Test Command:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Command", text: $model.shellCommand)
                            .font(.caption.monospaced())
                            .textFieldStyle(.roundedBorder)
                        Button("Run Shell Command") { Task { await model.runShell() } }
                            .disabled(model.isRunning)

                        if !model.shellOutput.isEmpty {
                            ScrollView {
                                Text(model.shellOutput)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 100)
                            .padding(6)
                            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                Section("Embedded Terminal") {
                    TerminalPanel(model: model, minimumHeight: 180)
                }

                if let conversation = model.selectedConversation {
                    Section("Session Runtime & Provider") {
                        LabeledContent("Session ID", value: String(conversation.id.prefix(8)))
                        LabeledContent("Kind", value: conversation.kind.rawValue.capitalized)
                        Picker("Provider", selection: Binding(
                            get: { conversation.providerConfigurationID ?? "__default__" },
                            set: { value in Task { await model.bindSelectedSession(to: value == "__default__" ? nil : value) } }
                        )) {
                            Text("Default Provider").tag("__default__")
                            ForEach(model.providerConfigurations, id: \.id) { configuration in
                                Text(configuration.displayName).tag(configuration.id)
                            }
                        }
                    }
                }

                Section("iCloud Sync") {
                    Text(model.cloudSyncMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let sync = model.cloudSyncStatus {
                        HStack {
                            LabeledContent("Uploaded", value: String(sync.uploadedCount))
                            LabeledContent("Downloaded", value: String(sync.downloadedCount))
                        }
                    }
                    Button(model.isCloudSyncing ? "Syncing…" : "Sync Now") {
                        Task { await model.synchronizeNow() }
                    }
                    .disabled(model.isCloudSyncing)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Session Tools & Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .frame(width: 580, height: 600)
    }
}
// MARK: - Auxiliary Sheets & Panels

struct WorkspaceDropConfirmation: View {
    @ObservedObject var model: DesktopViewModel
    let workspaceDrop: PendingWorkspaceDrop

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Use Dropped Folder as Workspace?", systemImage: "folder.badge.plus")
                .font(.title2.bold())
            Text(workspaceDrop.url.path)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text("Yima will grant this folder and switch the current conversation to it. No files will be executed by dropping the folder.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissDroppedWorkspace() }
                Button("Grant and Switch") { Task { await model.confirmDroppedWorkspace() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

struct TerminalWindowView: View {
    @ObservedObject var model: DesktopViewModel
    let route: TerminalWindowRoute?

    var body: some View {
        Group {
            if let tabID = route?.tabID, model.terminalTabs.contains(where: { $0.id == tabID }) {
                TerminalPanel(model: model, preferredTabID: tabID, minimumHeight: 440)
            } else {
                VStack(spacing: 12) {
                    ContentUnavailableView("Terminal Closed", systemImage: "rectangle.portrait.and.arrow.right")
                    Button("New Terminal") {
                        Task {
                            if let tabID = await model.openTerminal(showInInspector: false) {
                                model.focusTerminal(tabID)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .onAppear { if let tabID = route?.tabID { model.focusTerminal(tabID) } }
    }
}

struct TerminalPanel: View {
    @ObservedObject var model: DesktopViewModel
    var preferredTabID: UUID?
    var minimumHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.terminalTabs.isEmpty {
                Button("Open Terminal Tab") { Task { await model.openTerminal() } }
            } else {
                if preferredTabID == nil {
                    terminalPicker
                } else if let tab = visibleTab {
                    Text(tab.title).font(.headline)
                }
                if let tab = visibleTab {
                    MacTerminalView(
                        output: tab.output,
                        columns: tab.columns,
                        rows: tab.rows,
                        onResize: { columns, rows in
                            Task { await model.resizeTerminal(tab.id, columns: columns, rows: rows) }
                        },
                        onFocus: { model.focusTerminal(tab.id) },
                        onClear: { model.clearTerminal(tab.id) },
                        onClose: { Task { await model.closeTerminal(tab.id) } }
                    )
                    .frame(minHeight: minimumHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack {
                        TextField("Type a command", text: Binding(
                            get: { model.terminalInput(for: tab.id) },
                            set: { model.setTerminalInput($0, for: tab.id) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.submitTerminalInput(tabID: tab.id) } }
                        Button("⌃C") { Task { await model.interruptTerminal(tabID: tab.id) } }
                            .disabled(!tab.isRunning)
                        Button("Clear") { model.clearTerminal(tab.id) }
                        Button("Close") { Task { await model.closeTerminal(tab.id) } }
                    }
                    if !tab.isRunning {
                        Text("Process exited — close this tab or open a new terminal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { if let preferredTabID { model.focusTerminal(preferredTabID) } }
    }

    private var visibleTab: TerminalTabState? {
        if let preferredTabID, let tab = model.terminalTabs.first(where: { $0.id == preferredTabID }) { return tab }
        return model.selectedTerminalTab
    }

    private var terminalPicker: some View {
        HStack {
            Picker("Terminal", selection: Binding(
                get: { preferredTabID ?? model.selectedTerminalTabID },
                set: { if let id = $0 { model.focusTerminal(id) } }
            )) {
                ForEach(model.terminalTabs) { tab in
                    Text(tab.title).tag(Optional(tab.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await model.openTerminal() } } label: { Image(systemName: "plus") }
                .help("New terminal tab")
        }
    }
}

struct ShellApprovalView: View {
    @ObservedObject var model: DesktopViewModel
    let approval: ShellApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(approval.isShellCommand ? "Approve macOS Shell Command?" : "Approve macOS Native Action?", systemImage: "exclamationmark.shield")
                .font(.title2.bold())
            Text(approval.isShellCommand
                 ? "\(approval.agentName) requested a shell command. It runs with your macOS user permissions and can access local files."
                 : "\(approval.agentName) requested \(approval.toolName).")
                .foregroundStyle(.secondary)
            GroupBox(approval.isShellCommand ? "Working Directory" : "Action Type") {
                Text(approval.workingDirectory).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(approval.isShellCommand ? "Command" : "Requested Action") {
                ScrollView { Text(approval.command).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 100, maxHeight: 240)
            }
            HStack {
                Spacer()
                Button("Deny", role: .cancel) { Task { await model.resolveShellApproval(approval, approved: false) } }
                Button("Approve Once") { Task { await model.resolveShellApproval(approval, approved: true) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled()
    }
}

struct NewAgentView: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var title = ""
    @State private var summary = ""
    @State private var emoji = "🤖"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Agent").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                TextField("Role", text: $title)
                TextField("Summary", text: $summary)
                TextField("Emoji", text: $emoji)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    Task {
                        await model.createAgent(name: name, title: title, summary: summary, emoji: emoji)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct NewGroupView: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var selected = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Group").font(.title2.bold())
            TextField("Group Name", text: $title)
            List(model.agents, selection: $selected) { agent in
                Label("\(agent.emoji) \(agent.name)", systemImage: "person").tag(agent.id)
            }
            .frame(height: 220)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    Task {
                        let ids = model.agents.map(\.id).filter(selected.contains)
                        await model.createGroup(title: title, memberIDs: ids, ownerID: ids.first)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct ProviderSettingsView: View {
    @ObservedObject var model: DesktopViewModel

    var body: some View {
        Form {
            Section("Configured Providers") {
                if model.providerConfigurations.isEmpty {
                    Text("No providers configured").foregroundStyle(.secondary)
                } else {
                    ForEach(model.providerConfigurations, id: \.id) { configuration in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(configuration.displayName)
                                Text("\(configuration.providerType.rawValue) · \(configuration.model.id)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { model.editProvider(configuration) }
                            Button("Test") { Task { await model.testProvider(configuration.id) } }
                                .disabled(model.isProviderTesting)
                        }
                    }
                }
                Button("New Provider Configuration") { model.createProviderConfiguration() }
            }

            Section("Edit Provider Configuration") {
                TextField("Configuration ID", text: $model.providerConfigurationID)
                Picker("Provider Type", selection: Binding(
                    get: { model.providerKind },
                    set: { model.selectProviderKind($0) }
                )) {
                    ForEach(DesktopProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField("Display Name", text: $model.providerDisplayName)
                TextField("Endpoint", text: $model.providerEndpoint)
                TextField("Model", text: $model.providerModel)
                SecureField("API Key", text: $model.providerKey)

                HStack {
                    Button("Save Configuration") { Task { await model.saveProvider() } }
                        .disabled(model.providerConfigurationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(model.isProviderTesting ? "Testing…" : "Test Configuration") {
                        Task { await model.testProvider() }
                    }
                    .disabled(model.isProviderTesting || !model.providerConfigurations.contains(where: { $0.id == model.providerConfigurationID }))
                }

                if !model.providerTestStatus.isEmpty {
                    Text(model.providerTestStatus).font(.caption).textSelection(.enabled)
                }

                if model.providerKind == .openRouter {
                    Button(model.isProviderAuthenticating ? "Signing in…" : "Sign in with OpenRouter") {
                        Task { await model.signInWithOpenRouter() }
                    }
                    .disabled(model.isProviderAuthenticating)
                }

                if model.providerKind == .kimiCode {
                    Button(model.isProviderAuthenticating ? "Waiting for Kimi…" : "Sign in with Kimi Code") {
                        Task { await model.signInWithKimi() }
                    }
                    .disabled(model.isProviderAuthenticating)
                    if let authorization = model.kimiDeviceAuthorization {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Enter this code in the browser:").font(.caption).foregroundStyle(.secondary)
                            Text(authorization.userCode).font(.title3.monospaced().bold()).textSelection(.enabled)
                            HStack {
                                Button("Copy Code") { model.copyKimiUserCode() }
                                Link("Open Kimi", destination: authorization.verificationURL)
                            }
                        }
                    }
                }
            }

            Section("Migration") {
                Button("Import iOS Minis Database…") { model.importLegacyDatabase() }
                Text("The source database is opened read-only. Re-importing is idempotent and never overwrites newer desktop records.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
