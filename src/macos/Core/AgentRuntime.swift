import Foundation
import MinisAppleDomain
import Darwin
import MinisProviderDomain

/// `AgentRunEngine` invokes Sendable dependency closures while this actor is
/// re-entrant. Keep the request's emitted Runtime events in a tiny locked
/// collector so the synchronous Runtime protocol can still return the complete
/// ordered batch once the shared engine finishes.
private final class RuntimeRunEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RuntimeEvent] = []

    func append(_ event: RuntimeEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func values() -> [RuntimeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public enum RuntimeState: String, Codable, Sendable {
    case idle, queued, thinking, runningTool, waitingApproval, speakingInGroup, completed, failed, cancelled
}

public struct RuntimeCapabilities: Codable, Sendable, Equatable {
    public let operatingSystem: String
    public let shell: String
    public let workspaceSupport: Bool
    public let interactiveTerminalSupport: Bool
    public let persistenceSupport: Bool
    public let providerSupport: Bool

    public init(operatingSystem: String = "macos-host", shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", workspaceSupport: Bool = true, interactiveTerminalSupport: Bool = true, persistenceSupport: Bool = true, providerSupport: Bool = true) {
        self.operatingSystem = operatingSystem
        self.shell = shell
        self.workspaceSupport = workspaceSupport
        self.interactiveTerminalSupport = interactiveTerminalSupport
        self.persistenceSupport = persistenceSupport
        self.providerSupport = providerSupport
    }
}

/// UI-free desktop runtime. The same actor serves the direct transport in
/// tests and the multiplexed stdio helper in the shipping architecture.
public actor AgentRuntime {
    private struct PendingApproval {
        let sessionID: String
        let category: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private enum NativeInvocationOutcome: Sendable {
        case success(JSONValue)
        case failure(String)
    }

    private struct PendingNativeInvocation {
        let sessionID: String
        let toolName: String
        let continuation: CheckedContinuation<NativeInvocationOutcome, Never>
    }

    private let workspaces: WorkspaceRegistry
    private let shell: MacCommandExecutionBackend
    private let store: DesktopStore?
    private let credentials: any CredentialStore
    private let kimiOAuth: KimiOAuthManager
    private let provider: any ProviderRunner
    private let terminal: any TerminalBackend
    private let syncCoordinator: DesktopSyncCoordinator?
    private var terminalCaptures: [UUID: TerminalCapture] = [:]
    private var sequence = 0
    private var states: [String: RuntimeState] = [:]
    private var busySessions = Set<String>()
    private var didRestoreWorkspaces = false
    private var requestEventSinks: [UUID: @Sendable (RuntimeEvent) -> Void] = [:]
    private var eventSubscribers: [UUID: AsyncStream<RuntimeEvent>.Continuation] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var pendingNativeInvocations: [String: PendingNativeInvocation] = [:]

    public init(store: DesktopStore? = nil, workspaces: WorkspaceRegistry = WorkspaceRegistry(), shell: MacCommandExecutionBackend = MacCommandExecutionBackend(), credentials: (any CredentialStore)? = nil, provider: (any ProviderRunner)? = nil, terminal: (any TerminalBackend)? = nil) {
        let credentialStore = credentials ?? KeychainCredentialStore()
        self.store = store
        self.workspaces = workspaces
        self.shell = shell
        self.credentials = credentialStore
        self.kimiOAuth = KimiOAuthManager(credentials: credentialStore)
        self.provider = provider ?? OpenAICompatibleProviderRunner(credentials: credentialStore)
        self.terminal = terminal ?? MacTerminalBackend()
        self.syncCoordinator = store.map { DesktopSyncCoordinator(repository: $0, transport: MacCloudKitSyncTransport()) }
    }

    public func installEventSink(for requestID: UUID, sink: @escaping @Sendable (RuntimeEvent) -> Void) {
        requestEventSinks[requestID] = sink
    }

    public func removeEventSink(for requestID: UUID) {
        requestEventSinks.removeValue(forKey: requestID)
    }

    public func events() -> AsyncStream<RuntimeEvent> {
        let id = UUID()
        let pair = AsyncStream<RuntimeEvent>.makeStream(bufferingPolicy: .bufferingNewest(4_096))
        eventSubscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return pair.stream
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventSubscribers.removeValue(forKey: id)
    }

    public func handle(_ request: RuntimeRequest) async -> [RuntimeEvent] {
        guard request.protocolVersion == MinisRuntimeProtocol.version else {
            return [event(for: request, name: "runtime.error", error: "Unsupported protocol version \(request.protocolVersion).")]
        }
        let exclusiveSessionID: String? = ["session.send", "group.send"].contains(request.method) ? request.sessionID : nil
        if let exclusiveSessionID {
            guard !busySessions.contains(exclusiveSessionID) else {
                return [event(for: request, name: "runtime.error", error: "This session already has an active run.")]
            }
            busySessions.insert(exclusiveSessionID)
        }
        defer {
            if let exclusiveSessionID { busySessions.remove(exclusiveSessionID) }
        }
        do {
            switch request.method {
            case "initialize": return try await initialize(request)
            case "capabilities": return [readyEvent(for: request)]
            case "shutdown": return await shutdown(request)
            case "runtime.snapshot", "snapshot": return try await snapshot(request)
            case "session.list": return try await sessionList(request)
            case "session.create": return try await sessionCreate(request)
            case "session.open": return try await sessionOpen(request)
            case "session.delete": return try await sessionDelete(request)
            case "session.send": return try await sessionSend(request)
            case "session.cancel", "group.cancel", "tool.cancel": return cancel(request)
            case "tool.approve": return await approvalDecision(request, approved: true)
            case "tool.deny": return await approvalDecision(request, approved: false)
            case "audit.list": return try await auditList(request)
            case "native.capabilities": return [event(for: request, name: "native.capabilities", payload: try .encoded(NativeToolCatalog.capabilities))]
            case "native.resolve": return await nativeInvocationDecision(request)
            case "session.setShellAccess": return try await sessionSetShellAccess(request)
            case "agent.list": return try await agentList(request)
            case "agent.create", "agent.update": return try await agentUpsert(request)
            case "agent.archive": return try await agentArchive(request)
            case "agent.openMainSession": return try await agentOpenMainSession(request)
            case "group.list": return try await groupList(request)
            case "group.create", "group.update": return try await groupUpsert(request)
            case "group.send": return try await groupSend(request)
            case "group.openMemberSession": return try await groupOpenMemberSession(request)
            case "provider.list": return try await providerList(request)
            case "provider.configure": return try await providerConfigure(request)
            case "provider.test": return try await providerTest(request)
            case "provider.setSessionBinding": return try await providerSetSessionBinding(request)
            case "provider.kimiDeviceStart": return try await providerKimiDeviceStart(request)
            case "provider.kimiDeviceComplete": return try await providerKimiDeviceComplete(request)
            case "provider.kimiSignOut": return try await providerKimiSignOut(request)
            case "sync.now": return try await syncNow(request)
            case "sync.status": return await syncStatus(request)
            case "persistence.importLegacy": return try await importLegacyStore(request)
            case "workspace.grant": return try await workspaceGrant(request)
            case "workspace.list": return await workspaceList(request)
            case "workspace.revoke": return await workspaceRevoke(request)
            case "workspace.setSessionWorkspace": return try await workspaceSetSession(request)
            case "shell.execute": return await executeShell(request)
            case "terminal.create": return try await terminalCreate(request)
            case "terminal.read": return try await terminalRead(request)
            case "terminal.input": return try await terminalInput(request)
            case "terminal.resize": return try await terminalResize(request)
            case "terminal.signal": return try await terminalSignal(request)
            case "terminal.close": return try await terminalClose(request)
            default: return [event(for: request, name: "runtime.error", error: "Unknown method: \(request.method)")]
            }
        } catch is CancellationError {
            if let sessionID = request.sessionID { states[sessionID] = .cancelled }
            return [event(for: request, name: "session.updated", payload: .object(["state": .string(RuntimeState.cancelled.rawValue)]), error: "Cancelled")]
        } catch {
            if let sessionID = request.sessionID { states[sessionID] = .failed }
            return [event(for: request, name: "runtime.error", error: error.localizedDescription)]
        }
    }

    private func readyEvent(for request: RuntimeRequest) -> RuntimeEvent {
        let capabilities = RuntimeCapabilities(persistenceSupport: store != nil)
        return event(for: request, name: "runtime.ready", payload: try? .encoded(capabilities))
    }

    private func initialize(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        if !didRestoreWorkspaces, let store {
            let saved: [String: String] = try await store.metadata([String: String].self, for: "workspace.grants") ?? [:]
            for (id, path) in saved { _ = try? await workspaces.grant(URL(fileURLWithPath: path), id: id) }
            didRestoreWorkspaces = true
        }
        if MacCloudKitSyncTransport.hasRequiredEntitlement(), let syncCoordinator {
            Task { try? await syncCoordinator.start() }
        }
        return [readyEvent(for: request)]
    }

    private func shutdown(_ request: RuntimeRequest) async -> [RuntimeEvent] {
        resolveAllApprovals(approved: false)
        resolveAllNativeInvocations(error: "Runtime is shutting down.")
        await shell.cancelAll()
        for id in terminalCaptures.keys { await terminal.close(sessionID: id) }
        terminalCaptures.removeAll()
        await syncCoordinator?.stop()
        states = states.mapValues { _ in .cancelled }
        return [event(for: request, name: "runtime.shutdown")]
    }

    private func cancel(_ request: RuntimeRequest) -> [RuntimeEvent] {
        if let sessionID = request.sessionID {
            states[sessionID] = .cancelled
            resolveApprovals(for: sessionID, approved: false)
            resolveNativeInvocations(for: sessionID, error: "Cancelled")
        }
        return [event(for: request, name: "session.updated", payload: .object(["state": .string(RuntimeState.cancelled.rawValue)]))]
    }

    private func approvalDecision(_ request: RuntimeRequest, approved: Bool) async -> [RuntimeEvent] {
        guard let approvalID = request.objectPayload.string("approvalId") else {
            return [event(for: request, name: "runtime.error", error: "tool.approve/tool.deny requires payload.approvalId.")]
        }
        guard let pending = pendingApprovals.removeValue(forKey: approvalID) else {
            return [event(for: request, name: "runtime.error", error: "The approval is no longer pending.")]
        }
        pending.continuation.resume(returning: approved)
        try? await store?.appendAudit(RuntimeAuditRecord(
            sessionID: pending.sessionID,
            category: pending.category,
            action: approvalID,
            decision: approved ? "approved" : "denied",
            detail: "The user \(approved ? "approved" : "denied") this operation once."
        ))
        return [event(for: request, name: "approval.resolved", sessionID: pending.sessionID, payload: .object([
            "approvalId": .string(approvalID),
            "approved": .bool(approved)
        ]))]
    }

    private func waitForApproval(id: String, sessionID: String, category: String, onRegistered: () -> Void) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    pendingApprovals[id] = PendingApproval(sessionID: sessionID, category: category, continuation: continuation)
                    onRegistered()
                }
            }
        } onCancel: {
            Task { await self.resolveApproval(id: id, approved: false) }
        }
    }

    private func resolveApproval(id: String, approved: Bool) {
        pendingApprovals.removeValue(forKey: id)?.continuation.resume(returning: approved)
    }

    private func resolveApprovals(for sessionID: String, approved: Bool) {
        let ids = pendingApprovals.compactMap { $0.value.sessionID == sessionID ? $0.key : nil }
        for id in ids { resolveApproval(id: id, approved: approved) }
    }

    private func resolveAllApprovals(approved: Bool) {
        for id in Array(pendingApprovals.keys) { resolveApproval(id: id, approved: approved) }
    }

    private func nativeInvocationDecision(_ request: RuntimeRequest) async -> [RuntimeEvent] {
        guard let invocationID = request.objectPayload.string("invocationId") else {
            return [event(for: request, name: "runtime.error", error: "native.resolve requires payload.invocationId.")]
        }
        guard let pending = pendingNativeInvocations.removeValue(forKey: invocationID) else {
            return [event(for: request, name: "runtime.error", error: "The native invocation is no longer pending.")]
        }
        let outcome: NativeInvocationOutcome
        if let message = request.objectPayload.string("error") {
            outcome = .failure(message)
        } else {
            outcome = .success(request.objectPayload["result"] ?? .null)
        }
        pending.continuation.resume(returning: outcome)
        try? await store?.appendAudit(RuntimeAuditRecord(
            sessionID: pending.sessionID,
            category: "native_tool",
            action: pending.toolName,
            decision: request.objectPayload.string("error") == nil ? "completed" : "failed",
            detail: "invocationId=\(invocationID)"
        ))
        return [event(for: request, name: "native.resolved", sessionID: pending.sessionID, payload: .object(["invocationId": .string(invocationID)]))]
    }

    private func waitForNativeInvocation(id: String, sessionID: String, toolName: String, onRegistered: () -> Void) async -> NativeInvocationOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .failure("Cancelled"))
                } else {
                    pendingNativeInvocations[id] = PendingNativeInvocation(sessionID: sessionID, toolName: toolName, continuation: continuation)
                    onRegistered()
                }
            }
        } onCancel: {
            Task { await self.resolveNativeInvocation(id: id, outcome: .failure("Cancelled")) }
        }
    }

    private func resolveNativeInvocation(id: String, outcome: NativeInvocationOutcome) {
        pendingNativeInvocations.removeValue(forKey: id)?.continuation.resume(returning: outcome)
    }

    private func resolveNativeInvocations(for sessionID: String, error: String) {
        let ids = pendingNativeInvocations.compactMap { $0.value.sessionID == sessionID ? $0.key : nil }
        for id in ids { resolveNativeInvocation(id: id, outcome: .failure(error)) }
    }

    private func resolveAllNativeInvocations(error: String) {
        for id in Array(pendingNativeInvocations.keys) {
            resolveNativeInvocation(id: id, outcome: .failure(error))
        }
    }

    private func requireStore() throws -> DesktopStore {
        guard let store else { throw DesktopStoreError.open("Runtime persistence was not configured.") }
        return store
    }

    private func auditList(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let limit = request.objectPayload.int("limit") ?? 200
        let records = try await requireStore().audit(sessionID: request.sessionID, limit: limit)
        return [event(for: request, name: "audit.list", payload: try .encoded(records))]
    }

    private func snapshot(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let value = try await requireStore().snapshot(states: states)
        return [event(for: request, name: "runtime.snapshot", payload: try .encoded(value))]
    }

    private func sessionList(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let values = try await requireStore().listConversations()
        return [event(for: request, name: "session.list", payload: try .encoded(values))]
    }

    private func sessionCreate(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let object = request.objectPayload
        let title = object.string("title") ?? "New conversation"
        let agentID = object.string("agentId")
        let groupID = object.string("groupId")
        let role = object.string("role")
        let kind: RuntimeConversationKind = groupID != nil || role == "group"
            ? .group
            : (agentID != nil ? .agent : .conversation)
        let conversation = RuntimeConversation(title: title, kind: kind, agentID: agentID, groupID: groupID)
        try await requireStore().upsertConversation(conversation)
        states[conversation.id] = .idle
        return [event(for: request, name: "session.created", sessionID: conversation.id, payload: try .encoded(conversation))]
    }

    private func sessionOpen(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let id = request.sessionID else { throw RuntimeRequestError.missing("sessionId") }
        let store = try requireStore()
        guard let conversation = try await store.conversation(id) else { throw RuntimeRequestError.notFound("session") }
        let messages = try await store.messages(sessionID: id)
        return [event(for: request, name: "session.opened", payload: .object(["session": try .encoded(conversation), "messages": try .encoded(messages), "state": .string((states[id] ?? .idle).rawValue)]))]
    }

    private func sessionDelete(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let id = request.sessionID else { throw RuntimeRequestError.missing("sessionId") }
        try await requireStore().deleteConversation(id)
        states.removeValue(forKey: id)
        return [event(for: request, name: "session.updated", sessionID: id, payload: .object(["deleted": .bool(true)]))]
    }

    private func sessionSetShellAccess(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let sessionID = request.sessionID, var conversation = try await requireStore().conversation(sessionID) else { throw RuntimeRequestError.notFound("session") }
        guard case .bool(let enabled)? = request.objectPayload["enabled"] else { throw RuntimeRequestError.missing("payload.enabled") }
        conversation.agentShellAccess = enabled
        conversation.updatedAt = Date()
        try await requireStore().upsertConversation(conversation)
        return [event(for: request, name: "session.updated", sessionID: sessionID, payload: try .encoded(conversation))]
    }

    private func sessionSend(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let sessionID = request.sessionID else { throw RuntimeRequestError.missing("sessionId") }
        guard let text = request.objectPayload.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw RuntimeRequestError.missing("payload.text") }
        let store = try requireStore()
        guard let conversation = try await store.conversation(sessionID) else { throw RuntimeRequestError.notFound("session") }
        let user = RuntimeMessageRecord(sessionID: sessionID, role: .user, text: text)
        try await store.appendMessage(user)
        states[sessionID] = .thinking
        var events = [event(for: request, name: "message.started", sessionID: sessionID, payload: try .encoded(user))]
        let configuration = try await configuredProvider(for: conversation, store: store)
        let history = try await store.messages(sessionID: sessionID)
        let systemPrompt = try await systemPrompt(for: conversation, store: store)
        let run = try await providerResponse(messages: history, systemPrompt: systemPrompt, configuration: configuration, conversation: conversation, request: request, agentID: conversation.agentID)
        let response = run.text
        events.append(contentsOf: run.events)
        try Task.checkCancellation()
        let assistant = RuntimeMessageRecord(sessionID: sessionID, role: .assistant, text: response, senderAgentID: conversation.agentID)
        try await store.appendMessage(assistant)
        states[sessionID] = .completed
        events.append(event(for: request, name: "message.delta", sessionID: sessionID, payload: .object(["messageId": .string(assistant.id), "text": .string(response)])))
        events.append(event(for: request, name: "message.completed", sessionID: sessionID, payload: try .encoded(assistant)))
        return events
    }

    private func agentList(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        [event(for: request, name: "agent.list", payload: try .encoded(try await requireStore().listAgents()))]
    }

    private func agentUpsert(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        var agent = try request.requirePayload(RuntimeAgentRecord.self)
        agent.updatedAt = Date()
        try await requireStore().upsertAgent(agent)
        AgentProfile.ensureDirectories(for: agent.id)
        return [event(for: request, name: "agent.updated", payload: try .encoded(agent))]
    }

    private func agentArchive(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let id = request.objectPayload.string("agentId"), var agent = try await requireStore().agent(id) else { throw RuntimeRequestError.notFound("agent") }
        agent.archived = true
        agent.updatedAt = Date()
        try await requireStore().upsertAgent(agent)
        return [event(for: request, name: "agent.updated", payload: try .encoded(agent))]
    }

    private func agentOpenMainSession(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let store = try requireStore()
        guard let id = request.objectPayload.string("agentId"), var agent = try await store.agent(id) else { throw RuntimeRequestError.notFound("agent") }
        if let existing = agent.mainSessionID, let conversation = try await store.conversation(existing) {
            return [event(for: request, name: "session.opened", sessionID: existing, payload: try .encoded(conversation))]
        }
        let conversation = RuntimeConversation(title: agent.name, kind: .agent, agentID: id)
        try await store.upsertConversation(conversation)
        agent.mainSessionID = conversation.id
        agent.updatedAt = Date()
        try await store.upsertAgent(agent)
        return [event(for: request, name: "session.created", sessionID: conversation.id, payload: try .encoded(conversation))]
    }

    private func groupList(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        [event(for: request, name: "group.list", payload: try .encoded(try await requireStore().listGroups()))]
    }

    private func groupUpsert(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        var group = try request.requirePayload(RuntimeGroupRecord.self)
        guard !group.memberIDs.isEmpty, group.memberIDs.count <= GroupProfile.maxMembers else { throw RuntimeRequestError.invalid("A group needs 1–\(GroupProfile.maxMembers) members.") }
        group.updatedAt = Date()
        let store = try requireStore()
        if try await store.conversation(group.sessionID) == nil {
            let conversation = RuntimeConversation(id: group.sessionID, title: group.title, kind: .group, groupID: group.id)
            try await store.createGroup(group, conversation: conversation)
        } else {
            try await store.upsertGroup(group)
        }
        return [event(for: request, name: "group.updated", sessionID: group.sessionID, payload: try .encoded(group))]
    }

    private func groupOpenMemberSession(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let store = try requireStore()
        guard let groupID = request.objectPayload.string("groupId"), let agentID = request.objectPayload.string("agentId"), var group = try await store.group(groupID), let agent = try await store.agent(agentID) else { throw RuntimeRequestError.notFound("group member") }
        let session = try await ensureMemberSession(agent: agent, group: &group, store: store)
        return [event(for: request, name: "session.opened", sessionID: session.id, payload: try .encoded(session))]
    }

    private func groupSend(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let store = try requireStore()
        guard let groupID = request.objectPayload.string("groupId"), let group = try await store.group(groupID) else { throw RuntimeRequestError.notFound("group") }
        guard let text = request.objectPayload.string("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeRequestError.missing("payload.text") }
        let members = try await resolvedMembers(group: group, store: store)
        guard !members.isEmpty else { throw RuntimeRequestError.invalid("Group has no active members.") }
        let room = GroupChatRoom(
            id: group.id,
            sessionID: group.sessionID,
            title: group.title,
            mode: GroupChatMode(rawValue: group.mode) ?? .freeform,
            ownerMemberID: group.ownerAgentID,
            members: members.map { GroupChatParticipant(id: $0.id, name: $0.name, title: $0.title, emoji: $0.emoji, accentColor: $0.accentColor, summary: $0.summary, slot: $0.slot) }
        )
        let collector = RuntimeGroupEventCollector()
        let configuration = try await configuredProvider(for: try await store.conversation(group.sessionID), store: store)
        let repository = ClosureGroupChatRepository(
            room: room,
            transcript: {
                (try? await store.messages(sessionID: group.sessionID).map { record in
                    record.role == .user ? .user(record.text) : .member(record.senderAgentID ?? "unknown", record.text)
                }) ?? []
            },
            appendUser: { room, canonical in
                let record = RuntimeMessageRecord(sessionID: room.sessionID, role: .user, text: canonical)
                try? await store.appendMessage(record)
                await collector.append(RuntimeEvent(requestID: request.requestID, name: "group.turnStarted", sessionID: room.sessionID, payload: (try? .encoded(record))))
            },
            appendMember: { room, memberID, answer in
                let record = RuntimeMessageRecord(sessionID: room.sessionID, role: .assistant, text: answer, senderAgentID: memberID)
                try? await store.appendMessage(record)
                await collector.append(RuntimeEvent(requestID: request.requestID, name: "message.completed", sessionID: room.sessionID, payload: (try? .encoded(record))))
            },
            runMember: { turn in
                await collector.append(RuntimeEvent(requestID: request.requestID, name: "group.memberStarted", sessionID: turn.room.sessionID, payload: .object(["agentId": .string(turn.participant.id), "round": .int(turn.round)])))
                let result = await self.runSharedGroupMemberTurn(turn, store: store, request: request, configuration: configuration, collector: collector)
                await collector.append(RuntimeEvent(requestID: request.requestID, name: "group.memberCompleted", sessionID: turn.room.sessionID, payload: .object(["agentId": .string(turn.participant.id), "skipped": .bool(result.text == nil || !result.accepted || result.timedOut || result.cancelled)])))
                return result
            }
        )
        states[group.sessionID] = .speakingInGroup
        _ = await GroupChatEngine(repository: repository).send(roomID: room.id, text: text)
        states[group.sessionID] = .completed
        var events = await collector.drain()
        events.append(event(for: request, name: "group.completed", sessionID: group.sessionID, payload: .object(["memberTurns": .int(await collector.turnCount())])))
        return events
    }

    private func runSharedGroupMemberTurn(
        _ turn: GroupChatMemberTurn,
        store: DesktopStore,
        request: RuntimeRequest,
        configuration: ProviderConfiguration,
        collector: RuntimeGroupEventCollector
    ) async -> GroupChatMemberTurnResult {
        do {
            guard let agent = try await store.agent(turn.participant.id),
                  var group = try await store.group(turn.room.id),
                  let member = try await resolvedMembers(group: group, store: store).first(where: { $0.id == turn.participant.id }) else {
                return .skipped
            }
            let privateSession = try await ensureMemberSession(agent: agent, group: &group, store: store)
            try await store.appendMessage(RuntimeMessageRecord(sessionID: privateSession.id, role: .user, text: turn.prompt))
            let history = try await store.messages(sessionID: privateSession.id)
            let peers = try await resolvedMembers(group: group, store: store).filter { $0.id != agent.id }
            let run = try await providerResponse(messages: history, systemPrompt: groupSystemPrompt(agent: agent, member: member, group: group, peers: peers), configuration: configuration, conversation: privateSession, request: request, agentID: agent.id)
            await collector.append(contentsOf: run.events)
            try await store.appendMessage(RuntimeMessageRecord(sessionID: privateSession.id, role: .assistant, text: run.text, senderAgentID: agent.id))
            await collector.recordTurn()
            return GroupChatMemberTurnResult(text: run.text)
        } catch is CancellationError {
            return GroupChatMemberTurnResult(text: nil, accepted: false, cancelled: true)
        } catch {
            return .skipped
        }
    }

    private func providerList(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let configurations = try await requireStore().providerConfigurations()
        return [event(for: request, name: "provider.list", payload: try .encoded(configurations))]
    }

    private func providerConfigure(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let configValue = request.objectPayload["configuration"] else { throw RuntimeRequestError.missing("payload.configuration") }
        let config = try configValue.decoded(ProviderConfiguration.self)
        guard !config.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeRequestError.invalid("Provider id cannot be empty.") }
        guard let scheme = config.endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme) else { throw RuntimeRequestError.invalid("Provider endpoint must use HTTP or HTTPS.") }
        let makeDefault: Bool
        if case .bool(let value)? = request.objectPayload["makeDefault"] { makeDefault = value }
        else { makeDefault = config.id == "default" }
        try await requireStore().upsertProviderConfiguration(config, makeDefault: makeDefault)
        if let key = request.objectPayload.string("apiKey"), !key.isEmpty { try await credentials.save(key, account: config.id) }
        return [event(for: request, name: "provider.updated", payload: try .encoded(config))]
    }

    private func providerTest(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let store = try requireStore()
        let configuration: ProviderConfiguration
        if let providerID = request.objectPayload.string("providerId") {
            guard let selected = try await store.providerConfiguration(id: providerID) else { throw RuntimeRequestError.notFound("provider") }
            configuration = selected
        } else if let configValue = request.objectPayload["configuration"] {
            // An unsaved configuration may be probed, but its credential still
            // comes from Keychain under the configuration's stable id.
            configuration = try configValue.decoded(ProviderConfiguration.self)
        } else if let selected = try await store.defaultProviderConfiguration() {
            configuration = selected
        } else {
            throw ProviderRunnerError.notConfigured
        }

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await provider.respond(
                messages: [RuntimeMessageRecord(sessionID: "provider-test", role: .user, text: "Reply with OK.")],
                systemPrompt: "This is a provider connectivity test. Reply with OK only.",
                configuration: configuration
            )
            let elapsed = started.duration(to: clock.now)
            let result = RuntimeProviderTestResult(providerID: configuration.id, success: true, elapsedMilliseconds: Self.milliseconds(elapsed))
            return [event(for: request, name: "provider.tested", payload: try .encoded(result))]
        } catch {
            let elapsed = started.duration(to: clock.now)
            let result = RuntimeProviderTestResult(providerID: configuration.id, success: false, elapsedMilliseconds: Self.milliseconds(elapsed), error: error.localizedDescription)
            return [event(for: request, name: "provider.tested", payload: try .encoded(result))]
        }
    }

    private func providerSetSessionBinding(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let sessionID = request.sessionID else { throw RuntimeRequestError.missing("sessionId") }
        let providerID: String?
        switch request.objectPayload["providerId"] {
        case .string(let value):
            guard try await requireStore().providerConfiguration(id: value) != nil else { throw RuntimeRequestError.notFound("provider") }
            providerID = value
        case .null:
            providerID = nil
        case nil:
            throw RuntimeRequestError.missing("payload.providerId")
        default:
            throw RuntimeRequestError.invalid("payload.providerId must be a provider id or null.")
        }
        guard let conversation = try await requireStore().setProviderConfigurationID(providerID, forSession: sessionID) else { throw RuntimeRequestError.notFound("session") }
        return [event(for: request, name: "session.updated", sessionID: sessionID, payload: try .encoded(conversation))]
    }

    private func providerKimiDeviceStart(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        _ = try await requireKimiProviderID(request)
        let authorization = try await kimiOAuth.requestDeviceAuthorization()
        return [event(for: request, name: "provider.kimiDeviceCode", payload: try .encoded(authorization))]
    }

    private func providerKimiDeviceComplete(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let providerID = try await requireKimiProviderID(request)
        guard let value = request.objectPayload["authorization"] else { throw RuntimeRequestError.missing("payload.authorization") }
        let authorization = try value.decoded(KimiDeviceAuthorization.self)
        _ = try await kimiOAuth.completeDeviceAuthorization(authorization, account: providerID)
        return [event(for: request, name: "provider.authenticated", payload: .object(["providerId": .string(providerID)]))]
    }

    private func providerKimiSignOut(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let providerID = try await requireKimiProviderID(request)
        try await kimiOAuth.signOut(account: providerID)
        return [event(for: request, name: "provider.signedOut", payload: .object(["providerId": .string(providerID)]))]
    }

    private func requireKimiProviderID(_ request: RuntimeRequest) async throws -> String {
        guard let providerID = request.objectPayload.string("providerId"), !providerID.isEmpty else {
            throw RuntimeRequestError.missing("payload.providerId")
        }
        guard let configuration = try await requireStore().providerConfiguration(id: providerID) else {
            throw RuntimeRequestError.notFound("provider")
        }
        guard configuration.providerType == .kimiCode, configuration.credentialType == .oauth else {
            throw RuntimeRequestError.invalid("The selected provider is not a Kimi OAuth configuration.")
        }
        return providerID
    }

    private func syncNow(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let syncCoordinator else { throw RuntimeRequestError.invalid("Persistence is unavailable.") }
        let didStart = try await syncCoordinator.start(periodicInterval: .seconds(60))
        let status = didStart
            ? await syncCoordinator.currentStatus()
            : try await syncCoordinator.synchronize(trigger: .manual)
        return [event(for: request, name: "sync.completed", payload: try .encoded(status))]
    }

    private func syncStatus(_ request: RuntimeRequest) async -> [RuntimeEvent] {
        guard let syncCoordinator else {
            return [event(for: request, name: "sync.status", error: "Persistence is unavailable.")]
        }
        return [event(for: request, name: "sync.status", payload: try? .encoded(await syncCoordinator.currentStatus()))]
    }

    private func importLegacyStore(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let path = request.objectPayload.string("path") else { throw RuntimeRequestError.missing("payload.path") }
        let result = try await LegacyChatStoreImporter(databaseURL: URL(fileURLWithPath: path)).importInto(requireStore())
        return [event(for: request, name: "persistence.imported", payload: try .encoded(result))]
    }

    private func workspaceGrant(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let path = request.objectPayload.string("path") else { throw RuntimeRequestError.missing("payload.path") }
        let id = try await workspaces.grant(URL(fileURLWithPath: path))
        try await persistWorkspaces()
        return [event(for: request, name: "workspace.granted", payload: .object(["workspaceID": .string(id), "path": .string(path)]))]
    }

    private func workspaceList(_ request: RuntimeRequest) async -> [RuntimeEvent] {
        let values = await workspaces.all().mapValues(\.path)
        return [event(for: request, name: "workspace.list", payload: (try? .encoded(values)))]
    }

    private func workspaceRevoke(_ request: RuntimeRequest) async -> [RuntimeEvent] {
        if let id = request.objectPayload.string("workspaceId") { await workspaces.revoke(id) }
        try? await persistWorkspaces()
        return [event(for: request, name: "workspace.revoked")]
    }

    private func persistWorkspaces() async throws {
        guard let store else { return }
        let values = await workspaces.all().mapValues(\.path)
        try await store.setMetadata(values, for: "workspace.grants")
    }

    private func workspaceSetSession(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let sessionID = request.sessionID, let workspaceID = request.objectPayload.string("workspaceId"), await workspaces.url(for: workspaceID) != nil, var conversation = try await requireStore().conversation(sessionID) else { throw RuntimeRequestError.invalid("Unknown session or workspace.") }
        conversation.workspaceID = workspaceID
        conversation.updatedAt = Date()
        try await requireStore().upsertConversation(conversation)
        return [event(for: request, name: "session.updated", sessionID: sessionID, payload: try .encoded(conversation))]
    }

    private func executeShell(_ request: RuntimeRequest) async -> [RuntimeEvent] {
        guard let command = request.objectPayload.string("command"), let workspaceID = request.objectPayload.string("workspaceID"), let workspace = await workspaces.url(for: workspaceID) else {
            return [event(for: request, name: "runtime.error", error: "shell.execute requires command and a granted workspaceID.")]
        }
        let sessionID = request.sessionID ?? "desktop-preview"
        states[sessionID] = .runningTool
        let started = event(for: request, name: "tool.started", sessionID: sessionID, payload: .object(["tool": .string("shell_execute")]))
        do {
            let timeout = request.objectPayload.int("timeoutSeconds").map(TimeInterval.init)
            let result = try await shell.execute(CommandRequest(command: command, workingDirectory: workspace, sessionID: sessionID, timeout: timeout))
            states[sessionID] = result.wasCancelled ? .cancelled : .completed
            return [started, event(for: request, name: "tool.completed", sessionID: sessionID, payload: .object(["stdout": .string(result.stdout), "stderr": .string(result.stderr), "exitCode": .int(Int(result.exitCode)), "cancelled": .bool(result.wasCancelled)]))]
        } catch {
            states[sessionID] = .failed
            return [started, event(for: request, name: "tool.completed", sessionID: sessionID, error: error.localizedDescription)]
        }
    }

    private func terminalCreate(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        guard let workspaceID = request.objectPayload.string("workspaceId"), let workspace = await workspaces.url(for: workspaceID) else { throw RuntimeRequestError.invalid("Choose a workspace before opening a terminal.") }
        let columns = UInt16(clamping: request.objectPayload.int("columns") ?? 100)
        let rows = UInt16(clamping: request.objectPayload.int("rows") ?? 30)
        let created = try await terminal.create(workingDirectory: workspace, size: TerminalSize(columns: columns, rows: rows))
        let capture = TerminalCapture()
        terminalCaptures[created.id] = capture
        Task {
            for await value in created.events { await capture.append(value) }
        }
        return [event(for: request, name: "terminal.created", payload: .object(["terminalId": .string(created.id.uuidString)]))]
    }

    private func terminalRead(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let id = try request.terminalID()
        guard let capture = terminalCaptures[id] else { throw TerminalBackendError.unknownSession }
        let events = await capture.drain().map { value -> RuntimeTerminalEventRecord in
            switch value {
            case .output(let data): RuntimeTerminalEventRecord(kind: .output, base64Data: data.base64EncodedString())
            case .exited(let code): RuntimeTerminalEventRecord(kind: .exited, exitCode: code)
            }
        }
        return [event(for: request, name: "terminal.output", payload: try .encoded(events))]
    }

    private func terminalInput(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let id = try request.terminalID()
        guard let base64 = request.objectPayload.string("base64"), let data = Data(base64Encoded: base64) else { throw RuntimeRequestError.missing("payload.base64") }
        try await terminal.input(data, sessionID: id)
        return [event(for: request, name: "terminal.updated")]
    }

    private func terminalResize(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let id = try request.terminalID()
        try await terminal.resize(TerminalSize(columns: UInt16(clamping: request.objectPayload.int("columns") ?? 100), rows: UInt16(clamping: request.objectPayload.int("rows") ?? 30)), sessionID: id)
        return [event(for: request, name: "terminal.updated")]
    }

    private func terminalSignal(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let id = try request.terminalID()
        await terminal.signal(Int32(request.objectPayload.int("signal") ?? Int(SIGINT)), sessionID: id)
        return [event(for: request, name: "terminal.updated")]
    }

    private func terminalClose(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        let id = try request.terminalID()
        await terminal.close(sessionID: id)
        terminalCaptures.removeValue(forKey: id)
        return [event(for: request, name: "terminal.exited")]
    }

    private func configuredProvider(for conversation: RuntimeConversation?, store: DesktopStore) async throws -> ProviderConfiguration {
        if let id = conversation?.providerConfigurationID {
            guard let selected = try await store.providerConfiguration(id: id) else {
                throw RuntimeRequestError.invalid("The session is bound to a provider configuration that no longer exists: \(id)")
            }
            return selected
        }
        guard let configuration = try await store.defaultProviderConfiguration() else { throw ProviderRunnerError.notConfigured }
        return configuration
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        let millisFromAttoseconds = components.attoseconds / 1_000_000_000_000_000
        guard !seconds.overflow else { return Int.max }
        return max(0, Int(clamping: seconds.partialValue + millisFromAttoseconds))
    }

    private func systemPrompt(for conversation: RuntimeConversation, store: DesktopStore) async throws -> String? {
        guard let agentID = conversation.agentID, let agent = try await store.agent(agentID) else { return nil }
        return DesktopContextAssembler.prompt(for: agent) + "\n\nKeep your identity and answer in the user's language."
    }

    private func resolvedMembers(group: RuntimeGroupRecord, store: DesktopStore) async throws -> [GroupMember] {
        var members: [GroupMember] = []
        for (slot, id) in group.memberIDs.enumerated() {
            if let agent = try await store.agent(id), !agent.archived {
                members.append(GroupMember(id: id, name: agent.name, title: agent.title, emoji: agent.emoji, accentColor: agent.accentColor, summary: agent.summary, slot: slot))
            }
        }
        return members
    }

    private func ensureMemberSession(agent: RuntimeAgentRecord, group: inout RuntimeGroupRecord, store: DesktopStore) async throws -> RuntimeConversation {
        if let id = group.memberSessionIDs[agent.id], let existing = try await store.conversation(id) { return existing }
        let groupConversation = try await store.conversation(group.sessionID)
        let conversation = RuntimeConversation(title: "\(group.title) · \(agent.name)", kind: .agent, agentID: agent.id, groupID: group.id, workspaceID: groupConversation?.workspaceID)
        try await store.upsertConversation(conversation)
        group.memberSessionIDs[agent.id] = conversation.id
        group.updatedAt = Date()
        try await store.upsertGroup(group)
        return conversation
    }

    private func groupSystemPrompt(agent: RuntimeAgentRecord, member: GroupMember, group: RuntimeGroupRecord, peers: [GroupMember]) -> String {
        let mode = GroupChatMode(rawValue: group.mode) ?? .freeform
        return DesktopContextAssembler.prompt(for: agent) + "\n\n" + GroupChatPrompt.memberSystemBlock(member: member, groupId: group.id, groupTitle: group.title, mode: mode, isOwner: group.ownerAgentID == agent.id, peers: peers)
    }

    private func providerResponse(
        messages: [RuntimeMessageRecord],
        systemPrompt: String?,
        configuration: ProviderConfiguration,
        conversation: RuntimeConversation,
        request: RuntimeRequest,
        agentID: String?
    ) async throws -> (text: String, events: [RuntimeEvent]) {
        guard let toolProvider = provider as? any ToolCallingProviderRunner,
              let workspaceID = conversation.workspaceID,
              let workspace = await workspaces.url(for: workspaceID) else {
            return (try await provider.respond(messages: messages, systemPrompt: systemPrompt, configuration: configuration), [])
        }
        if let agentID, let agent = try await store?.agent(agentID), agent.toolPolicy != "standalone" {
            return (try await provider.respond(messages: messages, systemPrompt: systemPrompt, configuration: configuration), [])
        }

        let executor = RuntimeToolExecutor(shell: shell, workspace: workspace, sessionID: conversation.id, agentID: agentID)
        let runtimeTools = RuntimeToolExecutor.availableDefinitions(allowShell: conversation.agentShellAccess == true)
            + NativeToolCatalog.definitions
        let runtimeToolsByName = Dictionary(uniqueKeysWithValues: runtimeTools.map { ($0.name, $0) })
        let sharedTools = try runtimeTools.map { definition in
            let json = try JSONEncoder.runtime.encode(definition.parameters)
            return AgentRunToolDefinition(
                name: definition.name,
                description: definition.description,
                parametersJSON: String(decoding: json, as: UTF8.self)
            )
        }
        let initialMessages = messages.compactMap { message -> AgentRunMessage? in
            switch message.role {
            case .user: .init(role: .user, content: message.text)
            case .assistant: .init(role: .assistant, content: message.text)
            case .system: nil
            }
        }
        let collector = RuntimeRunEventCollector()
        let engine = AgentRunEngine(dependencies: .init(
            provider: { request in
                let wireMessages = request.messages.map { message in
                    ProviderConversationMessage(
                        role: message.role.rawValue,
                        content: message.content,
                        toolCallID: message.toolCallID,
                        toolCalls: message.toolCalls.map {
                            ProviderToolCall(id: $0.id, name: $0.name, arguments: $0.argumentsJSON)
                        }
                    )
                }
                let definitions = request.tools.compactMap { runtimeToolsByName[$0.name] }
                let turn = try await toolProvider.complete(
                    messages: wireMessages,
                    systemPrompt: request.systemPrompt,
                    tools: definitions,
                    configuration: configuration
                )
                return AgentRunProviderTurn(
                    text: turn.content,
                    toolCalls: turn.toolCalls.map {
                        AgentRunToolCall(id: $0.id, name: $0.name, argumentsJSON: $0.arguments)
                    }
                )
            },
            executeTool: { [weak self, collector] call in
                guard let self else { throw CancellationError() }
                return try await self.executeSharedToolCall(
                    call,
                    executor: executor,
                    request: request,
                    conversation: conversation,
                    workspace: workspace,
                    agentID: agentID,
                    collector: collector
                )
            },
            emit: { [weak self, collector] event in
                guard let self else { return }
                await self.captureSharedRunEvent(event, request: request, conversation: conversation, collector: collector)
            },
            isCancelled: { [weak self] in
                guard let self else { return true }
                return await self.isRunCancelled(sessionID: conversation.id)
            }
        ))
        let result = try await engine.run(
            messages: initialMessages,
            systemPrompt: systemPrompt,
            tools: sharedTools,
            configuration: AgentRunConfiguration(maximumToolRounds: 8)
        )
        let content = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw ProviderRunnerError.invalidResponse }
        return (content, collector.values())
    }

    private func executeSharedToolCall(
        _ sharedCall: AgentRunToolCall,
        executor: RuntimeToolExecutor,
        request: RuntimeRequest,
        conversation: RuntimeConversation,
        workspace: URL,
        agentID: String?,
        collector: RuntimeRunEventCollector
    ) async throws -> String {
        let call = ProviderToolCall(id: sharedCall.id, name: sharedCall.name, arguments: sharedCall.argumentsJSON)
        if call.name == "shell_execute" {
            let command = try shellCommand(from: call)
            let approvalID = UUID().uuidString
            states[conversation.id] = .waitingApproval
            try? await store?.appendAudit(RuntimeAuditRecord(
                sessionID: conversation.id,
                category: "agent_shell",
                action: approvalID,
                decision: "requested",
                detail: "cwd=\(workspace.path)\ncommand=\(command)"
            ))
            let approved = await waitForApproval(id: approvalID, sessionID: conversation.id, category: "agent_shell") {
                collector.append(event(for: request, name: "approval.requested", sessionID: conversation.id, payload: .object([
                    "approvalId": .string(approvalID),
                    "toolCallId": .string(call.id),
                    "tool": .string(call.name),
                    "command": .string(command),
                    "cwd": .string(workspace.path),
                    "agentId": agentID.map(JSONValue.string) ?? .null
                ])))
            }
            try Task.checkCancellation()
            guard approved else { throw RuntimeToolError.approvalDenied }
            states[conversation.id] = .runningTool
        }

        if NativeToolCatalog.contains(call.name) {
            let invocationID = UUID().uuidString
            let arguments = try NativeToolCatalog.arguments(for: call)
            if NativeToolCatalog.requiresExplicitApproval(call.name) {
                let approvalID = UUID().uuidString
                let summary = NativeToolCatalog.approvalSummary(name: call.name, arguments: arguments)
                states[conversation.id] = .waitingApproval
                try? await store?.appendAudit(RuntimeAuditRecord(
                    sessionID: conversation.id,
                    category: "native_tool",
                    action: approvalID,
                    decision: "requested",
                    detail: "tool=\(call.name)\n\(summary)"
                ))
                let approved = await waitForApproval(id: approvalID, sessionID: conversation.id, category: "native_tool") {
                    collector.append(event(for: request, name: "approval.requested", sessionID: conversation.id, payload: .object([
                        "approvalId": .string(approvalID),
                        "toolCallId": .string(call.id),
                        "tool": .string(call.name),
                        "command": .string(summary),
                        "cwd": .string("macOS native action"),
                        "agentId": agentID.map(JSONValue.string) ?? .null
                    ])))
                }
                try Task.checkCancellation()
                guard approved else { throw RuntimeToolError.approvalDenied }
                states[conversation.id] = .runningTool
            }
            try? await store?.appendAudit(RuntimeAuditRecord(
                sessionID: conversation.id,
                category: "native_tool",
                action: call.name,
                decision: "requested",
                detail: "invocationId=\(invocationID)"
            ))
            let nativeOutcome = await waitForNativeInvocation(id: invocationID, sessionID: conversation.id, toolName: call.name) {
                collector.append(event(for: request, name: "native.invoke", sessionID: conversation.id, payload: .object([
                    "invocationId": .string(invocationID),
                    "name": .string(call.name),
                    "arguments": arguments
                ])))
            }
            let result: String
            switch nativeOutcome {
            case .success(let value): result = try NativeToolCatalog.resultString(value)
            case .failure(let message): throw RuntimeRequestError.invalid(message)
            }
            try Task.checkCancellation()
            return result
        }
        return try await executor.execute(call)
    }

    private func captureSharedRunEvent(
        _ runEvent: AgentRunEvent,
        request: RuntimeRequest,
        conversation: RuntimeConversation,
        collector: RuntimeRunEventCollector
    ) {
        switch runEvent {
        case .toolStarted(let call):
            collector.append(event(for: request, name: "tool.started", sessionID: conversation.id, payload: .object([
                "tool": .string(call.name),
                "toolCallId": .string(call.id)
            ])))
        case .toolOutput(let id, let name, let output):
            collector.append(event(for: request, name: "tool.output", sessionID: conversation.id, payload: .object([
                "tool": .string(name),
                "toolCallId": .string(id),
                "output": .string(output)
            ])))
            collector.append(event(for: request, name: "tool.completed", sessionID: conversation.id, payload: .object([
                "tool": .string(name),
                "toolCallId": .string(id),
                "success": .bool(true)
            ])))
        case .toolFailed(let id, let name, let message):
            collector.append(event(for: request, name: "tool.completed", sessionID: conversation.id, payload: .object([
                "tool": .string(name),
                "toolCallId": .string(id),
                "success": .bool(false)
            ]), error: message))
        default:
            break
        }
    }

    private func isRunCancelled(sessionID: String) -> Bool {
        states[sessionID] == .cancelled
    }

    private func shellCommand(from call: ProviderToolCall) throws -> String {
        guard let data = call.arguments.data(using: .utf8),
              case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data),
              let command = object.string("command"),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeToolError.invalidArguments("shell_execute.command")
        }
        return command
    }

    private func event(for request: RuntimeRequest, name: String, sessionID: String? = nil, payload: JSONValue? = nil, error: String? = nil) -> RuntimeEvent {
        sequence += 1
        let value = RuntimeEvent(requestID: request.requestID, name: name, sessionID: sessionID ?? request.sessionID, sequence: sequence, payload: payload, error: error)
        requestEventSinks[request.requestID]?(value)
        for subscriber in eventSubscribers.values { subscriber.yield(value) }
        return value
    }
}

