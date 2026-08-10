//
//  PiRuntimeSessionController.swift
//  Minis
//
//  Session-level controller for the `pi` agent runtime.
//
//  Owns a PiRuntimeBridge for one chat session and translates pi's AgentEvent
//  stream into UI-facing callbacks (streaming text, thinking, tool cards,
//  turn end) through the delegate protocol. The AIChatViewModel implements
//  the delegate by mutating its `messages` array, so the existing rendering
//  and ChatStore persistence pipelines stay untouched.
//
//  At launch the controller:
//    1. Writes the app's base system prompt to <rootfs>/root/.pi/agent/system_prompt.md
//       (passed to pi via --system-prompt),
//    2. Writes/refreshes <rootfs>/root/.pi/agent/models.json from the launch spec
//       (provider endpoints, headers; credentials go to the process environment),
//    3. Launches `pi --mode rpc --system-prompt <file> --provider <p> --model <m>`
//       with the session transcript file, then applies steering/compaction/retry
//       settings via RPC.
//
//  Resume: pi persists its own transcript under ~/.pi/agent/sessions; the same
//  session file is reused on relaunch so history is restored inside pi. The
//  app's ChatStore remains the UI/sync truth source.
//

import Foundation

/// Launch parameters for one pi session, resolved from the app's provider
/// configuration by the caller (AIChatViewModel / ProviderConfigStore).
struct PiRuntimeLaunchSpec {
    /// App provider identifier, mapped to a pi provider id.
    var piProvider: String
    /// Model id as pi should see it.
    var modelId: String
    /// API key (or access token) for the provider. Nil when pi can resolve it
    /// from its own auth (not used for now — always injected via env).
    var apiKey: String?
    /// Custom base URL for OpenAI-compatible endpoints (nil = provider default).
    var baseURL: String?
    /// Extra headers for the provider (e.g. OAuth bearer overrides).
    var headers: [String: String] = [:]
    /// pi thinking level: off/minimal/low/medium/high/xhigh/max.
    var thinkingLevel: String = "off"
    /// Guest cwd for the pi process (tool commands run here).
    var guestCwd: String = "/root"
}

/// UI-facing callbacks produced by mirroring pi AgentEvents. All delivered on
/// the main actor. Implemented by AIChatViewModel.
@MainActor
protocol PiRuntimeSessionControllerDelegate: AnyObject {
    /// The agent started a run (sessionId from pi).
    func piControllerDidStartTurn(sessionId: String)
    /// Streaming text delta. `text` is the full text so far.
    func piController(_ controller: PiRuntimeSessionController, didUpdateText text: String)
    /// Streaming thinking delta. `thinking` is the full reasoning so far.
    func piController(_ controller: PiRuntimeSessionController, didUpdateThinking thinking: String)
    /// A tool execution started (tool card appears).
    func piController(_ controller: PiRuntimeSessionController,
                      didStartTool callId: String,
                      name: String,
                      arguments: String)
    /// Partial tool output while the tool runs.
    func piController(_ controller: PiRuntimeSessionController,
                      didUpdateTool callId: String,
                      output: String)
    /// A tool execution finished. `output` is the final result.
    func piController(_ controller: PiRuntimeSessionController,
                      didEndTool callId: String,
                      output: String,
                      success: Bool)
    /// The turn finished. `error` is set when the run failed.
    func piControllerDidEndTurn(error: String?)
    /// A stderr/diagnostic line from the pi process.
    func piController(_ controller: PiRuntimeSessionController, didReceiveStderr line: String)
    /// Process-level state change (crash/restart).
    func piController(_ controller: PiRuntimeSessionController, didChangeRunning isRunning: Bool)
}

@MainActor
final class PiRuntimeSessionController {

    // MARK: State

    weak var delegate: PiRuntimeSessionControllerDelegate?

    private let bridge: PiRuntimeBridge
    private let rootfsDataURL: URL
    private let spec: PiRuntimeLaunchSpec
    private let sessionFile: String?
    private let fsContext: UInt64

    private var isTerminating = false
    private var turnState: PiTurnState?
    /// Resumed when the current turn finishes (agent_end or process exit).
    /// Value = turn error string, nil = success.
    private var turnCompletion: CheckedContinuation<String?, Never>?

    /// True when a turn (or restart) is in flight.
    private(set) var isRunning = false

    /// Guest path of the system prompt file pi reads via --system-prompt.
    static let guestSystemPromptPath = "/root/.pi/agent/system_prompt.md"

    /// Guest dir where pi persists session transcripts (--session-dir).
    /// pi names new sessions `<dir>/<cwd>/<timestamp>_<id>.{jsonl|sqlite}`,
    /// so the app discovers the created file after each turn and resumes it
    /// via `--session` on the next turn.
    static let guestSessionDirPath = "/root/.pi/agent/sessions"

    // MARK: Init

