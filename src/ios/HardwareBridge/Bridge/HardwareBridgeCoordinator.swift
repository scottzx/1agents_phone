import Combine
import Foundation

/// Glues the BLE hardware link to Minis's existing agent loop. Not a port of
/// AgentBridge's BridgeCoordinator — that file's core job is calling the
/// remote AgentStackClient (cloud HTTP), which has no equivalent here: the
/// "brain" is the local AIChatViewModel this app already ships.
///
/// Session handling mirrors Agent/Intents/SendPromptIntent.swift's headless
/// "no UI to drive send() from" pattern: set inputText, call send(), await
/// $isProcessing draining, extract the last assistant message's text.
@MainActor
final class HardwareBridgeCoordinator: ObservableObject {
    enum Activity: Equatable {
        case idle
        case transcribing
        case waitingForAgent
        case synthesizing
        case deliveringAudio
        case delivered
        case failed(String)
    }

    /// Lazily created on first access (e.g. when the user opens the Hardware
    /// settings screen) — NOT instantiated at app launch, since constructing
    /// HardwareBLECentral's CBCentralManager can itself trigger the system
    /// Bluetooth permission prompt.
    static let shared = HardwareBridgeCoordinator()

    let bluetooth = HardwareBLECentral()

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastReply = ""
    @Published private(set) var bridgeLog: [String] = []
    /// Latest battery report from the device (0x14). Nil until one arrives.
    @Published private(set) var batteryLevel: UInt8?
    @Published private(set) var batteryState: AgentLinkEvent.PowerState?
    /// Most recent value per generic-I/O endpoint (0x19), keyed by endpoint id.
    @Published private(set) var readings: [String: String] = [:]
    /// The roster last pushed to the device, for the settings screen to show.
    @Published private(set) var pushedRoster: DeviceRosterSnapshot?

    /// How the roster reaches the device. Defaults to the route that needs no
    /// firmware change, so the bridge is usable before the SDK grows a 0x37
    /// handler.
    @Published var rosterTransport: HardwareBLECentral.RosterTransport = .ioEndpoint
    /// Where reply audio comes out. Defaults to Plan A with Plan B standing by
    /// (DEMO_PRD.md §6).
    @Published var voiceRoute: HardwareVoiceOutput.Route = .auto

    /// When set, a prompt from the device goes to this group's orchestrator
    /// instead of to a single agent's session. Nil is the original behavior —
    /// one board, one agent, one conversation.
    @Published var activeGroupId: String?

    private let speechClient = MossSpeechClient.shared
    private let transcriber = HardwareVoiceTranscriber.shared
    private var sequence: UInt8 = 0
    private var voiceSessionID: UInt32 = 0
    private var cancellables = Set<AnyCancellable>()

    /// The hardware-bridge chat session, scoped to one BLE connection. Reset
    /// on disconnect so a fresh connection starts a fresh conversation.
    private var activeSessionId: String?
    /// Per-conversation message counter carried in every chat payload, so the
    /// device can notice a dropped frame.
    private var chatSequence: UInt32 = 0

