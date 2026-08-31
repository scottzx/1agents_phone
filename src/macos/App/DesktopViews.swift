import SwiftUI
import MinisDesktopCore
import UniformTypeIdentifiers

struct DesktopRootView: View {
    @ObservedObject var model: DesktopViewModel
    @State private var showingAgent = false
    @State private var showingGroup = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSessionID) {
                Section("Conversations") {
                    ForEach(model.conversations.filter { $0.kind == .conversation }) { item in
                        conversationRow(item, icon: "message").tag(item.id)
                    }
                }
                Section("Agents") {
                    ForEach(model.agents) { agent in
                        if let session = model.conversations.first(where: { $0.agentID == agent.id && $0.groupID == nil }) {
                            conversationRow(session, icon: "person.crop.circle").tag(session.id)
                        }
                    }
                    Button("New Agent…") { showingAgent = true }
                }
                Section("Groups") {
                    ForEach(model.groups) { group in
                        if let session = model.conversations.first(where: { $0.id == group.sessionID }) {
                            conversationRow(session, icon: "person.3").tag(session.id)
                        }
                    }
                    Button("New Group…") { showingGroup = true }
                }
            }
            .navigationTitle("Minis")
            .onChange(of: model.selectedSessionID) { _, id in if let id { Task { await model.open(id) } } }
            .toolbar { Button { Task { await model.createConversation() } } label: { Image(systemName: "square.and.pencil") } }
        } content: {
            ChatColumn(model: model)
                .navigationTitle(model.selectedConversation?.title ?? "Minis")
        } detail: {
            InspectorColumn(model: model)
        }
        .safeAreaInset(edge: .bottom) {
            HStack { Circle().fill(model.status.contains("error") ? .red : .green).frame(width: 7); Text(model.status).font(.caption).foregroundStyle(.secondary); Spacer() }
                .padding(.horizontal, 12).padding(.vertical, 5).background(.bar)
        }
        .sheet(isPresented: $showingAgent) { NewAgentView(model: model, isPresented: $showingAgent) }
        .sheet(isPresented: $showingGroup) { NewGroupView(model: model, isPresented: $showingGroup) }
        .sheet(item: $model.pendingShellApproval) { approval in
            ShellApprovalView(model: model, approval: approval)
        }
        .sheet(item: $model.pendingWorkspaceDrop) { workspaceDrop in
            WorkspaceDropConfirmation(model: model, workspaceDrop: workspaceDrop)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: acceptDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(10)
                    .allowsHitTesting(false)
                    .overlay {
                        Text("Drop folders to switch workspace; files become visible path context")
                            .padding(10)
                            .background(.regularMaterial, in: Capsule())
                            .allowsHitTesting(false)
                    }
            }
        }
    }

    private func conversationRow(_ item: RuntimeConversation, icon: String) -> some View {
        Label { VStack(alignment: .leading) { Text(item.title); Text(item.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary) } } icon: { Image(systemName: icon) }
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

private struct ChatColumn: View {
    @ObservedObject var model: DesktopViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedConversation == nil {
                ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
            } else {
                ScrollViewReader { proxy in
                    List(model.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            if message.role == .user {
                                Text("You").font(.caption.bold()).foregroundStyle(.secondary)
                            } else {
                                Text(senderName(message)).font(.caption.bold()).foregroundStyle(.tint)
                            }
                            Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5).id(message.id)
                    }
                    .onChange(of: model.messages.count) { _, _ in if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    TextEditor(text: $model.composer).frame(minHeight: 48, maxHeight: 120).font(.body)
                    if model.isRunning {
                        Button("Stop") { Task { await model.cancel() } }.buttonStyle(.bordered)
                    } else {
                        Button { Task { await model.send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain).disabled(!model.canSend)
                    }
                }.padding(12)
                if !model.fileContextURLs.isEmpty {
                    FileContextBar(model: model)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private func senderName(_ message: RuntimeMessageRecord) -> String {
        guard let id = message.senderAgentID else { return "Assistant" }
        return model.agents.first(where: { $0.id == id })?.name ?? "Assistant"
    }
}

private struct InspectorColumn: View {
    @ObservedObject var model: DesktopViewModel

    var body: some View {
        Form {
            Section("Workspace") {
                Text(model.workspacePath).font(.caption).textSelection(.enabled).lineLimit(3)
                HStack {
                    Button("Choose Folder…") { model.selectWorkspace() }
                    Button("Reveal in Finder") { model.revealWorkspaceInFinder() }
                        .disabled(model.workspacePath == "No workspace selected")
                }
            }
            Section("Agent command") {
                Toggle("Allow the Agent to request macOS Shell", isOn: Binding(
                    get: { model.selectedConversation?.agentShellAccess == true },
                    set: { enabled in Task { await model.setAgentShellAccess(enabled) } }
                ))
                .help("Off by default. When enabled, every model-initiated command requires an explicit approval before it runs with your user permissions.")
                TextEditor(text: $model.shellCommand).font(.body.monospaced()).frame(minHeight: 90)
                Button("Run") { Task { await model.runShell() } }.disabled(model.isRunning)
                if !model.shellOutput.isEmpty { ScrollView { Text(model.shellOutput).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 120) }
            }
            Section("Interactive terminal") {
                if model.inspectorTerminalVisible {
                    TerminalPanel(model: model, minimumHeight: 220)
                } else {
                    Button("Show Terminal") { model.showInspectorTerminal() }
                }
            }
            if let conversation = model.selectedConversation {
                Section("Runtime") {
                    LabeledContent("Kind", value: conversation.kind.rawValue)
                    LabeledContent("Session", value: String(conversation.id.prefix(8)))
                    Picker("Provider", selection: Binding(
                        get: { conversation.providerConfigurationID ?? "__default__" },
                        set: { value in Task { await model.bindSelectedSession(to: value == "__default__" ? nil : value) } }
                    )) {
                        Text("Default").tag("__default__")
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
                    LabeledContent("Uploaded", value: String(sync.uploadedCount))
                    LabeledContent("Downloaded", value: String(sync.downloadedCount))
                }
                Button(model.isCloudSyncing ? "Syncing…" : "Sync Now") {
                    Task { await model.synchronizeNow() }
                }
                .disabled(model.isCloudSyncing)
            }
        }.formStyle(.grouped).frame(minWidth: 280)
    }
}

private struct FileContextBar: View {
    @ObservedObject var model: DesktopViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Attached file context — paths only; content has not been read or executed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(model.fileContextURLs, id: \.self) { url in
                        HStack(spacing: 4) {
                            Image(systemName: "doc")
                            Text(url.lastPathComponent).lineLimit(1)
                            Button { model.revealInFinder(url) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.plain)
                                .help("Reveal in Finder")
                            Button { model.removeFileContext(url) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .help("Remove file context")
                        }
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }
}

private struct WorkspaceDropConfirmation: View {
    @ObservedObject var model: DesktopViewModel
    let workspaceDrop: PendingWorkspaceDrop

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Use dropped folder as workspace?", systemImage: "folder.badge.plus")
                .font(.title2.bold())
            Text(workspaceDrop.url.path)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text("Minis will explicitly grant this folder and switch the current conversation to it. No files will be run or read by dropping the folder.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissDroppedWorkspace() }
                Button("Grant and Switch") { Task { await model.confirmDroppedWorkspace() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
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
                    ContentUnavailableView("Terminal closed", systemImage: "rectangle.portrait.and.arrow.right")
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

private struct TerminalPanel: View {
    @ObservedObject var model: DesktopViewModel
    var preferredTabID: UUID?
    var minimumHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.terminalTabs.isEmpty {
                Button("Open Terminal") { Task { await model.openTerminal() } }
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

private struct ShellApprovalView: View {
    @ObservedObject var model: DesktopViewModel
    let approval: ShellApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(approval.isShellCommand ? "Approve macOS Shell command?" : "Approve macOS native action?", systemImage: "exclamationmark.shield")
                .font(.title2.bold())
            Text(approval.isShellCommand
                 ? "\(approval.agentName) requested a command. Shell commands run with your macOS user permissions and can access paths outside the selected workspace."
                 : "\(approval.agentName) requested \(approval.toolName). This action can open external content or modify macOS user data.")
                .foregroundStyle(.secondary)
            GroupBox(approval.isShellCommand ? "Working directory" : "Action type") {
                Text(approval.workingDirectory).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(approval.isShellCommand ? "Command" : "Requested action") {
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

private struct NewAgentView: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var title = ""
    @State private var summary = ""
    @State private var emoji = "🤖"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Agent").font(.title2.bold())
            Form { TextField("Name", text: $name); TextField("Role", text: $title); TextField("Summary", text: $summary); TextField("Emoji", text: $emoji) }
            HStack { Spacer(); Button("Cancel") { isPresented = false }; Button("Create") { Task { await model.createAgent(name: name, title: title, summary: summary, emoji: emoji); isPresented = false } }.keyboardShortcut(.defaultAction).disabled(name.isEmpty) }
        }.padding(24).frame(width: 480)
    }
}

private struct NewGroupView: View {
    @ObservedObject var model: DesktopViewModel
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var selected = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Group").font(.title2.bold())
            TextField("Group name", text: $title)
            List(model.agents, selection: $selected) { agent in Label("\(agent.emoji) \(agent.name)", systemImage: "person").tag(agent.id) }.frame(height: 220)
            HStack { Spacer(); Button("Cancel") { isPresented = false }; Button("Create") { Task { let ids = model.agents.map(\.id).filter(selected.contains); await model.createGroup(title: title, memberIDs: ids, ownerID: ids.first); isPresented = false } }.keyboardShortcut(.defaultAction).disabled(title.isEmpty || selected.isEmpty) }
        }.padding(24).frame(width: 520)
    }
}

struct ProviderSettingsView: View {
    @ObservedObject var model: DesktopViewModel
    var body: some View {
        Form {
            Section("Configured providers") {
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
                Button("New Provider") { model.createProviderConfiguration() }
            }
            Section("Provider configuration") {
                TextField("Configuration ID", text: $model.providerConfigurationID)
                Picker("Provider", selection: Binding(
                    get: { model.providerKind },
                    set: { model.selectProviderKind($0) }
                )) {
                    ForEach(DesktopProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField("Display name", text: $model.providerDisplayName)
                TextField("Endpoint", text: $model.providerEndpoint)
                TextField("Model", text: $model.providerModel)
                SecureField("API key", text: $model.providerKey)
                HStack {
                    Button("Save") { Task { await model.saveProvider() } }
                        .disabled(model.providerConfigurationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(model.isProviderTesting ? "Testing…" : "Test Saved Configuration") {
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
            Text("Each conversation can select a configured provider from its Runtime inspector. API keys remain in Keychain and are never placed in the Agent shell environment.").font(.caption).foregroundStyle(.secondary)
            Section("Migration") {
                Button("Import iOS Minis Database…") { model.importLegacyDatabase() }
                Text("The source database is opened read-only. Re-importing is idempotent and never overwrites newer desktop records.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding()
    }
}
