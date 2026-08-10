//
//  PiRuntimeBridge.swift
//  Minis
//
//  Long-lived transport to the `pi` agent runtime (`pi --mode rpc`) running
//  inside the iSH guest sandbox.
//
//  Owns an `ISHShellPersistentProcess` (see ISHShellExecutor.h), correlates
//  responses with requests by `id`, and forwards decoded events to the
//  delegate. Request/response correlation is single-threaded: calls must be
//  made from the main actor, and pi processes commands sequentially.
//
//  Wire protocol types (requests, responses, AgentEvent decoding) live in
//  PiRPCWire.swift — keep this file free of pure-protocol code so the wire
//  layer stays unit-testable without the iSH runtime.
//

import Foundation

/// Delegate callbacks from the bridge (all delivered on the main actor).
@MainActor
protocol PiRuntimeBridgeDelegate: AnyObject {
    /// A typed agent event arrived on stdout.
    func piRuntime(_ bridge: PiRuntimeBridge, didReceive event: PiAgentEvent)
    /// A stderr line arrived (diagnostics only).
    func piRuntime(_ bridge: PiRuntimeBridge, didReceiveStderr line: String)
    /// The process exited unexpectedly (not via `terminate()`).
    /// `willRestart` is true when the bridge is about to relaunch.
    func piRuntime(_ bridge: PiRuntimeBridge, didExit code: Int, willRestart: Bool)
}

@MainActor
final class PiRuntimeBridge {

    // MARK: Configuration

    struct Configuration {
        /// Guest path to the pi binary.
        var executablePath: String = "/usr/local/bin/pi"
        /// Extra CLI args (e.g. `["--mode", "rpc"]` or `["--system-prompt", "/root/.pi/agent/system_prompt.md"]`).
        var arguments: [String] = ["--mode", "rpc"]
        /// Environment for the guest process (credentials, provider selection).
        var environment: [String: String] = [:]
        /// Per-session fs_context stamp (0 = default global view).
        var fsContext: UInt64 = 0
        /// Seconds to wait for a command response before failing.
        var responseTimeout: TimeInterval = 60
        /// Backoff (seconds) between crash-restarts; doubles per failure.
        var restartBaseDelay: TimeInterval = 1.0
        /// Maximum restart backoff.
        var restartMaxDelay: TimeInterval = 30.0
        /// Cap on consecutive auto-restarts before giving up.
        var maxConsecutiveRestarts: Int = 5
    }

    // MARK: State

    weak var delegate: PiRuntimeBridgeDelegate?

    private(set) var configuration: Configuration
    private var process: ISHShellPersistentProcess?
    private var pendingRequests: [String: CheckedContinuation<PiRPCResponse, Error>] = [:]
    private var requestIDs = 0
    private var isTerminating = false
    private var consecutiveRestarts = 0
    private var restartTask: Task<Void, Never>?

    /// True while the process is alive (or a restart is pending).
    private(set) var isRunning = false

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: Lifecycle

    /// Launch the pi process. Safe to call when already running (no-op).
    func start() throws {
        guard process == nil else { return }
        isTerminating = false
        let config = configuration
        let handle = ISHShellExecutor.launchPersistentExecutable(
            config.executablePath,
            arguments: config.arguments,
            environment: config.environment,
            fsContext: config.fsContext,
            lineCallback: { [weak self] line, isStdErr in
                Task { @MainActor [weak self] in
                    self?.handleLine(line, isStdErr: isStdErr)
                }
            },
            exitCallback: { [weak self] exitCode, _ in
                Task { @MainActor [weak self] in
                    self?.handleExit(exitCode: Int(exitCode))
                }
            }
        )
        guard let handle else {
            throw PiBridgeError.launchFailed("ISHShellExecutor returned nil handle")
        }
        process = handle
        isRunning = true
        consecutiveRestarts = 0
    }