    init() {
        bluetooth.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        bluetooth.$state
            .sink { [weak self] state in
                guard let self else { return }
                if state == .idle {
                    self.activeSessionId = nil
                    self.chatSequence = 0
                    self.pushedRoster = nil
                    self.batteryLevel = nil
                    self.batteryState = nil
                    self.readings.removeAll()
                    DeviceRosterService.shared.unbind()
                } else if state.isReady {
                    // The board sends its manifest unprompted after we
                    // subscribe to 0xFFC4, but a re-subscribe on reconnect can
                    // race that; a 0x34 fetch makes it deterministic.
                    self.bluetooth.requestIoManifest()
                    self.pushRosterIfNeeded()
                }
            }
            .store(in: &cancellables)
        bluetooth.onPrompt = { [weak self] prompt in
            guard let self else { return }
            Task { await self.forward(prompt: prompt) }
        }
        bluetooth.onAudioStreamFinished = { [weak self] pcm16, truncated in
            guard let self else { return }
            Task { await self.transcribeAndForward(pcm16: pcm16, truncated: truncated) }
        }
        bluetooth.onPowerStatus = { [weak self] state, level in
            self?.batteryState = state
            self?.batteryLevel = level
        }
        bluetooth.onReading = { [weak self] endpointId, value in
            self?.readings[endpointId] = value.displayText
        }
        bluetooth.onManifest = { [weak self] _ in
            // A board that only now declares a screen/speaker may need the
            // roster it couldn't have rendered before.
            self?.pushRosterIfNeeded()
        }
        bluetooth.onSelectedAgent = { [weak self] _, agentId in
            guard let self else { return }
            self.appendLog("设备选择了 Agent \(agentId)，重新绑定会话名册")
            self.pushRosterIfNeeded(preferredAgentId: agentId)
        }

        // Keep a connected device's roster current when an agent is renamed or
        // recolored, without waiting for the next turn.
        DeviceRosterService.shared.$snapshot
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] snapshot in self?.pushRoster(snapshot) }
            .store(in: &cancellables)
    }

    private func transcribeAndForward(pcm16: Data, truncated: Bool) async {
        guard !isTurnRunning else {
            appendLog("已有 Turn 运行，忽略本次音频")
            return
        }
        activity = .transcribing
        let seconds = Double(pcm16.count) / 32_000
        let segmentCount = max(1, Int(ceil(seconds / Double(HardwareVoiceTranscriber.defaultSegmentSeconds))))
        appendLog(String(
            format: "设备音频 → 本地 SenseVoice：%.1f 秒，%d 段%@",
            seconds,
            segmentCount,
            truncated ? "（链路截断）" : ""
        ))
        do {
            let text = try await transcriber.transcribeSegmented(pcm16: pcm16)
            lastTranscript = text
            appendLog("本地 SenseVoice → 文本：\(text)")
            await forward(prompt: text)
        } catch {
            await failAndReleaseDevice(error.localizedDescription)
        }
    }

    private func forward(prompt: String) async {
        guard activity != .waitingForAgent else {
            appendLog("已有 Turn 运行，忽略重复 Prompt")
            return
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activity = .waitingForAgent
        appendLog("Prompt → Agent：\(trimmed)")

        BackgroundKeepAliveManager.shared.setup()

        // A bound group takes the whole turn: the orchestrator drives the
        // roster push, the per-speaker state events and the chat0 messages
        // itself, and hands back the closing line for TTS. Everything below
        // this branch is the single-agent path, unchanged.
        if let groupId = activeGroupId {
            await forwardToGroup(groupId: groupId, prompt: trimmed)
            return
        }

        let vm = resolveSessionViewModel()
        if activeSessionId == nil {
            vm.sessionSource = "hardware"
            let sid = await vm.ensureSessionReturningId()
            activeSessionId = sid
        }
        if let sid = activeSessionId {
            _ = BackgroundKeepAliveManager.shared.armEagerlyForShortcut(sessionId: sid, caller: "HardwareBridgeCoordinator")
        }

        // Now that the session and its agent are resolved, the device can be
        // told who it is talking to. Cheap and idempotent: the service only
        // emits a snapshot when the content actually changed.
        pushRosterIfNeeded(preferredAgentId: vm.agentId)

        guard !vm.isProcessing else {
            await failAndReleaseDevice("Agent 正忙")
            return
        }

        vm.inputText = trimmed
        vm.send()

        for await processing in vm.$isProcessing.values {
            if !processing { break }
        }

        let replyText = SendPromptIntent.extractResponseText(from: vm)
        lastReply = replyText
        let sender = DeviceRosterService.shared.sender(preferring: vm.agentId)
        do {
            try deliverText(replyText, from: sender)
        } catch {
            await failAndReleaseDevice(error.localizedDescription)
            return
        }

        await speak(replyText)
    }

    /// Sends the reply text to the device with its sender attached, falling
    /// back to the bare `screen0` text endpoint.
    ///
    /// `chat0` is the forward-compatible path: it carries `from`, so a group
    /// conversation needs no firmware change to show who is speaking. It is
    /// only usable once the board registers that endpoint, so `screen0` — the
    /// one the board has always had — remains the fallback rather than the
    /// primary.
    private func deliverText(_ text: String, from sender: DeviceParticipant?) throws {
        guard let sender, let conversationId = activeSessionId else {
            appendLog("Agent → screen0：\(text)")
            try sendToDevice(text)
            return
        }

        chatSequence &+= 1
        let message = DeviceChatMessage(
            conversationId: conversationId,
            from: sender.id,
            sequence: chatSequence,
            text: text
        )
        do {
            try bluetooth.sendChatMessage(message)
            appendLog("Agent → chat0（\(sender.emoji) \(sender.name)）：\(text)")
        } catch {
            // A board without a `chat0` endpoint NAKs the actuate; the text
            // still has to arrive, so fall through to the screen endpoint
            // rather than failing the turn.
            appendLog("chat0 下发失败（\(error.localizedDescription)），回落 screen0")
            try sendToDevice(text)
        }
    }

    /// Speaks the reply, on the device when it can and on the phone when it
    /// can't. Never fails the turn: the text has already been delivered.
    private func speak(_ text: String) async {
        guard let apiKey = activeMossAPIKey() else {
            activity = .failed("缺少 MOSS_API_KEY，文字已发送但无法合成语音")
            appendLog("错误：缺少 MOSS_API_KEY，跳过 TTS")
            return
        }

        if voiceRoute == .phone {
            await speakOnPhone(text, reason: nil)
            return
        }

        let deviceReady = bluetooth.state.isReady && bluetooth.l2capReceiver.isWritable
        guard deviceReady else {
            let reason = "设备音频通道未就绪"
            if voiceRoute == .auto {
                await speakOnPhone(text, reason: reason)
            } else {
                activity = .failed(reason)
                appendLog("错误：\(reason)")
            }
            return
        }

        let sanitized = VoiceTextSanitizer.sanitize(text)
        let segments = AIChatViewModel.splitIntoSpeechSegments(sanitized)
        guard !segments.isEmpty else {
            activity = .failed("回复没有可朗读内容")
            return
        }

        voiceSessionID &+= 1
        sequence &+= 1
        let startSequence = sequence
        sequence &+= 1
        let endSequence = sequence
        let sessionID = voiceSessionID
        var streamStarted = false
        var deliveredBytes = 0

        do {
            activity = .synthesizing
            try await bluetooth.beginVoicePCM16(sessionID: sessionID, sequence: startSequence)
            streamStarted = true

            for (index, segment) in segments.enumerated() {
                try Task.checkCancellation()
                appendLog("流式 TTS 第 \(index + 1)/\(segments.count) 段：\(segment)")
                deliveredBytes += try await speechClient.streamSynthesizePCM16(
                    text: segment,
                    apiKey: apiKey,
                    onChunk: { [weak self] pcm16 in
                        guard let self else { return }
                        await MainActor.run { self.activity = .deliveringAudio }
                        try await self.bluetooth.appendVoicePCM16(pcm16)
                    }
                )
            }

            try bluetooth.endVoicePCM16(sessionID: sessionID, sequence: endSequence)
            streamStarted = false
            activity = .delivered
            appendLog("设备流式播报 \(segments.count) 段，\(deliveredBytes) 字节")
        } catch {
            if streamStarted {
                try? bluetooth.endVoicePCM16(sessionID: sessionID, sequence: endSequence)
            }
            appendLog("设备流式播报失败：\(error.localizedDescription)")
            if voiceRoute == .auto {
                await speakOnPhone(text, reason: error.localizedDescription)
            } else {
                activity = .failed(error.localizedDescription)
            }
        }
    }

    private func speakOnPhone(_ text: String, reason: String?) async {
        let outcome = await HardwareVoiceOutput.shared.speak(
            text,
            route: .phone,
            phoneSessionId: activeSessionId ?? "hardware-bridge",
            delivery: .init(
                synthesize: { _ in Data() },
                sendToDevice: { _ in },
                deviceReady: { false },
                willSpeak: { _, _, _ in }
            )
        )
        let description = reason.map { "\(outcome.logDescription)（设备原因：\($0)）" }
            ?? outcome.logDescription
        appendLog(description)
        switch outcome {
        case .spokeOnPhone:
            activity = .delivered
        case .phoneMuted, .skipped, .spokeOnDevice:
            activity = .failed(description)
        }
    }

    /// Run one device prompt through a group and speak whatever the room
    /// concluded with.
    private func forwardToGroup(groupId: String, prompt: String) async {
        guard let group = await GroupStore.shared.loadGroup(groupId) else {
            await failAndReleaseDevice("群聊不存在，已断开绑定")
            activeGroupId = nil
            return
        }
        activeSessionId = group.sessionId
        appendLog("Prompt → 群聊「\(group.title)」")

        let closing = await GroupChatOrchestrator.shared.run(groupId: groupId, userText: prompt)
        guard let closing, !closing.isEmpty else {
            await failAndReleaseDevice("群里没有人发言")
            return
        }
        lastReply = closing
        // The text of every speaker already went down as it was said; only the
        // closing line is spoken, so the device does not narrate the whole room.
        await speak(closing)
    }

    /// Push one group message to the device, attributed to the member that said
    /// it. Never throws: a room must run identically with no board attached.
    func deliverGroupMessage(_ text: String, fromAgentId: String) {
        guard bluetooth.state.isReady else { return }
        let sender = DeviceRosterService.shared.sender(preferring: fromAgentId)
        do {
            try deliverText(text, from: sender)
        } catch {
            appendLog("群消息下发失败：\(error.localizedDescription)")
        }
    }

    private func resolveSessionViewModel() -> AIChatViewModel {
        if let sid = activeSessionId {
            let (vm, _) = ViewModelCache.shared.getOrCreate(for: sid)
            return vm
        }
        return ViewModelCache.shared.createDraft()
    }

    func resetSession() {
        activeSessionId = nil
        activity = .idle
        appendLog("已重置硬件会话，下次将创建新 Session")
    }

    /// Rebuilds the roster for the active session and pushes it if it changed.
    ///
    /// Safe to call often — `DeviceRosterService.bind` returns nil when the
    /// snapshot is byte-identical to the one the device already has, so a
    /// repeat call costs no BLE traffic and no redraw on the device.
    func pushRosterIfNeeded(preferredAgentId: String? = nil) {
        guard let conversationId = activeSessionId else { return }
        let agentId = preferredAgentId
            ?? pushedRoster?.members.first?.id
            ?? AgentProfile.defaultAgentId
        guard let profile = AgentStore.shared.agent(agentId) else { return }

        // One member today. The roundtable passes four ids here and everything
        // downstream — snapshot, wire format, device rendering — is unchanged.
        // The push itself is driven by the `$snapshot` subscription in `init`,
        // which is the single place a roster reaches the wire — binding here as
        // well would send every roster twice.
        DeviceRosterService.shared.bind(
            conversationId: conversationId,
            title: profile.name,
            agentIds: [profile.id]
        )
    }

    private func pushRoster(_ snapshot: DeviceRosterSnapshot) {
        guard bluetooth.state.isReady else { return }
        do {
            let frames = try bluetooth.sendRoster(snapshot, transport: rosterTransport)
            pushedRoster = snapshot
            appendLog("名册已下发（\(rosterTransport.displayName)，\(frames) 帧）")
        } catch {
            appendLog("名册下发失败：\(error.localizedDescription)")
        }
    }

    /// Pushes a round-screen state transition (DEMO_PRD.md §5).
    ///
    /// Exposed rather than driven from here because the orchestration that
    /// decides which expert is speaking is work package A; this is the wire
    /// end of it, ready for that caller.
    func sendState(_ state: DeviceRoundtableState, name: String, brief: String = "") {
        guard bluetooth.state.isReady else { return }
        do {
            try bluetooth.sendStateEvent(DeviceStateEvent(state: state, name: name, textBrief: brief))
        } catch {
            appendLog("state0 下发失败：\(error.localizedDescription)")
        }
    }

    private func sendToDevice(_ text: String) throws {
        sequence &+= 1
        try bluetooth.sendScreenText(text, sequence: sequence)
    }

    private func sendAudioToDevice(_ pcm16: Data) async throws {
        voiceSessionID &+= 1
        sequence &+= 1
        let startSequence = sequence
        sequence &+= 1
        let endSequence = sequence
        try await bluetooth.sendVoicePCM16(
            pcm16,
            sessionID: voiceSessionID,
            startSequence: startSequence,
            endSequence: endSequence
        )
    }

    private func failAndReleaseDevice(_ message: String) async {
        activity = .failed(message)
        appendLog("错误：\(message)")
        if lastReply.isEmpty { try? sendToDevice("ERROR") }
    }

    private var isTurnRunning: Bool {
        switch activity {
        case .transcribing, .waitingForAgent, .synthesizing, .deliveringAudio:
            return true
        case .idle, .delivered, .failed:
            return false
        }
    }

    private func activeMossAPIKey() -> String? {
        let stored = EnvVarStore.shared.value(forKey: MossSpeechClient.apiKeyEnvironmentName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
#if DEBUG
        let environment = ProcessInfo.processInfo.environment[MossSpeechClient.apiKeyEnvironmentName]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environment, !environment.isEmpty { return environment }
#endif
        let bundled = MossSpeechClient.bundledTestAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return bundled.isEmpty ? nil : bundled
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        bridgeLog.append("\(formatter.string(from: Date()))  \(text)")
        if bridgeLog.count > 80 { bridgeLog.removeFirst(bridgeLog.count - 80) }
        print("[HardwareBridgeCoordinator] \(text)")
    }
}
