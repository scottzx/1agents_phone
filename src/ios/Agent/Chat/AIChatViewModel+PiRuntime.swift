//
//  AIChatViewModel+PiRuntime.swift
//  Minis
//
//  Integration of the `pi` agent runtime (PiRuntimeSessionController) with the
//  chat view model.
//
//  `runAgentLoop` routes to the pi runtime when the bundled binary is present:
//  the controller launches `pi --mode rpc` inside the iSH guest with the app's
//  base system prompt and provider credentials, streams AgentEvents back here
//  (text deltas → text block, thinking → thinking block, tool executions →
//  tool cards), and the turn is persisted through the existing
//  persistAgentMessage path — so ChatStore stays the UI/sync truth source and
//  the renderer is untouched.
//
//  Fallback: if pi cannot start (no binary, no credentials, launch error) the
//  call returns false and the legacy runAgentLoop continues as before.
//

import Foundation

// MARK: - Routing

extension AIChatViewModel {

    /// Whether the pi runtime should take over agent turns for this VM.
    /// Requires the bundled binary and a resolvable provider entry.
    private var piRuntimeIsEligible: Bool {
        guard Bundle.main.url(forResource: "pi", withExtension: nil) != nil else { return false }
        return true
    }

    /// Guest session transcript path (pi persists its own history here).
    /// Reused across relaunches so multi-turn context survives.
    ///
    /// pi's `--session` only resumes an EXISTING file (SessionNotFound
    /// otherwise), so on the first turn of a chat session there is no file
    /// yet: we return nil and pi creates a new session under --session-dir.
    /// `recordPiSessionFile()` maps pi's actually-created file back to this
    /// chat session after the first turn, and later turns resume it.
    private func piSessionFile() -> String? {
        guard let sessionId else { return nil }
        let fm = FileManager.default
        let hostRoot = RootfsManager.shared.dataPath.path

        // Previously recorded pi session file for this chat session.
        let key = "piSessionFile.\(sessionId)"
        if let recorded = UserDefaults.standard.string(forKey: key),
           fm.fileExists(atPath: hostRoot + recorded) {
            return recorded
        }
        UserDefaults.standard.removeObject(forKey: key)

        // Legacy deterministic path used by earlier builds (if present).
        let legacy = "\(PiRuntimeSessionController.guestSessionDirPath)/\(sessionId).sqlite"
        if fm.fileExists(atPath: hostRoot + legacy) {
            return legacy
        }
        return nil
    }

