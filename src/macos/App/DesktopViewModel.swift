import AppKit
import Foundation
import MinisDesktopCore

struct ShellApproval: Identifiable, Equatable {
    let id: String
    let sessionID: String?
    let command: String
    let workingDirectory: String
    let agentName: String
    let toolName: String

    var isShellCommand: Bool { toolName == "shell_execute" }
}

struct PendingWorkspaceDrop: Identifiable {
    let id = UUID()
    let url: URL
}

enum DesktopProviderKind: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case gemini
    case openRouter
    case xAI
    case kimiCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"
        case .xAI: "xAI"
        case .kimiCode: "Kimi Code"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1/chat/completions"
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        case .openRouter: "https://openrouter.ai/api/v1/chat/completions"
        case .xAI: "https://api.x.ai/v1/chat/completions"
        case .kimiCode: "https://api.kimi.com/coding/v1/chat/completions"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-5.1"
        case .anthropic: "claude-sonnet-4-5"
        case .gemini: "gemini-2.5-flash"
        case .openRouter: "openai/gpt-5.1"
        case .xAI: "grok-4.3"
        case .kimiCode: "kimi-k3"
        }
    }
}

@MainActor
final class DesktopViewModel: ObservableObject {
    @Published var conversations: [RuntimeConversation] = []
    @Published var agents: [RuntimeAgentRecord] = []
    @Published var groups: [RuntimeGroupRecord] = []
    @Published var messages: [RuntimeMessageRecord] = []
    @Published var selectedSessionID: String?
    @Published var composer = ""
    @Published var status = "Starting Runtime…"
    @Published var isRunning = false
    @Published var workspacePath = "No workspace selected"
    @Published var shellCommand = "pwd && git status --short"
    @Published var shellOutput = ""
    @Published var providerEndpoint = "https://api.openai.com/v1/chat/completions"
    @Published var providerModel = "gpt-5.1"
    @Published var providerKey = ""
    @Published var providerKind: DesktopProviderKind = .openAI
    @Published var providerConfigurationID = "default"
    @Published var providerDisplayName = "OpenAI"
    @Published var providerConfigurations: [RuntimeProviderConfiguration] = []
    @Published var providerTestStatus = ""
    @Published var isProviderAuthenticating = false
    @Published var isProviderTesting = false
    @Published var kimiDeviceAuthorization: KimiDeviceAuthorization?
    @Published var cloudSyncStatus: DesktopSyncStatus?
    @Published var cloudSyncMessage = "Sync has not run yet"
    @Published var isCloudSyncing = false
    @Published var terminalTabs: [TerminalTabState] = []
    @Published var selectedTerminalTabID: UUID?
    @Published var inspectorTerminalVisible = false
    @Published var pendingShellApproval: ShellApproval?
    @Published var fileContextURLs: [URL] = []
    @Published var pendingWorkspaceDrop: PendingWorkspaceDrop?

    private let client: any RuntimeClient
    private let nativeToolHost = MacNativeToolHost()
    private let openRouterOAuth = OpenRouterOAuthCoordinator()
    private var workspaceID: String?
    private var terminalPollTasks: [UUID: Task<Void, Never>] = [:]
    private var nativeInvocationTasks: [String: Task<Void, Never>] = [:]
    private var runtimeEventTask: Task<Void, Never>?
    private var lastRuntimeSequence = 0
    private var queuedShellApprovals: [ShellApproval] = []
    private var fileContextsBySession: [String: [URL]] = [:]

    init(client: (any RuntimeClient)? = nil) {
        self.client = client ?? DesktopRuntimeConnection.makeClient()
    }

    var selectedConversation: RuntimeConversation? {
        conversations.first { $0.id == selectedSessionID }
    }

    var selectedTerminalTab: TerminalTabState? {
        guard let selectedTerminalTabID else { return nil }
        return terminalTabs.first { $0.id == selectedTerminalTabID }
    }

    var canSend: Bool {
        !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !fileContextURLs.isEmpty
    }

