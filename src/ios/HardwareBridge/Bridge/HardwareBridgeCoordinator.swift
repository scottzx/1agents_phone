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

    /// How the roster reaches the device. Defaults to picking per payload: the
    /// chat-list catalog is kilobytes and has to fragment, while a bound
    /// single-agent roster still goes out in the one write it always did.
    @Published var rosterTransport: HardwareBLECentral.RosterTransport = .auto
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
            // `@Published` publishes in `willSet`, so inside this sink
            // `bluetooth.state` is still the previous value — and everything
            // below reaches code that guards on it (`sendCommand`, `pushRoster`).
            // A hop to the next runloop turn means "ready" really means ready.
            .receive(on: RunLoop.main)
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
                    // The device draws its whole chat list — every group and
                    // every one-to-one agent — from this snapshot, so it goes
                    // out on connect rather than waiting for a first turn to
                    // create a session. Each of these binds *and* rebuilds, and
                    // the `$snapshot` sink below is what puts it on the wire, so
                    // only a real change costs a push.
                    if let groupId = self.activeGroupId {
                        Task {
                            await self.rebind(groupId: groupId)
                            self.deliverCurrentRoster()
                        }
                    } else {
                        self.pushRosterIfNeeded()
                        // Covers a link that comes up before AgentStore has
                        // finished bootstrapping, when there is no agent to
                        // bind but there may already be groups to list.
                        DeviceRosterService.shared.rebuild()
                        self.deliverCurrentRoster()
                    }
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
        bluetooth.onSelectedAgent = { [weak self] index, entryId in
            guard let self else { return }
            Task { await self.selectConversation(entryId: entryId, index: index) }
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
        // The text is delivered by `speak`, one line at a time as each is
        // spoken. Sending the whole reply up front instead left the board's
        // fixed-size label showing only the first line for the entire minute of
        // audio, and pushed replies past the single-frame chat0 budget so they
        // fell back to bare screen0 text with no sender attached.
        let sender = DeviceRosterService.shared.sender(preferring: vm.agentId)
        await speak(replyText, narrating: sender)
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
    private func speak(_ text: String, narrating sender: DeviceParticipant? = nil) async {
        // Whenever the reply will not be spoken segment by segment, the device
        // still has to receive it, so each early exit below delivers it whole.
        func deliverWhole() {
            guard let sender else { return }
            try? deliverText(text, from: sender)
        }

        guard let apiKey = activeMossAPIKey() else {
            deliverWhole()
            activity = .failed("缺少 MOSS_API_KEY，文字已发送但无法合成语音")
            appendLog("错误：缺少 MOSS_API_KEY，跳过 TTS")
            return
        }

        if voiceRoute == .phone {
            deliverWhole()
            await speakOnPhone(text, reason: nil)
            return
        }

        let sanitized = VoiceTextSanitizer.sanitize(text)
        let segments = AIChatViewModel.splitIntoSpeechSegments(sanitized)
        guard !segments.isEmpty else {
            deliverWhole()
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

            // Synthesise the next clause while the current one is still being
            // delivered. Each clause costs two round trips (ask for a URL, then
            // download it), and doing that between clauses left an audible hole
            // in every sentence boundary. Overlapping hides it behind playback.
            func synthesize(_ clause: String) -> Task<Data, Error> {
                Task { try await self.speechClient.synthesizePCM16(text: clause, apiKey: apiKey) }
            }
            var inFlight = segments.isEmpty ? nil : synthesize(segments[0])

            for (index, segment) in segments.enumerated() {
                try Task.checkCancellation()
                // The whole clause is in hand before any of it goes out, so a
                // network hiccup cannot empty the board's playback queue
                // mid-word.
                activity = .synthesizing
                guard let current = inFlight else { break }
                let pcm16 = try await current.value
                inFlight = index + 1 < segments.count ? synthesize(segments[index + 1]) : nil
                // On screen just before it is heard, so the text tracks the voice.
                if let sender { try? deliverText(segment, from: sender) }
                appendLog(String(format: "TTS 第 %d/%d 段（%d 字节，%.1f 秒）：%@",
                                 index + 1, segments.count, pcm16.count,
                                 Double(pcm16.count) / 2 / Double(MossSpeechClient.deviceSampleRate),
                                 segment))
                activity = .deliveringAudio
                try await bluetooth.appendVoicePCM16(pcm16)
                deliveredBytes += pcm16.count
            }

            try bluetooth.endVoicePCM16(sessionID: sessionID, sequence: endSequence)
            streamStarted = false
            activity = .delivered
            // If the board takes noticeably more or less time than this to play
            // it back, the stream's sample rate is not what
            // MossSpeechClient.sourceValuesPerDeviceSample assumes.
            let seconds = Double(deliveredBytes) / 2 / Double(MossSpeechClient.deviceSampleRate)
            appendLog(String(format: "设备播报 %d 段，%d 字节，应为 %.1f 秒",
                             segments.count, deliveredBytes, seconds))
            // The one line that settles the sample-rate question, in the app
            // rather than on a console that keeps detaching.
            appendLog("TTS 源：\(MossSpeechClient.lastStreamDescription)")
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
        // A bound group belongs to GroupChatOrchestrator; rebinding it to a
        // single agent here would point the screen at the wrong room.
        guard activeGroupId == nil else { return }
        let agentId = preferredAgentId ?? boundDirectAgentId ?? AgentProfile.defaultAgentId
        guard let profile = AgentStore.shared.agent(agentId) else { return }

        // The bound conversation is keyed by agent id, matching the catalog
        // entry the device echoes back when it opens that row. The push itself
        // is driven by the `$snapshot` subscription in `init`, which is the
        // single place a roster reaches the wire — sending here as well would
        // put every roster on the link twice.
        DeviceRosterService.shared.bind(
            conversationId: profile.id,
            title: profile.name,
            agentIds: [profile.id]
        )
    }

    /// The agent the device is currently pointed at, when it is a one-to-one
    /// row. Nil for a group and before anything has been pushed.
    private var boundDirectAgentId: String? {
        guard let pushedRoster,
              let entry = pushedRoster.entry(pushedRoster.conversation.id),
              entry.kind == .direct else { return nil }
        return entry.id
    }

    /// The device opened a row in its chat list (0x16, carrying the catalog
    /// entry id it was given). Point the phone at the same conversation so the
    /// next thing said into the board lands in the room the user is looking at.
    private func selectConversation(entryId: String, index: UInt8) async {
        if let group = await resolveGroup(entryId) {
            let count = await bind(group: group)
            appendLog("设备打开群聊「\(group.title)」（#\(index)，\(count) 位成员）")
            return
        }

        if let profile = AgentStore.shared.agent(entryId) {
            activeGroupId = nil
            chatSequence = 0
            activeSessionId = await AgentStore.shared.openMainSession(for: profile.id)
            appendLog("设备打开单聊「\(profile.name)」（#\(index)）")
            DeviceRosterService.shared.bind(
                conversationId: profile.id,
                title: profile.name,
                agentIds: [profile.id]
            )
            return
        }

        appendLog("设备选择了未知会话 \(entryId)（#\(index)），已忽略")
    }

    /// Re-points a reconnecting device at the group it was already bound to,
    /// rather than letting the first catalog row take over.
    private func rebind(groupId: String) async {
        guard let group = await resolveGroup(groupId) else {
            pushRosterIfNeeded()
            return
        }
        _ = await bind(group: group)
    }

    /// Reads through to the store, so a group created or edited elsewhere this
    /// launch resolves without waiting for `GroupStore` to refresh.
    private func resolveGroup(_ id: String) async -> GroupProfile? {
        if let cached = GroupStore.shared.group(id) { return cached }
        return await GroupStore.shared.loadGroup(id)
    }

    /// Points the phone at one group. Returns its resolved member count.
    @discardableResult
    private func bind(group: GroupProfile) async -> Int {
        activeGroupId = group.id
        activeSessionId = group.sessionId
        chatSequence = 0
        let members = await GroupStore.shared.members(of: group)
        DeviceRosterService.shared.bind(
            conversationId: group.id,
            title: group.title,
            agentIds: members.map(\.id)
        )
        return members.count
    }

    /// Sends whatever the roster currently is, unless the device already has it.
    ///
    /// The `$snapshot` subscription only fires on *change*, and the catalog is
    /// normally built at launch — long before a board connects. Without this, a
    /// link coming up against an unchanged roster publishes nothing and the
    /// device sits on an empty chat list for the whole session.
    private func deliverCurrentRoster() {
        guard let snapshot = DeviceRosterService.shared.snapshot else { return }
        pushRoster(snapshot)
    }

    private func pushRoster(_ snapshot: DeviceRosterSnapshot) {
        guard bluetooth.state.isReady, !snapshot.rendersSameAs(pushedRoster) else { return }
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