    /// Ask pi to quit (RPC mode exits after draining the current turn) and
    /// tear down the process group. After this, `start()` can be called again.
    func terminate() {
        isTerminating = true
        restartTask?.cancel()
        restartTask = nil
        failAllPending(with: PiBridgeError.notRunning)
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// Whether the process is currently alive (not merely scheduled).
    var isProcessAlive: Bool { process != nil }

    // MARK: RPC commands

    @discardableResult
    func sendPrompt(message: String,
                    images: [PiRPCImagePayload] = [],
                    streamingBehavior: PiStreamingBehavior? = nil,
                    timeout: TimeInterval? = nil) async throws -> PiRPCResponse {
        let id = nextRequestID()
        let request = PiRPCRequestFactory.prompt(
            message: message, images: images, streamingBehavior: streamingBehavior, id: id
        )
        return try await send(request: request, timeout: timeout)
    }

    @discardableResult
    func abort(timeout: TimeInterval? = nil) async throws -> PiRPCResponse {
        try await send(request: PiRPCRequestFactory.simple("abort", id: nextRequestID()),
                       timeout: timeout)
    }

    @discardableResult
    func getState(timeout: TimeInterval? = nil) async throws -> PiRPCResponse {
        try await send(request: PiRPCRequestFactory.simple("get_state", id: nextRequestID()),
                       timeout: timeout)
    }

    @discardableResult
    func getMessages(timeout: TimeInterval? = nil) async throws -> PiRPCResponse {
        try await send(request: PiRPCRequestFactory.simple("get_messages", id: nextRequestID()),
                       timeout: timeout)
    }

    @discardableResult
    func setModel(provider: String, modelId: String,
                  timeout: TimeInterval? = nil) async throws -> PiRPCResponse {
        let request = PiRPCRequestFactory.setModel(
            provider: provider, modelId: modelId, id: nextRequestID()
        )
        return try await send(request: request, timeout: timeout)
    }

    @discardableResult
    func setSteeringMode(_ mode: PiQueueMode, timeout: TimeInterval? = nil) async throws -> PiRPCResponse {
        let request = PiRPCRequestFactory.setQueueMode(
            "set_steering_mode", mode: mode, id: nextRequestID()
        )
        return try await send(request: request, timeout: timeout)
    }

    @discardableResult
    func setFollowUpMode(_ mode: PiQueueMode, timeout: TimeInterval? = nil) async throws -> PiRPCResponse {
        let request = PiRPCRequestFactory.setQueueMode(
            "set_follow_up_mode", mode: mode, id: nextRequestID()
        )
        return try await send(request: request, timeout: timeout)
    }

    @discardableResult
    func setAutoCompaction(enabled: Bool, timeout: TimeInterval? = nil) async throws -> PiRPCResponse {
        let request = PiRPCRequestFactory.setAuto(
            "set_auto_compaction", enabled: enabled, id: nextRequestID()
        )
        return try await send(request: request, timeout: timeout)
    }

    @discardableResult
    func setAutoRetry(enabled: Bool, timeout: TimeInterval? = nil) async throws -> PiRPCResponse {
        let request = PiRPCRequestFactory.setAuto(
            "set_auto_retry", enabled: enabled, id: nextRequestID()
        )
        return try await send(request: request, timeout: timeout)
    }

    // MARK: Core send/receive

    private func send(request: [String: Any],
                      timeout: TimeInterval?) async throws -> PiRPCResponse {
        guard let process else {
            throw PiBridgeError.notRunning
        }
        let id = request["id"] as? String ?? nextRequestID()
        let effectiveTimeout = timeout ?? configuration.responseTimeout

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            let deadlineTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard let continuation = self.pendingRequests.removeValue(forKey: id) else {
                    return
                }
                continuation.resume(throwing: PiBridgeError.timedOut(command: request["type"] as? String ?? "?"))
            }

            guard let payloadData = try? JSONSerialization.data(withJSONObject: request),
                  let line = String(data: payloadData, encoding: .utf8),
                  process.writeLine(line) else {
                pendingRequests.removeValue(forKey: id)
                deadlineTask.cancel()
                continuation.resume(throwing: PiBridgeError.notRunning)
                return
            }
            // The deadline task keeps itself alive via the strong `self` capture
            // above; if the continuation completes first it removes the entry and
            // the task no-ops. No retain on deadlineTask needed beyond the Task
            // itself, which is owned by the runtime.
        }
    }

    private func nextRequestID() -> String {
        requestIDs += 1
        return "pi-\(requestIDs)-\(UUID().uuidString.prefix(8))"
    }

    // MARK: Line pump

    private func handleLine(_ line: String, isStdErr: Bool) {
        if isStdErr {
            delegate?.piRuntime(self, didReceiveStderr: line)
            return
        }
        guard !PiRPCLineParser.isIgnorable(line) else { return }

        if let response = PiRPCLineParser.decodeResponse(line) {
            handle(response: response)
            return
        }
        if let event = PiRPCLineParser.decodeEvent(line) {
            delegate?.piRuntime(self, didReceive: event)
            return
        }
        // Unparseable stdout: log it, do not crash the bridge.
        delegate?.piRuntime(self, didReceiveStderr: "[pi:stdout] \(line)")
    }

    private func handle(response: PiRPCResponse) {
        guard let id = response.id, let continuation = pendingRequests.removeValue(forKey: id) else {
            // Response without a matching pending request (e.g. a prompt ack
            // whose continuation already timed out) — nothing to do.
            return
        }
        if response.success {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: PiRPCCommandError(response: response))
        }
    }

    private func handleExit(exitCode: Int) {
        let wasTerminating = isTerminating
        process = nil
        isRunning = false
        failAllPending(with: PiBridgeError.processExited(command: "pending", exitCode: exitCode))

        guard !wasTerminating else { return }
        delegate?.piRuntime(self, didExit: exitCode, willRestart: true)
        scheduleRestart(after: configuration.restartBaseDelay)
    }

    private func scheduleRestart(after delay: TimeInterval) {
        guard consecutiveRestarts < configuration.maxConsecutiveRestarts else {
            delegate?.piRuntime(self, didExit: -1, willRestart: false)
            return
        }
        consecutiveRestarts += 1
        let backoff = min(delay, configuration.restartMaxDelay)
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard let self, !Task.isCancelled, self.process == nil else { return }
            do {
                try self.start()
            } catch {
                self.scheduleRestart(after: self.configuration.restartBaseDelay * 2)
            }
        }
    }

    private func failAllPending(with error: PiBridgeError) {
        let pending = pendingRequests
        pendingRequests = [:]
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }
}
