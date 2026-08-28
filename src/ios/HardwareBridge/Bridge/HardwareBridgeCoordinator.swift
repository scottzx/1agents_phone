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

    private let transcriber = HardwareVoiceTranscriber()
    private var sequence: UInt8 = 0
    private var cancellables = Set<AnyCancellable>()

    /// The hardware-bridge chat session, scoped to one BLE connection. Reset
    /// on disconnect so a fresh connection starts a fresh conversation.
    private var activeSessionId: String?

    init() {
        bluetooth.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        bluetooth.$state
            .sink { [weak self] state in
                guard let self, state == .idle else { return }
                self.activeSessionId = nil
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
    }

    private func transcribeAndForward(pcm16: Data, truncated: Bool) async {
        guard activity != .waitingForAgent, activity != .transcribing else {
            appendLog("已有 Turn 运行，忽略本次音频")
            return
        }
        activity = .transcribing
        appendLog("音频转写中：\(pcm16.count) 字节\(truncated ? "（截断）" : "")")
        do {
            let text = try await transcriber.transcribe(pcm16: pcm16)
            lastTranscript = text
            appendLog("转写结果：\(text)")
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

        let vm = resolveSessionViewModel()
        if activeSessionId == nil {
            vm.sessionSource = "hardware"
            let sid = await vm.ensureSessionReturningId()
            activeSessionId = sid
        }
        if let sid = activeSessionId {
            _ = BackgroundKeepAliveManager.shared.armEagerlyForShortcut(sessionId: sid, caller: "HardwareBridgeCoordinator")
        }

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
        appendLog("Agent → screen0：\(replyText)")
        do {
            try sendToDevice(replyText)
            activity = .delivered
        } catch {
            await failAndReleaseDevice(error.localizedDescription)
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

    private func sendToDevice(_ text: String) throws {
        sequence &+= 1
        try bluetooth.sendScreenText(text, sequence: sequence)
    }

    private func failAndReleaseDevice(_ message: String) async {
        activity = .failed(message)
        appendLog("错误：\(message)")
        try? sendToDevice("ERROR")
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        bridgeLog.append("\(formatter.string(from: Date()))  \(text)")
        if bridgeLog.count > 80 { bridgeLog.removeFirst(bridgeLog.count - 80) }
        print("[HardwareBridgeCoordinator] \(text)")
    }
}