    func start() async {
        do {
            if runtimeEventTask == nil {
                let stream = await client.events()
                runtimeEventTask = Task { [weak self] in
                    for await event in stream { await self?.consumeRuntimeEvent(event) }
                }
            }
            _ = try await client.request(RuntimeRequest(method: "initialize"))
            try await refreshSnapshot()
            await refreshProviders()
            await refreshCloudSyncStatus()
            status = "Runtime ready"
            if selectedSessionID == nil, let first = conversations.first { await open(first.id) }
        } catch { status = error.localizedDescription }
    }

    func shutdown() async {
        runtimeEventTask?.cancel()
        runtimeEventTask = nil
        nativeInvocationTasks.values.forEach { $0.cancel() }
        nativeInvocationTasks.removeAll()
        let terminalTabIDs = terminalTabs.map(\.id)
        for terminalTabID in terminalTabIDs { await closeTerminal(terminalTabID) }
        await client.shutdown()
    }

    private func consumeRuntimeEvent(_ event: RuntimeEvent) async {
        let sequence = event.sequence
        if sequence > 0 {
            if lastRuntimeSequence > 0, sequence > lastRuntimeSequence + 1 {
                try? await refreshSnapshot()
                if let selectedSessionID { await open(selectedSessionID) }
            }
            lastRuntimeSequence = max(lastRuntimeSequence, sequence)
        }
        if event.name == "native.invoke" {
            beginNativeInvocation(event)
            return
        }
        if event.name == "approval.requested", case .object(let object)? = event.payload,
           let approvalID = object.string("approvalId"), let command = object.string("command"), let cwd = object.string("cwd") {
            let agentName = object.string("agentId").flatMap { id in agents.first(where: { $0.id == id })?.name } ?? "Agent"
            let toolName = object.string("tool") ?? "shell_execute"
            let approval = ShellApproval(id: approvalID, sessionID: event.sessionID, command: command, workingDirectory: cwd, agentName: agentName, toolName: toolName)
            enqueueShellApproval(approval)
            status = approval.isShellCommand ? "Waiting for Shell approval" : "Waiting for native action approval"
            return
        }
        if event.name == "approval.resolved", case .object(let object)? = event.payload,
           object.string("approvalId") == pendingShellApproval?.id {
            pendingShellApproval = nil
            showNextShellApproval()
        }
        guard event.sessionID == nil || event.sessionID == selectedSessionID else { return }
        switch event.name {
        case "message.started":
            if let payload = event.payload, let record = try? payload.decoded(RuntimeMessageRecord.self), !messages.contains(where: { $0.id == record.id }) {
                messages.append(record)
            }
        case "message.completed":
            if let payload = event.payload, let record = try? payload.decoded(RuntimeMessageRecord.self), !messages.contains(where: { $0.id == record.id }) {
                messages.append(record)
            }
            status = "Completed"
        case "message.delta":
            if case .object(let object)? = event.payload, let text = object.string("text") {
                status = "Receiving response… \(text.count) characters"
            }
        case "tool.started":
            if case .object(let object)? = event.payload { status = "Running \(object.string("tool") ?? "tool")…" }
        case "tool.output":
            if case .object(let object)? = event.payload, let output = object.string("output") {
                shellOutput = output
            }
        case "group.memberStarted":
            if case .object(let object)? = event.payload, let id = object.string("agentId") {
                status = "\(agents.first(where: { $0.id == id })?.name ?? "Group member") is responding…"
            }
        case "group.completed":
            status = "Completed"
        case "sync.completed", "sync.status":
            if let payload = event.payload, let value = try? payload.decoded(DesktopSyncStatus.self) {
                applyCloudSyncStatus(value)
            }
        case "runtime.error", "runtime.fatal":
            status = event.error ?? "Runtime error"
        default:
            break
        }
    }