    /// After a pi turn, remember the session file pi actually created so the
    /// next turn resumes the same conversation. pi names new sessions
    /// `<session-dir>/<cwd>/<timestamp>_<id>.{jsonl|sqlite}`, so we discover
    /// the newest regular session file under the sessions dir.
    private func recordPiSessionFile() {
        guard let sessionId else { return }
        let fm = FileManager.default
        let sessionsHostDir = RootfsManager.shared.dataPath
            .appendingPathComponent("root/.pi/agent/sessions")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: sessionsHostDir,
                                             includingPropertiesForKeys: Array(keys),
                                             options: [.skipsHiddenFiles]) else { return }
        var newestPath: String?
        var newestDate = Date.distantPast
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            let ext = url.pathExtension.lowercased()
            guard ext == "jsonl" || ext == "sqlite" else { continue }
            if url.lastPathComponent == "session-index.sqlite" { continue }
            if date > newestDate {
                newestDate = date
                newestPath = url.path
            }
        }
        guard let newestPath else { return }
        let guestPath = PiRuntimeSessionController.guestSessionDirPath
            + newestPath.replacingOccurrences(of: sessionsHostDir.path, with: "")
        UserDefaults.standard.set(guestPath, forKey: "piSessionFile.\(sessionId)")
        AppLogger(category: "PiRuntime").info("pi session file recorded: \(guestPath)")
    }

    /// Build the same system prompt the legacy loop sends, so pi drives the
    /// identical identity/skills/MCP/memory context.
    private func buildPiSystemPrompt() -> String {
        var prompt = baseSystemPrompt
        let activeModel = ProviderConfigStore.shared.entry(for: resolveCurrentEntry()?.id ?? "")?.model ?? selectedModel
        if let capFragment = activeModel.capabilityPromptFragment {
            prompt += "\n\n" + capFragment
        }
        if let behaviorFragment = activeModel.agentBehaviorPromptFragment {
            prompt += "\n\n" + behaviorFragment
        }
        if let sid = sessionId, let skillFragment = SkillStore.shared.skillPromptFragment(for: sid) {
            prompt += "\n\n" + skillFragment
        }
        if let sid = sessionId, let mcpFragment = MCPStore.shared.systemPromptSnippet(for: sid) {
            prompt += "\n\n" + mcpFragment
        }
        if memoryEnabled {
            if let memoryFragment = Self.loadGlobalMemoryFragment() {
                prompt += "\n\n" + memoryFragment
            }
            if let dailyFragment = Self.loadRecentDailyMemoryFragment() {
                prompt += "\n\n" + dailyFragment
            }
        }
        prompt += memoryStatusFragment
        return prompt
    }

    /// Route one turn through the pi runtime. Returns true when pi handled the
    /// turn (the caller must not run the legacy loop); false = fall back.
    func runPiTurnIfEligible(text: String) async -> Bool {
        guard piRuntimeIsEligible else { return false }
        guard let entry = resolveCurrentEntry() else { return false }
        let store = ProviderConfigStore.shared
        guard let instance = store.instance(for: entry.providerInstanceId) else { return false }
        guard let spec = Self.makePiLaunchSpec(entry: entry, instance: instance) else {
            AppLogger(category: "PiRuntime").error("pi launch spec unresolved for entry \(entry.id)")
            return false
        }

        let prompt = buildPiSystemPrompt()
        let controller = PiRuntimeSessionController(
            rootfsDataURL: RootfsManager.shared.dataPath,
            spec: spec,
            sessionFile: piSessionFile()
        )
        piSessionController = controller
        controller.delegate = self
        piToolNamesByCallId = [:]

        do {
            try controller.start(systemPrompt: prompt)
        } catch {
            AppLogger(category: "PiRuntime").error("pi start failed: \(error)")
            piSessionController = nil
            return false
        }
        piTurnErrorAttachedToBubble = false

        let turnError = await controller.runTurn(text: text)

        // Let pi's autosave queue flush the transcript to disk, then record
        // which session file it created so the next turn resumes it.
        try? await Task.sleep(nanoseconds: 600_000_000)
        recordPiSessionFile()

        if let turnError, !turnError.isEmpty {
            AppLogger(category: "PiRuntime").error("pi turn error: \(turnError)")
            // piControllerDidEndTurn(error:) already attached the error to the
            // assistant bubble and persisted it; only surface the global banner
            // when the turn failed before any assistant message existed.
            if !piTurnErrorAttachedToBubble {
                errorMessage = turnError
            }
        }

        // Per-turn process lifecycle: the session is persisted by pi to its
        // --session sqlite file, so the next turn relaunches and resumes.
        // Tear the process down to avoid leaking a running pi per turn.
        controller.terminate()
        piSessionController = nil
        return true
    }
}

// MARK: - Launch spec (provider → pi mapping)

extension AIChatViewModel {

    /// Map the app's provider type to a pi provider id (Phase-0 provider matrix).
    static func piProviderID(for type: ProviderType) -> String? {
        switch type {
        case .anthropic: return "anthropic"
        case .openAI, .openAIResponses: return "openai"
        case .gemini: return "google"
        case .xAI: return "xai"
        case .openRouter: return "openrouter"
        case .antigravity: return "google-antigravity"
        case .kimiCode: return "kimi"
        case .unsupported: return nil
        }
    }