    /// - Parameters:
    ///   - rootfsDataURL: host URL of the guest rootfs `data/` dir
    ///     (RootfsManager.shared.dataPath). Used to write guest config files.
    ///   - spec: resolved provider/model launch parameters.
    ///   - sessionFile: guest path of the pi session transcript to resume
    ///     (e.g. `/root/.pi/agent/sessions/<sessionId>.sqlite`). Nil = new.
    ///   - fsContext: per-session fs_context stamp (0 = default).
    init(rootfsDataURL: URL,
         spec: PiRuntimeLaunchSpec,
         sessionFile: String?,
         fsContext: UInt64 = 0) {
        self.rootfsDataURL = rootfsDataURL
        self.spec = spec
        self.sessionFile = sessionFile
        self.fsContext = fsContext

        var arguments = ["--mode", "rpc"]
        arguments += ["--system-prompt", Self.guestSystemPromptPath]
        arguments += ["--provider", spec.piProvider, "--model", spec.modelId]
        if let apiKey = spec.apiKey, !apiKey.isEmpty {
            arguments += ["--api-key", apiKey]
        }
        // New sessions are created under --session-dir; `--session` (resume)
        // is only passed when the target file already exists, because pi
        // errors with SessionNotFound on a missing file.
        arguments += ["--session-dir", Self.guestSessionDirPath]
        if let sessionFile {
            arguments += ["--session", sessionFile]
        }
        arguments += ["--cwd", spec.guestCwd]

        // Credentials + provider routing via env (kept out of models.json so
        // the on-disk skeleton never stores secrets).
        var environment: [String: String] = [:]
        let envKey = "PI_\(spec.piProvider.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
        if let apiKey = spec.apiKey, !apiKey.isEmpty {
            environment[envKey] = apiKey
        }
        if let baseURL = spec.baseURL, !baseURL.isEmpty {
            environment["PI_\(spec.piProvider.uppercased().replacingOccurrences(of: "-", with: "_"))_BASE_URL"] = baseURL
        }

        self.bridge = PiRuntimeBridge(
            configuration: .init(
                executablePath: "/usr/local/bin/pi",
                arguments: arguments,
                environment: environment,
                fsContext: fsContext
            )
        )
    }

    // MARK: Lifecycle

    /// Write guest config (system prompt + models.json) and launch pi.
    func start(systemPrompt: String) throws {
        try writeGuestConfig(systemPrompt: systemPrompt)
        bridge.delegate = self
        try bridge.start()
        isRunning = true
        delegate?.piController(self, didChangeRunning: true)
    }

    func terminate() {
        isTerminating = true
        isRunning = false
        bridge.terminate()
        delegate?.piController(self, didChangeRunning: false)
    }

    // MARK: Turn control

