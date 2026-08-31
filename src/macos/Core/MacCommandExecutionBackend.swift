import Foundation
import Darwin
import MinisPOSIX

public struct CommandRequest: Sendable, Equatable {
    public let command: String
    public let workingDirectory: URL
    public let sessionID: String
    public let agentID: String?
    public let environment: [String: String]
    public let timeout: TimeInterval?

    public init(command: String, workingDirectory: URL, sessionID: String, agentID: String? = nil, environment: [String: String] = [:], timeout: TimeInterval? = nil) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.agentID = agentID
        self.environment = environment
        self.timeout = timeout
    }
}

public struct CommandResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let wasCancelled: Bool
}

public enum CommandError: LocalizedError, Sendable, Equatable {
    case launchFailed(String)
    case outputLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): "Unable to start shell command: \(message)"
        case .outputLimitExceeded: "Shell output exceeded the configured safety limit."
        }
    }
}

/// macOS command backend. Commands use a fresh login shell and a constrained
/// environment; this intentionally does not share the user-visible PTY.
public actor MacCommandExecutionBackend {
    public static let defaultOutputLimit = 1_048_576
    private var running: [UUID: pid_t] = [:]
    private var cancelled = Set<UUID>()
    private let outputLimit: Int

    public init(outputLimit: Int = MacCommandExecutionBackend.defaultOutputLimit) {
        self.outputLimit = outputLimit
    }

    public func execute(_ request: CommandRequest) async throws -> CommandResult {
        let id = UUID()
        let input = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let environment = shellEnvironment(for: request)
        let shell = resolvedShell()
        let pid: pid_t = try withEnvironment(environment) { environmentPointer in
            shell.withCString { shellPath in
                request.workingDirectory.path.withCString { cwd in
                    minis_spawn_command(shellPath, cwd, environmentPointer, input.fileHandleForReading.fileDescriptor, stdout.fileHandleForWriting.fileDescriptor, stderr.fileHandleForWriting.fileDescriptor)
                }
            }
        }
        guard pid > 0 else { throw CommandError.launchFailed(String(cString: strerror(errno))) }
        try? input.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        running[id] = pid

        // Start draining both streams before awaiting process termination. A
        // child that emits more than a pipe buffer must never deadlock merely
        // because the desktop client is waiting for its exit status.
        let perStreamLimit = max(1, outputLimit / 2)
        async let outputData = Self.readOutput(from: stdout.fileHandleForReading, limit: perStreamLimit, pid: pid)
        async let errorData = Self.readOutput(from: stderr.fileHandleForReading, limit: perStreamLimit, pid: pid)
        input.fileHandleForWriting.write(Data(request.command.utf8))
        input.fileHandleForWriting.write(Data("\nexit\n".utf8))
        try? input.fileHandleForWriting.close()

        let timeoutTask: Task<Void, Never>?
        if let timeout = request.timeout {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await self?.cancel(id)
            }
        } else {
            timeoutTask = nil
        }
        defer { timeoutTask?.cancel() }

        let exitTask = Task.detached(priority: .utility) { minis_wait_exit_code(pid) }
        let exitCode = await withTaskCancellationHandler(operation: {
            await exitTask.value
        }, onCancel: {
            Task { await self.cancel(id) }
        })
        let out = await outputData
        let err = await errorData
        let wasCancelled = cancelled.remove(id) != nil
        running.removeValue(forKey: id)
        guard !out.exceeded, !err.exceeded, out.data.count + err.data.count <= outputLimit else { throw CommandError.outputLimitExceeded }
        return CommandResult(
            stdout: String(decoding: out.data, as: UTF8.self),
            stderr: String(decoding: err.data, as: UTF8.self),
            exitCode: exitCode,
            wasCancelled: wasCancelled
        )
    }

    public func cancel(_ id: UUID) {
        guard let pid = running[id] else { return }
        cancelled.insert(id)
        _ = kill(-pid, SIGTERM)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            _ = Darwin.kill(-pid, SIGKILL)
        }
    }

    public func cancelAll() {
        for id in Array(running.keys) { cancel(id) }
    }

    private struct CapturedOutput: Sendable {
        let data: Data
        let exceeded: Bool
    }

    private nonisolated static func readOutput(from handle: FileHandle, limit: Int, pid: pid_t) async -> CapturedOutput {
        await Task.detached(priority: .utility) {
            var data = Data()
            var exceeded = false
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                let remaining = limit - data.count
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
                if chunk.count > remaining, !exceeded {
                    exceeded = true
                    _ = Darwin.kill(-pid, SIGTERM)
                    Task.detached(priority: .utility) {
                        try? await Task.sleep(for: .milliseconds(500))
                        _ = Darwin.kill(-pid, SIGKILL)
                    }
                }
            }
            return CapturedOutput(data: data, exceeded: exceeded)
        }.value
    }

    private func resolvedShell() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    private func shellEnvironment(for request: CommandRequest) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var result: [String: String] = [:]
        for key in ["HOME", "USER", "SHELL", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR"] {
            if let value = inherited[key] { result[key] = value }
        }
        result["MINIS_SESSION_ID"] = request.sessionID
        result["MINIS_WORKSPACE"] = request.workingDirectory.path
        if let agentID = request.agentID { result["MINIS_AGENT_ID"] = agentID }
        for (key, value) in request.environment where key.hasPrefix("MINIS_") { result[key] = value }
        return result
    }

    private nonisolated func withEnvironment<T>(_ environment: [String: String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> T) throws -> T {
        var pointers = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in try body(buffer.baseAddress) }
    }
}