    /// Resolve a usable credential string for the instance (API key or OAuth
    /// bearer token) from the keychain.
    static func resolvePiCredential(instance: ProviderInstance) -> String? {
        switch instance.credentialType {
        case .apiKey:
            return ProviderKeychainHelper.loadAPIKey(instanceId: instance.id)
        case .oauth:
            return ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token")
        }
    }

    static func makePiLaunchSpec(entry: ModelEntry, instance: ProviderInstance) -> PiRuntimeLaunchSpec? {
        guard let piProvider = piProviderID(for: instance.providerType) else { return nil }
        var baseURL = instance.customBaseURL
        if let url = baseURL, !url.hasSuffix("/v1"), instance.appendV1Suffix {
            baseURL = url.hasSuffix("/") ? url + "v1" : url + "/v1"
        }
        return PiRuntimeLaunchSpec(
            piProvider: piProvider,
            modelId: entry.model.id,
            apiKey: resolvePiCredential(instance: instance),
            baseURL: baseURL,
            headers: [:],
            thinkingLevel: "off",
            guestCwd: "/root"
        )
    }
}

// MARK: - Delegate (event → UI + persistence)

extension AIChatViewModel: PiRuntimeSessionControllerDelegate {

    func piControllerDidStartTurn(sessionId: String) {
        messages.append(ChatMessage(role: .assistant, content: "", blocks: []))
        piTurnAssistantIndex = messages.count - 1
    }

    func piController(_ controller: PiRuntimeSessionController, didUpdateText text: String) {
        guard let idx = piTurnAssistantIndex, idx < messages.count else { return }
        let msg = messages[idx]
        if let textBlock = msg.blocks.first(where: { $0.kind == .text }) {
            textBlock.content = text
        } else {
            let block = AssistantBlock(kind: .text, content: text)
            msg.blocks.append(block)
        }
    }

    func piController(_ controller: PiRuntimeSessionController, didUpdateThinking thinking: String) {
        guard let idx = piTurnAssistantIndex, idx < messages.count else { return }
        let msg = messages[idx]
        if let thinkingBlock = msg.blocks.first(where: { $0.kind == .thinking }) {
            thinkingBlock.content = thinking
            thinkingBlock.flushThinkingBuffer()
        } else {
            let block = AssistantBlock(kind: .thinking, content: thinking)
            if let textIdx = msg.blocks.firstIndex(where: { $0.kind == .text }) {
                msg.blocks.insert(block, at: textIdx)
            } else {
                msg.blocks.append(block)
            }
        }
    }

    func piController(_ controller: PiRuntimeSessionController,
                      didStartTool callId: String,
                      name: String,
                      arguments: String) {
        guard let idx = piTurnAssistantIndex, idx < messages.count else { return }
        let msg = messages[idx]
        let block = AssistantBlock(
            kind: Self.assistantBlockKind(for: name, argumentsJSON: arguments),
            content: "",
            toolStatus: .running,
            toolUseId: callId
        )
        block.toolInputArgs = arguments
        block.toolStartTime = Date()
        msg.blocks.append(block)
        piToolNamesByCallId[callId] = name
    }

    func piController(_ controller: PiRuntimeSessionController,
                      didUpdateTool callId: String,
                      output: String) {
        guard let idx = piTurnAssistantIndex, idx < messages.count else { return }
        let msg = messages[idx]
        guard let block = msg.blocks.first(where: { $0.toolUseId == callId }) else { return }
        block.content = output
        block.toolStatus = .streaming(bytes: output.utf8.count)
    }

    func piController(_ controller: PiRuntimeSessionController,
                      didEndTool callId: String,
                      output: String,
                      success: Bool) {
        guard let idx = piTurnAssistantIndex, idx < messages.count else { return }
        let msg = messages[idx]
        guard let block = msg.blocks.first(where: { $0.toolUseId == callId }) else { return }
        block.content = output
        if let start = block.toolStartTime {
            block.toolDuration = Date().timeIntervalSince(start)
        }
        if success {
            block.toolStatus = .success
        } else {
            block.toolStatus = .failed(message: String(output.suffix(300)))
        }
    }

