import Foundation

/// Temporary iOS adapter around the existing ViewModel-hosted engine. All
/// AgentKit callers target `AgentSessionRunning`; extraction of AgentRunEngine
/// can therefore replace this adapter without changing group business rules.
@MainActor
final class IOSAgentSessionRunner: AgentSessionRunning {
    static let shared = IOSAgentSessionRunner()

    private init() {}

    func createSession(_ request: AgentSessionCreateRequest) async -> String? {
        let vm = ViewModelCache.shared.createDraft()
        vm.sessionSource = request.source
        vm.agentId = request.agentId
        vm.groupId = request.groupId
        vm.isGroupTranscript = request.role == GroupSessionRole.group
        vm.agentRole = request.role == "subagent" ? .executor : .main
        if let rawPolicy = request.toolPolicy, let policy = AgentToolPolicy(rawValue: rawPolicy) {
            vm.resolvedToolPolicy = policy
        }

        let sessionId = await vm.ensureSessionReturningId()
        guard !sessionId.isEmpty else { return nil }
        if request.role == GroupSessionRole.group {
            await ChatStore.shared.linkGroupSession(sessionId, title: request.title ?? request.spawnTitle ?? "")
        } else if let agentId = request.agentId {
            await ChatStore.shared.linkSession(
                sessionId,
                agentId: agentId,
                role: request.role,
                parentSessionId: request.parentSessionId,
                spawnTitle: request.spawnTitle
            )
        }

        if let inheritedSessionId = request.inheritModelFromSessionId,
           let binding = ProviderConfigStore.shared.binding(for: inheritedSessionId) {
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(sessionId: sessionId, primarySource: binding.primarySource),
                for: sessionId
            )
        } else if let entryId = request.defaultModelEntryId,
                  ProviderConfigStore.shared.entry(for: entryId) != nil {
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(sessionId: sessionId, primarySource: .directEntry(modelEntryId: entryId)),
                for: sessionId
            )
        }

        if !request.groupMemberIds.isEmpty {
            var members: [GroupMember] = []
            for (slot, agentId) in request.groupMemberIds.enumerated() {
                guard let profile = await AgentStore.shared.loadAgent(agentId), !profile.isArchived else { continue }
                members.append(GroupMember(
                    id: profile.id,
                    name: profile.name,
                    title: profile.title,
                    emoji: profile.emoji,
                    accentColor: profile.accentColor,
                    summary: profile.summary,
                    slot: slot
                ))
            }
            vm.groupMembers = members
        }
        ViewModelCache.shared.cacheDraft(vm, sessionId: sessionId)
        return sessionId
    }

    func run(_ request: AgentSessionRunRequest) async -> AgentSessionRunResult {
        let (vm, isFresh) = ViewModelCache.shared.getOrCreate(for: request.sessionId)
        if isFresh { await vm.loadSession() }
        vm.groupId = request.groupId
        vm.agentId = request.agentId
        vm.agentRole = request.role == AgentRunRole.executor.rawValue ? .executor : .main
        vm.sessionSource = request.source
        vm.groupPromptBlock = request.systemPromptBlock
        if let rawPolicy = request.toolPolicy, let policy = AgentToolPolicy(rawValue: rawPolicy) {
            vm.resolvedToolPolicy = policy
        }

        if let rawThinking = request.thinkingLevel, let level = ThinkingLevel(rawValue: rawThinking) {
            var inference = ProviderConfigStore.shared.inferenceConfig(for: request.sessionId) ?? SessionInferenceConfig()
            if inference.thinkingLevel != level {
                inference.thinkingLevel = level
                ProviderConfigStore.shared.setInferenceConfig(inference, for: request.sessionId)
            }
        }

        if vm.isProcessing {
            vm.cancel()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let countBefore = vm.messages.count
        let draft = vm.inputText
        AgentDirectoryCoordinator.shared.discardPendingGroupMessage(callerSessionId: request.sessionId)
        vm.inputText = request.prompt
        vm.send()
        let accepted = vm.isProcessing
        vm.inputText = draft
        guard accepted else {
            AgentDirectoryCoordinator.shared.discardPendingGroupMessage(callerSessionId: request.sessionId)
            return .rejected
        }
        guard await AgentTurnAwaiter.awaitTurn(vm: vm, seconds: request.timeoutSeconds) else {
            AgentDirectoryCoordinator.shared.discardPendingGroupMessage(callerSessionId: request.sessionId)
            return AgentSessionRunResult(text: nil, accepted: true, timedOut: true, cancelled: false)
        }
        let text = AgentDirectoryCoordinator.shared.consumePendingGroupMessage(callerSessionId: request.sessionId)
            ?? AgentTurnAwaiter.lastAssistantText(vm: vm, after: countBefore)
        return AgentSessionRunResult(text: text, accepted: true, timedOut: false, cancelled: false)
    }

    func resumeAfterAsyncToolResults(sessionId: String) async -> AgentSessionRunResult {
        let (vm, isFresh) = ViewModelCache.shared.getOrCreate(for: sessionId)
        if isFresh {
            await vm.loadSession()
        } else {
            await vm.reloadMessagesFromDB(reason: "asyncToolResults")
        }
        guard !vm.isProcessing else { return .rejected }
        let countBefore = vm.messages.count
        let accepted = await vm.resumeNoticeDrivenLoop()
        guard accepted else { return .rejected }
        guard await AgentTurnAwaiter.awaitTurn(vm: vm, seconds: 120) else {
            return AgentSessionRunResult(text: nil, accepted: true, timedOut: true, cancelled: false)
        }
        let text = AgentTurnAwaiter.lastAssistantText(vm: vm, after: countBefore)
        return AgentSessionRunResult(text: text, accepted: true, timedOut: false, cancelled: false)
    }

    func cancel(sessionId: String) {
        ViewModelCache.shared.get(for: sessionId)?.cancel()
    }

    func status(sessionId: String) async -> AgentSessionStatus {
        let vm = ViewModelCache.shared.get(for: sessionId)
        let iteration = SessionActivityTracker.shared.sessionToolInfo[sessionId]?.loopIteration ?? 0
        let lastAssistant = vm?.messages.last(where: { $0.role == .assistant })
        let toolBlock = lastAssistant?.blocks.last { block in
            switch block.kind {
            case .text, .thinking, .info: return false
            default: return true
            }
        }
        let activity = toolBlock.map { $0.toolSummary ?? $0.toolDescription } ?? ""
        let liveText = lastAssistant?.blocks
            .filter { $0.kind == .text }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let persisted = await ChatStore.shared.getSession(sessionId)?.lastMessage
        return AgentSessionStatus(
            isRunning: vm?.isProcessing == true || SessionActivityTracker.shared.isActive(sessionId),
            lastAssistantText: liveText?.isEmpty == false ? liveText : persisted,
            currentActivity: activity,
            iteration: iteration
        )
    }

    func isRunning(sessionId: String) async -> Bool {
        await status(sessionId: sessionId).isRunning
    }
}