    /// Native requests may originate from a non-selected agent/session. Start
    /// their AppKit work in a separate task so the event stream keeps draining
    /// while a notification permission prompt or system launch is in flight.
    private func beginNativeInvocation(_ event: RuntimeEvent) {
        guard case .object(let object)? = event.payload,
              let invocationID = object.string("invocationId"),
              let name = object.string("name") else {
            return
        }
        let arguments = object["arguments"] ?? .object([:])
        nativeInvocationTasks[invocationID]?.cancel()
        nativeInvocationTasks[invocationID] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.nativeToolHost.invoke(name: name, arguments: arguments)
            var payload: [String: JSONValue] = ["invocationId": .string(invocationID)]
            switch outcome {
            case .success(let result):
                payload["result"] = result
            case .failure(let error):
                payload["error"] = .string(error)
            }
            do {
                _ = try await self.client.request(RuntimeRequest(
                    method: "native.resolve",
                    sessionID: event.sessionID,
                    payload: .object(payload)
                ))
            } catch {
                // A background session can disappear before its resolve is
                // delivered. Do not turn that into a foreground UI failure.
            }
            self.nativeInvocationTasks.removeValue(forKey: invocationID)
        }
    }

    func refreshSnapshot() async throws {
        let events = try await client.request(RuntimeRequest(method: "runtime.snapshot"))
        guard let payload = events.last(where: { $0.name == "runtime.snapshot" })?.payload else { return }
        let snapshot = try payload.decoded(RuntimeSnapshot.self)
        conversations = snapshot.conversations
        agents = snapshot.agents
        groups = snapshot.groups
    }

    func refreshCloudSyncStatus() async {
        do {
            let events = try await client.request(RuntimeRequest(method: "sync.status"))
            if let payload = events.last(where: { $0.name == "sync.status" })?.payload {
                applyCloudSyncStatus(try payload.decoded(DesktopSyncStatus.self))
            }
        } catch {
            cloudSyncMessage = error.localizedDescription
        }
    }

    func synchronizeNow() async {
        guard !isCloudSyncing else { return }
        isCloudSyncing = true
        cloudSyncMessage = "Syncing…"
        defer { isCloudSyncing = false }
        do {
            let events = try await client.request(RuntimeRequest(method: "sync.now"))
            guard let payload = events.last(where: { $0.name == "sync.completed" })?.payload else {
                throw CocoaError(.coderValueNotFound)
            }
            applyCloudSyncStatus(try payload.decoded(DesktopSyncStatus.self))
        } catch {
            cloudSyncMessage = error.localizedDescription
        }
    }

    private func applyCloudSyncStatus(_ value: DesktopSyncStatus) {
        cloudSyncStatus = value
        if let error = value.lastError, !error.isEmpty {
            cloudSyncMessage = error
        } else if let date = value.lastCompletedAt {
            cloudSyncMessage = "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
        } else {
            cloudSyncMessage = "Ready to sync when this helper is signed for iCloud"
        }
    }

    func open(_ sessionID: String) async {
        selectedSessionID = sessionID
        fileContextURLs = fileContextsBySession[sessionID] ?? []
        do {
            let events = try await client.request(RuntimeRequest(method: "session.open", sessionID: sessionID))
            guard case .object(let object)? = events.last?.payload, let value = object["messages"] else { return }
            messages = try value.decoded([RuntimeMessageRecord].self)
            await restoreWorkspaceSelection()
            status = "Runtime ready"
        } catch { status = error.localizedDescription }
    }

    func createConversation() async {
        do {
            let events = try await client.request(RuntimeRequest(method: "session.create", payload: .object(["title": .string("New conversation")])))
            try await refreshSnapshot()
            if let id = events.last?.sessionID { await open(id) }
        } catch { status = error.localizedDescription }
    }

    func createAgent(name: String, title: String, summary: String, emoji: String) async {
        do {
            let agent = RuntimeAgentRecord(name: name, emoji: emoji.isEmpty ? "🤖" : emoji, title: title, summary: summary)
            _ = try await client.request(RuntimeRequest(method: "agent.create", payload: try .encoded(agent)))
            let events = try await client.request(RuntimeRequest(method: "agent.openMainSession", payload: .object(["agentId": .string(agent.id)])))
            try await refreshSnapshot()
            if let id = events.last?.sessionID { await open(id) }
        } catch { status = error.localizedDescription }
    }

    func createGroup(title: String, memberIDs: [String], ownerID: String?) async {
        guard !memberIDs.isEmpty else { status = "Choose at least one agent."; return }
        do {
            let group = RuntimeGroupRecord(sessionID: UUID().uuidString, title: title, memberIDs: memberIDs, ownerAgentID: ownerID)
            _ = try await client.request(RuntimeRequest(method: "group.create", payload: try .encoded(group)))
            try await refreshSnapshot()
            await open(group.sessionID)
        } catch { status = error.localizedDescription }
    }

    func send() async {
        guard let conversation = selectedConversation else { return }
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        let contexts = fileContextURLs
        guard !text.isEmpty || !contexts.isEmpty else { return }
        let contextText = FileContextFormatter.message(for: contexts)
        let outboundText = [contextText, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        composer = ""
        fileContextURLs = []
        fileContextsBySession[conversation.id] = []
        isRunning = true
        status = conversation.kind == .group ? "Group members are speaking…" : "Thinking…"
        let method = conversation.kind == .group ? "group.send" : "session.send"
        var payload: [String: JSONValue] = ["text": .string(outboundText)]
        if let groupID = conversation.groupID { payload["groupId"] = .string(groupID) }
        do {
            _ = try await client.request(RuntimeRequest(method: method, sessionID: conversation.id, payload: .object(payload)))
            await open(conversation.id)
            try await refreshSnapshot()
        } catch { status = error.localizedDescription }
        isRunning = false
    }

    func cancel() async {
        guard let id = selectedSessionID else { return }
        do { _ = try await client.request(RuntimeRequest(method: "session.cancel", sessionID: id)); status = "Cancelled" }
        catch { status = error.localizedDescription }
        isRunning = false
    }

    func selectWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await grantWorkspace(at: url) }
    }

    func receiveDroppedURLs(_ urls: [URL]) {
        let folders = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let files = urls.filter { !folders.contains($0) }
        if !files.isEmpty { addFileContexts(files) }
        if let folder = folders.first {
            pendingWorkspaceDrop = PendingWorkspaceDrop(url: folder)
        }
    }

    func confirmDroppedWorkspace() async {
        guard let workspace = pendingWorkspaceDrop?.url else { return }
        pendingWorkspaceDrop = nil
        await grantWorkspace(at: workspace)
    }

    func dismissDroppedWorkspace() {
        pendingWorkspaceDrop = nil
    }

    func removeFileContext(_ url: URL) {
        fileContextURLs.removeAll { $0 == url }
        if let selectedSessionID { fileContextsBySession[selectedSessionID] = fileContextURLs }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealWorkspaceInFinder() {
        guard workspacePath != "No workspace selected" else { return }
        revealInFinder(URL(fileURLWithPath: workspacePath))
    }

    private func addFileContexts(_ urls: [URL]) {
        guard let sessionID = selectedSessionID else {
            status = "Choose a conversation before adding file context."
            return
        }
        for url in urls where !fileContextURLs.contains(url) { fileContextURLs.append(url) }
        fileContextsBySession[sessionID] = fileContextURLs
        status = "Added \(urls.count) file path\(urls.count == 1 ? "" : "s") as visible context"
    }

    private func grantWorkspace(at url: URL) async {
        do {
            let events = try await client.request(RuntimeRequest(method: "workspace.grant", payload: .object(["path": .string(url.path)])))
            guard case .object(let object)? = events.last?.payload, case .string(let id)? = object["workspaceID"] else { return }
            workspaceID = id
            workspacePath = url.path
            if let sessionID = selectedSessionID {
                _ = try await client.request(RuntimeRequest(method: "workspace.setSessionWorkspace", sessionID: sessionID, payload: .object(["workspaceId": .string(id)])))
                try await refreshSnapshot()
            }
            status = "Workspace set to \(url.lastPathComponent)"
        } catch { status = error.localizedDescription }
    }

    private func restoreWorkspaceSelection() async {
        guard let id = selectedConversation?.workspaceID else {
            workspaceID = nil
            workspacePath = "No workspace selected"
            return
        }
        do {
            let events = try await client.request(RuntimeRequest(method: "workspace.list"))
            guard let payload = events.last?.payload else { return }
            let values = try payload.decoded([String: String].self)
            if let path = values[id] {
                workspaceID = id
                workspacePath = path
            }
        } catch { status = error.localizedDescription }
    }

    func runShell() async {
        guard let workspaceID else { status = "Choose a workspace first."; return }
        isRunning = true
        do {
            let events = try await client.request(RuntimeRequest(method: "shell.execute", sessionID: selectedSessionID, payload: .object(["command": .string(shellCommand), "workspaceID": .string(workspaceID), "timeoutSeconds": .int(120)])))
            if case .object(let object)? = events.last?.payload {
                let stdout = object.string("stdout") ?? ""
                let stderr = object.string("stderr") ?? ""
                shellOutput = stdout + (stderr.isEmpty ? "" : "\n[stderr]\n" + stderr)
            }
        } catch { shellOutput = error.localizedDescription }
        isRunning = false
    }

    func setAgentShellAccess(_ enabled: Bool) async {
        guard let sessionID = selectedSessionID else { return }
        do {
            _ = try await client.request(RuntimeRequest(method: "session.setShellAccess", sessionID: sessionID, payload: .object(["enabled": .bool(enabled)])))
            try await refreshSnapshot()
            status = enabled ? "Agent Shell access enabled for this session" : "Agent Shell access disabled"
        } catch { status = error.localizedDescription }
    }

    func resolveShellApproval(_ approval: ShellApproval, approved: Bool) async {
        guard pendingShellApproval?.id == approval.id else { return }
        pendingShellApproval = nil
        showNextShellApproval()
        do {
            _ = try await client.request(RuntimeRequest(
                method: approved ? "tool.approve" : "tool.deny",
                sessionID: approval.sessionID,
                payload: .object(["approvalId": .string(approval.id)])
            ))
            let label = approval.isShellCommand ? "Shell command" : "Native action"
            status = approved ? "\(label) approved" : "\(label) denied"
        } catch {
            status = error.localizedDescription
        }
    }

    private func enqueueShellApproval(_ approval: ShellApproval) {
        guard pendingShellApproval == nil else {
            if !queuedShellApprovals.contains(where: { $0.id == approval.id }) { queuedShellApprovals.append(approval) }
            return
        }
        pendingShellApproval = approval
    }

    private func showNextShellApproval() {
        guard pendingShellApproval == nil, !queuedShellApprovals.isEmpty else { return }
        pendingShellApproval = queuedShellApprovals.removeFirst()
    }

    func saveProvider(credentialType: String = "apiKey") async {
        guard let endpoint = URL(string: providerEndpoint) else { status = "Invalid provider URL."; return }
        let configurationID = providerConfigurationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configurationID.isEmpty else { status = "Provider configuration ID cannot be empty."; return }
        do {
            let configuration: JSONValue = .object([
                "id": .string(configurationID),
                "displayName": .string(providerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? providerKind.displayName : providerDisplayName),
                "endpoint": .string(endpoint.absoluteString),
                "model": .object([
                    "id": .string(providerModel),
                    "displayName": .string(providerModel),
                    "provider": .string(providerKind.displayName),
                ]),
                "additionalHeaders": .object([:]),
                "providerType": .string(providerKind.rawValue),
                "credentialType": .string(credentialType),
            ])
            var payload: [String: JSONValue] = ["configuration": configuration]
            if !providerKey.isEmpty { payload["apiKey"] = .string(providerKey) }
            _ = try await client.request(RuntimeRequest(method: "provider.configure", payload: .object(payload)))
            providerKey = ""
            await refreshProviders()
            status = "Provider saved in Keychain"
        } catch { status = error.localizedDescription }
    }

    func refreshProviders() async {
        do {
            let events = try await client.request(RuntimeRequest(method: "provider.list"))
            guard let payload = events.last(where: { $0.name == "provider.list" })?.payload else { return }
            providerConfigurations = try payload.decoded([RuntimeProviderConfiguration].self)
        } catch {
            status = error.localizedDescription
        }
    }

    func editProvider(_ configuration: RuntimeProviderConfiguration) {
        providerConfigurationID = configuration.id
        providerDisplayName = configuration.displayName
        providerEndpoint = configuration.endpoint.absoluteString
        providerModel = configuration.model.id
        providerKind = DesktopProviderKind(rawValue: configuration.providerType.rawValue) ?? .openAI
        providerKey = ""
        providerTestStatus = ""
    }

    func createProviderConfiguration() {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        providerConfigurationID = "provider-\(suffix)"
        selectProviderKind(.openAI)
        providerKey = ""
        providerTestStatus = ""
    }

    func testProvider(_ providerID: String? = nil) async {
        let resolvedID = providerID ?? providerConfigurationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedID.isEmpty else { return }
        isProviderTesting = true
        defer { isProviderTesting = false }
        do {
            let events = try await client.request(RuntimeRequest(
                method: "provider.test",
                payload: .object(["providerId": .string(resolvedID)])
            ))
            guard let payload = events.last(where: { $0.name == "provider.tested" })?.payload else { return }
            let result = try payload.decoded(RuntimeProviderTestResult.self)
            if result.success {
                providerTestStatus = "Connected in \(result.elapsedMilliseconds) ms"
                status = "Provider connection succeeded"
            } else {
                providerTestStatus = result.error ?? "Provider connection failed"
                status = providerTestStatus
            }
        } catch {
            providerTestStatus = error.localizedDescription
            status = error.localizedDescription
        }
    }

    func bindSelectedSession(to providerID: String?) async {
        guard let sessionID = selectedSessionID else { return }
        do {
            _ = try await client.request(RuntimeRequest(
                method: "provider.setSessionBinding",
                sessionID: sessionID,
                payload: .object(["providerId": providerID.map(JSONValue.string) ?? .null])
            ))
            try await refreshSnapshot()
            status = providerID.flatMap { id in providerConfigurations.first(where: { $0.id == id })?.displayName }
                .map { "Session now uses \($0)" } ?? "Session now follows the default provider"
        } catch {
            status = error.localizedDescription
        }
    }

    func selectProviderKind(_ kind: DesktopProviderKind) {
        providerKind = kind
        providerDisplayName = kind.displayName
        providerEndpoint = kind.defaultEndpoint
        providerModel = kind.defaultModel
    }

    func signInWithOpenRouter() async {
        guard !isProviderAuthenticating else { return }
        isProviderAuthenticating = true
        defer { isProviderAuthenticating = false }
        do {
            selectProviderKind(.openRouter)
            providerKey = try await openRouterOAuth.signIn()
            await saveProvider()
            status = "OpenRouter sign-in complete"
        } catch {
            providerKey = ""
            status = error.localizedDescription
        }
    }

    func signInWithKimi() async {
        guard !isProviderAuthenticating else { return }
        isProviderAuthenticating = true
        defer {
            isProviderAuthenticating = false
            kimiDeviceAuthorization = nil
        }
        do {
            selectProviderKind(.kimiCode)
            if providerConfigurationID == "default" {
                providerConfigurationID = "kimi-code"
            }
            await saveProvider(credentialType: "oauth")
            guard providerConfigurations.contains(where: { $0.id == providerConfigurationID && $0.credentialType == .oauth }) else {
                throw KimiOAuthError.invalidResponse("Could not save the Kimi OAuth configuration.")
            }
            let startEvents = try await client.request(RuntimeRequest(
                method: "provider.kimiDeviceStart",
                payload: .object(["providerId": .string(providerConfigurationID)])
            ))
            guard let payload = startEvents.last(where: { $0.name == "provider.kimiDeviceCode" })?.payload else {
                throw KimiOAuthError.invalidResponse("Kimi did not return a device code.")
            }
            let authorization = try payload.decoded(KimiDeviceAuthorization.self)
            kimiDeviceAuthorization = authorization
            NSWorkspace.shared.open(authorization.verificationURL)
            _ = try await client.request(RuntimeRequest(
                method: "provider.kimiDeviceComplete",
                payload: .object([
                    "providerId": .string(providerConfigurationID),
                    "authorization": try .encoded(authorization),
                ])
            ))
            await refreshProviders()
            providerTestStatus = "Kimi sign-in complete"
            status = "Kimi Code sign-in complete"
        } catch {
            providerTestStatus = error.localizedDescription
            status = error.localizedDescription
        }
    }

    func copyKimiUserCode() {
        guard let code = kimiDeviceAuthorization?.userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    func importLegacyDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let events = try await client.request(RuntimeRequest(method: "persistence.importLegacy", payload: .object(["path": .string(url.path)])))
                guard let payload = events.last?.payload else { return }
                let result = try payload.decoded(LegacyChatStoreImportResult.self)
                try await refreshSnapshot()
                status = "Imported \(result.conversations) sessions and \(result.messages) messages"
            } catch { status = error.localizedDescription }
        }
    }

    func toggleInspectorTerminal() {
        inspectorTerminalVisible.toggle()
        if inspectorTerminalVisible, terminalTabs.isEmpty {
            Task { await openTerminal() }
        }
    }

    func showInspectorTerminal() {
        inspectorTerminalVisible = true
        if terminalTabs.isEmpty { Task { await openTerminal() } }
    }

    @discardableResult
    func openTerminal(showInInspector: Bool = true) async -> UUID? {
        guard let workspaceID else { status = "Choose a workspace first."; return nil }
        let columns = 100
        let rows = 30
        do {
            let events = try await client.request(RuntimeRequest(
                method: "terminal.create",
                sessionID: selectedSessionID,
                payload: .object([
                    "workspaceId": .string(workspaceID),
                    "columns": .int(columns),
                    "rows": .int(rows),
                ])
            ))
            guard case .object(let object)? = events.last?.payload,
                  let raw = object.string("terminalId"),
                  let terminalID = UUID(uuidString: raw) else { return nil }
            let tab = TerminalTabState(
                terminalID: terminalID,
                workspaceID: workspaceID,
                sessionID: selectedSessionID,
                title: "Terminal \(terminalTabs.count + 1)",
                columns: columns,
                rows: rows
            )
            terminalTabs.append(tab)
            selectedTerminalTabID = tab.id
            if showInInspector { inspectorTerminalVisible = true }
            startTerminalPoll(tab.id)
            return tab.id
        } catch {
            status = error.localizedDescription
            return nil
        }
    }

    func focusTerminal(_ tabID: UUID) {
        guard terminalTabs.contains(where: { $0.id == tabID }) else { return }
        selectedTerminalTabID = tabID
    }

    func terminalInput(for tabID: UUID) -> String {
        terminalTabs.first(where: { $0.id == tabID })?.input ?? ""
    }

    func setTerminalInput(_ input: String, for tabID: UUID) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == tabID }) else { return }
        terminalTabs[index].input = input
    }

    func submitTerminalInput(tabID: UUID? = nil) async {
        let tabID = tabID ?? selectedTerminalTabID
        guard let tabID, let index = terminalTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let data = Data((terminalTabs[index].input + "\n").utf8)
        terminalTabs[index].input = ""
        do {
            _ = try await client.request(RuntimeRequest(method: "terminal.input", payload: .object([
                "terminalId": .string(terminalTabs[index].terminalID.uuidString),
                "base64": .string(data.base64EncodedString()),
            ])))
        } catch { status = error.localizedDescription }
    }

    func interruptTerminal(tabID: UUID? = nil) async {
        let tabID = tabID ?? selectedTerminalTabID
        guard let tabID, let tab = terminalTabs.first(where: { $0.id == tabID }), tab.isRunning else { return }
        _ = try? await client.request(RuntimeRequest(method: "terminal.signal", payload: .object([
            "terminalId": .string(tab.terminalID.uuidString),
            "signal": .int(2),
        ])))
    }

    func resizeTerminal(_ tabID: UUID, columns: Int, rows: Int) async {
        guard let index = terminalTabs.firstIndex(where: { $0.id == tabID }),
              terminalTabs[index].isRunning,
              terminalTabs[index].columns != columns || terminalTabs[index].rows != rows else { return }
        terminalTabs[index].columns = columns
        terminalTabs[index].rows = rows
        _ = try? await client.request(RuntimeRequest(method: "terminal.resize", payload: .object([
            "terminalId": .string(terminalTabs[index].terminalID.uuidString),
            "columns": .int(columns),
            "rows": .int(rows),
        ])))
    }

    func clearTerminal(_ tabID: UUID? = nil) {
        let tabID = tabID ?? selectedTerminalTabID
        guard let tabID, let index = terminalTabs.firstIndex(where: { $0.id == tabID }) else { return }
        terminalTabs[index].clearOutput()
    }

    func closeSelectedTerminal() async {
        guard let selectedTerminalTabID else { return }
        await closeTerminal(selectedTerminalTabID)
    }

    func closeTerminal(_ tabID: UUID) async {
        guard let index = terminalTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = terminalTabs[index]
        terminalPollTasks.removeValue(forKey: tabID)?.cancel()
        if tab.isRunning {
            _ = try? await client.request(RuntimeRequest(method: "terminal.close", payload: .object([
                "terminalId": .string(tab.terminalID.uuidString),
            ])))
        }
        terminalTabs.remove(at: index)
        if selectedTerminalTabID == tabID { selectedTerminalTabID = terminalTabs.last?.id }
    }

    private func startTerminalPoll(_ tabID: UUID) {
        terminalPollTasks.removeValue(forKey: tabID)?.cancel()
        terminalPollTasks[tabID] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readTerminal(tabID)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func readTerminal(_ tabID: UUID) async {
        guard let index = terminalTabs.firstIndex(where: { $0.id == tabID }), terminalTabs[index].isRunning else { return }
        let terminalID = terminalTabs[index].terminalID
        do {
            let events = try await client.request(RuntimeRequest(method: "terminal.read", payload: .object([
                "terminalId": .string(terminalID.uuidString),
            ])))
            guard let payload = events.last?.payload else { return }
            for event in try payload.decoded([RuntimeTerminalEventRecord].self) {
                guard let currentIndex = terminalTabs.firstIndex(where: { $0.id == tabID }) else { return }
                if event.kind == .output, let raw = event.base64Data, let data = Data(base64Encoded: raw) {
                    terminalTabs[currentIndex].appendOutput(String(decoding: data, as: UTF8.self))
                } else if event.kind == .exited {
                    terminalTabs[currentIndex].appendOutput("\n[process exited \(event.exitCode ?? -1)]\n")
                    terminalTabs[currentIndex].isRunning = false
                    terminalPollTasks.removeValue(forKey: tabID)?.cancel()
                }
            }
        } catch {
            status = error.localizedDescription
            terminalPollTasks.removeValue(forKey: tabID)?.cancel()
        }
    }
}

private enum DesktopRuntimeConnection {
    static func makeClient() -> any RuntimeClient {
        let environment = ProcessInfo.processInfo.environment
        let explicit = environment["MINIS_RUNTIME_EXECUTABLE"].map(URL.init(fileURLWithPath:))
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MinisRuntimeService")
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MinisRuntimeService")
        let candidates = [explicit, embedded, sibling].compactMap { $0 }
        if let helper = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return StdioRuntimeClient(executableURL: helper)
        }
        #if DEBUG
        let store = try? DesktopStore()
        return DirectRuntimeClient(runtime: AgentRuntime(store: store))
        #else
        return UnavailableRuntimeClient(error: .helperNotFound(embedded))
        #endif
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { if case .string(let value) = self[key] { value } else { nil } }
}