private actor RuntimeGroupEventCollector {
    private var values: [RuntimeEvent] = []
    private var turns = 0

    func append(_ event: RuntimeEvent) { values.append(event) }
    func append(contentsOf events: [RuntimeEvent]) { values.append(contentsOf: events) }
    func recordTurn() { turns += 1 }
    func turnCount() -> Int { turns }
    func drain() -> [RuntimeEvent] { values }
}

private actor ClosureGroupChatRepository: GroupChatRepository {
    private let roomValue: GroupChatRoom
    private let transcriptBody: @Sendable () async -> [GroupMessage]
    private let appendUserBody: @Sendable (GroupChatRoom, String) async -> Void
    private let appendMemberBody: @Sendable (GroupChatRoom, String, String) async -> Void
    private let runMemberBody: @Sendable (GroupChatMemberTurn) async -> GroupChatMemberTurnResult

    init(
        room: GroupChatRoom,
        transcript: @escaping @Sendable () async -> [GroupMessage],
        appendUser: @escaping @Sendable (GroupChatRoom, String) async -> Void,
        appendMember: @escaping @Sendable (GroupChatRoom, String, String) async -> Void,
        runMember: @escaping @Sendable (GroupChatMemberTurn) async -> GroupChatMemberTurnResult
    ) {
        roomValue = room
        transcriptBody = transcript
        appendUserBody = appendUser
        appendMemberBody = appendMember
        runMemberBody = runMember
    }

    func room(id: String) async -> GroupChatRoom? { id == roomValue.id ? roomValue : nil }
    func transcript(room: GroupChatRoom) async -> [GroupMessage] { await transcriptBody() }
    func appendUser(room: GroupChatRoom, text: String) async { await appendUserBody(room, text) }
    func appendMember(room: GroupChatRoom, memberID: String, text: String) async { await appendMemberBody(room, memberID, text) }
    func runMemberTurn(_ turn: GroupChatMemberTurn) async -> GroupChatMemberTurnResult { await runMemberBody(turn) }
}

public enum RuntimeRequestError: LocalizedError, Sendable {
    case missing(String)
    case invalid(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let field): "Missing required field: \(field)."
        case .invalid(let message): message
        case .notFound(let name): "The requested \(name) was not found."
        }
    }
}

private extension RuntimeRequest {
    var objectPayload: [String: JSONValue] {
        if case .object(let object) = payload { return object }
        return [:]
    }

    func requirePayload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let payload else { throw RuntimeRequestError.missing("payload") }
        return try payload.decoded(type)
    }

    func terminalID() throws -> UUID {
        guard let raw = objectPayload.string("terminalId"), let id = UUID(uuidString: raw) else { throw RuntimeRequestError.missing("payload.terminalId") }
        return id
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { if case .string(let value) = self[key] { value } else { nil } }
    func int(_ key: String) -> Int? { if case .int(let value) = self[key] { value } else { nil } }
}

private actor TerminalCapture {
    private var values: [TerminalEvent] = []
    func append(_ value: TerminalEvent) { values.append(value) }
    func drain() -> [TerminalEvent] { defer { values.removeAll(keepingCapacity: true) }; return values }
}