    func piControllerDidEndTurn(error: String?) {
        piToolNamesByCallId = [:]
        let msgIndex = piTurnAssistantIndex
        piTurnAssistantIndex = nil
        if let error, !error.isEmpty {
            piTurnErrorAttachedToBubble = true
            if let msgIndex, msgIndex < messages.count {
                messages[msgIndex].error = error
            }
        }
        guard let msgIndex, msgIndex < messages.count else { return }
        let msg = messages[msgIndex]
        for block in msg.blocks {
            if case .text = block.kind, !block.content.isEmpty {
                block.cachedMarkdown = MarkdownContent(prepareMarkdownForRender(block.content))
                cacheAttributedString(for: block)
            }
        }
        Task { [weak self] in
            await self?.persistPiTurn(messageIndex: msgIndex)
        }
    }

    func piController(_ controller: PiRuntimeSessionController, didReceiveStderr line: String) {
        AppLogger(category: "PiRuntime").info("[pi] \(line)")
    }

    func piController(_ controller: PiRuntimeSessionController, didChangeRunning isRunning: Bool) {
        AppLogger(category: "PiRuntime").info("pi running=\(isRunning)")
    }

    // MARK: Persistence

    private func persistPiTurn(messageIndex: Int) async {
        guard messageIndex < messages.count else { return }
        let msg = messages[messageIndex]
        var parts: [AgentContentPart] = []

        for block in msg.blocks where block.kind == .text && !block.content.isEmpty {
            parts.append(.text(block.content))
        }

        for block in msg.blocks where block.toolUseId != nil {
            let callId = block.toolUseId ?? UUID().uuidString
            let name = piToolNamesByCallId[callId] ?? "tool"
            var input: [String: Any] = [:]
            if let args = block.toolInputArgs,
               let data = args.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                input = parsed
            }
            parts.append(.toolUse(id: callId, name: name, input: input))
            let isError: Bool
            if case .failed = block.toolStatus { isError = true } else { isError = false }
            parts.append(.toolResult(id: callId, name: name, content: block.content, isError: isError))
        }

        let agentMsg = AgentMessage(role: .assistant, parts: parts)
        let historyIdx = agentHistory.count
        agentHistory.append(agentMsg)
        if let pid = await persistAgentMessage(agentMsg), historyIdx < agentHistory.count {
            agentHistory[historyIdx].dbMessageId = pid
            // Persist the turn error now that the assistant row exists
            // (persistErrorInfo is a no-op before dbMessageId is set).
            if let err = msg.error, !err.isEmpty {
                await persistErrorInfo(err)
            }
        }
    }

    // MARK: Tool block mapping

    /// Map a pi tool name + JSON args to the app's rendering block kind.
    static func assistantBlockKind(for toolName: String, argumentsJSON: String) -> AssistantBlockKind {
        let name = toolName.lowercased()
        let args = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)
        )) as? [String: Any]
        let path = args?["path"] as? String ?? ""
        switch name {
        case "bash":
            return .shellTool(command: args?["command"] as? String ?? "")
        case "read":
            return path.isEmpty ? .fileReadTool(path: "") : .fileReadTool(path: path)
        case "write":
            return path.isEmpty ? .fileWriteTool(path: "") : .fileWriteTool(path: path)
        case "edit", "hashline_edit":
            return path.isEmpty ? .fileEditTool(path: "") : .fileEditTool(path: path)
        case "grep", "find", "ls":
            return .shellTool(command: "\(name) \(path)")
        case "browser_use", "browser":
            return .browserTool(action: args?["action"] as? String ?? "")
        default:
            return .shellTool(command: name)
        }
    }
}