    /// Run one full turn: send the user message, stream events through the
    /// delegate, and return when pi reports `agent_end`.
    /// - Returns: the turn error string (nil = success).
    func runTurn(text: String, images: [PiRPCImagePayload] = []) async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                turnCompletion = continuation
                Task { @MainActor in
                    do {
                        _ = try await self.bridge.sendPrompt(message: text, images: images)
                    } catch {
                        if let completion = self.turnCompletion {
                            self.turnCompletion = nil
                            completion.resume(returning: error.localizedDescription)
                        }
                    }
                }
            }
        } onCancel: {
            // The hosting task (sendMessage) was cancelled (Stop button, etc.).
            // Ask pi to abort the in-flight turn; pi answers with agent_end and
            // the continuation below resumes through the normal event path.
            Task { @MainActor in
                do {
                    try await self.bridge.abort(timeout: 5)
                } catch {
                    if let completion = self.turnCompletion {
                        self.turnCompletion = nil
                        completion.resume(returning: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Send a user message (new turn) without awaiting turn completion.
    /// Throws on transport failure; turn-level errors arrive via
    /// `piControllerDidEndTurn(error:)`.
    func sendUserMessage(text: String, images: [PiRPCImagePayload] = []) async throws {
        _ = try await bridge.sendPrompt(message: text, images: images)
    }

    /// Queue a follow-up while the agent is busy (steering). Requires the
    /// current turn to be streaming.
    func steer(text: String, images: [PiRPCImagePayload] = []) async throws {
        _ = try await bridge.sendPrompt(message: text, images: images, streamingBehavior: .steer)
    }

    /// Queue a follow-up while the agent is busy (follow-up queue).
    func queueFollowUp(text: String, images: [PiRPCImagePayload] = []) async throws {
        _ = try await bridge.sendPrompt(message: text, images: images, streamingBehavior: .followUp)
    }

    func abortTurn() async {
        _ = try? await bridge.abort(timeout: 5)
    }

    /// Ask pi to quit gracefully (drains the current turn).
    func requestStop() {
        bridge.terminate()
    }

    // MARK: Guest config

    private func writeGuestConfig(systemPrompt: String) throws {
        let fm = FileManager.default
        let piDir = rootfsDataURL.appendingPathComponent("root/.pi/agent")
        try fm.createDirectory(at: piDir, withIntermediateDirectories: true)

        // system_prompt.md — full replacement of pi's default prompt.
        try systemPrompt.write(to: piDir.appendingPathComponent("system_prompt.md"),
                               atomically: true, encoding: .utf8)

        // models.json — refresh provider entry for this launch (no secrets).
        let isAnthropic = spec.piProvider == "anthropic" || spec.piProvider == "anthropic-messages"
        var providerConfig: [String: Any] = [
            "api": isAnthropic ? "anthropic-messages" : "openai-compatible",
            "models": [
                ["id": spec.modelId, "name": spec.modelId],
            ],
        ]
        if let baseURL = spec.baseURL, !baseURL.isEmpty {
            providerConfig["baseUrl"] = baseURL
        }
        let modelsPayload: [String: Any] = ["providers": [spec.piProvider: providerConfig]]
        let data = try JSONSerialization.data(withJSONObject: modelsPayload, options: [.prettyPrinted])
        let modelsURL = piDir.appendingPathComponent("models.json")
        // The every-boot default-mount overlay copies models.json from the app
        // bundle, and iOS ships bundle resources read-only (copyItem preserves
        // the source mode). A plain in-place `Data.write(to:)` then throws
        // EACCES and aborts start() before pi launches. Write atomically (temp
        // file + rename — rename only needs directory write access, the same
        // path that already works for system_prompt.md) and stamp an explicit
        // writable mode so later in-place updates also succeed.
        try data.write(to: modelsURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: modelsURL.path)
    }

    // MARK: Event accumulation

    /// Mutable per-turn accumulators fed by message_update deltas.
    private struct PiTurnState {
        var text = ""
        var thinking = ""
        var activeToolCallId: String?
    }

    private func handle(event: PiAgentEvent) {
        switch event {
        case .agentStart(let sessionId):
            turnState = PiTurnState()
            delegate?.piControllerDidStartTurn(sessionId: sessionId)

        case .agentEnd(_, _, let error):
            delegate?.piControllerDidEndTurn(error: error)
            turnState = nil
            if let completion = turnCompletion {
                turnCompletion = nil
                completion.resume(returning: error)
            }
            if isTerminating {
                isRunning = false
                delegate?.piController(self, didChangeRunning: false)
            }

        case .messageUpdate(_, let sub):
            if turnState == nil { turnState = PiTurnState() }
            guard var state = turnState else { return }
            switch sub.kind {
            case .textStart, .textDelta:
                if let delta = sub.delta, !delta.isEmpty {
                    state.text += delta
                    turnState = state
                    delegate?.piController(self, didUpdateText: state.text)
                }
            case .thinkingStart, .thinkingDelta:
                if let delta = sub.delta, !delta.isEmpty {
                    state.thinking += delta
                    turnState = state
                    delegate?.piController(self, didUpdateThinking: state.thinking)
                }
            default:
                break
            }

        case .toolExecutionStart(let callId, let toolName, let args):
            turnState?.activeToolCallId = callId
            let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            delegate?.piController(self, didStartTool: callId, name: toolName, arguments: argsJSON)

        case .toolExecutionUpdate(let callId, _, let partialResult):
            delegate?.piController(self, didUpdateTool: callId, output: partialResult)

        case .toolExecutionEnd(let callId, _, let result, let isError):
            delegate?.piController(self, didEndTool: callId, output: result, success: !isError)
            if turnState?.activeToolCallId == callId {
                turnState?.activeToolCallId = nil
            }

        case .autoCompactionStart(let reason):
            delegate?.piController(self, didReceiveStderr: "[pi:compaction] \(reason)")

        case .autoRetryStart(let attempt, _, _, let errorMessage):
            delegate?.piController(self, didReceiveStderr: "[pi:retry] attempt \(attempt): \(errorMessage)")

        case .extensionError(let extensionId, let event, let error):
            delegate?.piController(self, didReceiveStderr: "[pi:extension:\(extensionId ?? "?")] \(event): \(error)")

        default:
            break
        }
    }
}

// MARK: - PiRuntimeBridgeDelegate

extension PiRuntimeSessionController: PiRuntimeBridgeDelegate {
    func piRuntime(_ bridge: PiRuntimeBridge, didReceive event: PiAgentEvent) {
        handle(event: event)
    }

    func piRuntime(_ bridge: PiRuntimeBridge, didReceiveStderr line: String) {
        delegate?.piController(self, didReceiveStderr: line)
    }

    func piRuntime(_ bridge: PiRuntimeBridge, didExit code: Int, willRestart: Bool) {
        isRunning = false
        let exitError = "pi runtime exited (code \(code))"
        if let completion = turnCompletion {
            turnCompletion = nil
            completion.resume(returning: exitError)
        }
        delegate?.piController(self, didChangeRunning: false)
        // The current turn is dead either way — end it so the UI finalizes the
        // assistant message and persistence runs. (The bridge may relaunch pi
        // for the NEXT turn; the in-flight one cannot be resumed.)
        delegate?.piControllerDidEndTurn(error: exitError)
    }
}
