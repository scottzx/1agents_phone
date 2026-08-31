import Foundation
import Darwin
import MinisPOSIX

public struct TerminalSize: Sendable, Equatable {
    public let columns: UInt16
    public let rows: UInt16

    public init(columns: UInt16 = 100, rows: UInt16 = 30) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

public enum TerminalEvent: Sendable, Equatable {
    case output(Data)
    case exited(Int32)
}

public protocol TerminalBackend: Sendable {
    func create(workingDirectory: URL, size: TerminalSize) async throws -> (id: UUID, events: AsyncStream<TerminalEvent>)
    func input(_ data: Data, sessionID: UUID) async throws
    func resize(_ size: TerminalSize, sessionID: UUID) async throws
    func signal(_ signal: Int32, sessionID: UUID) async
    func close(sessionID: UUID) async
}

public enum TerminalBackendError: LocalizedError, Sendable {
    case spawn(Int32)
    case unknownSession
    case io(Int32)

    public var errorDescription: String? {
        switch self {
        case .spawn(let code): "Unable to create terminal: \(String(cString: strerror(code)))."
        case .unknownSession: "The terminal session no longer exists."
        case .io(let code): "Terminal I/O failed: \(String(cString: strerror(code)))."
        }
    }
}

private final class TerminalProcess: @unchecked Sendable {
    let pid: pid_t
    let handle: FileHandle
    let continuation: AsyncStream<TerminalEvent>.Continuation

    init(pid: pid_t, handle: FileHandle, continuation: AsyncStream<TerminalEvent>.Continuation) {
        self.pid = pid
        self.handle = handle
        self.continuation = continuation
    }
}

/// Interactive host terminal. PTY ownership stays in the Runtime; consumers
/// receive bytes and never share the Agent command backend's pipes.
public actor MacTerminalBackend: TerminalBackend {
    private var sessions: [UUID: TerminalProcess] = [:]

    public init() {}

    public func create(workingDirectory: URL, size: TerminalSize) async throws -> (id: UUID, events: AsyncStream<TerminalEvent>) {
        let shell = resolvedShell()
        var master: Int32 = -1
        let pid = shell.withCString { shellPath in
            workingDirectory.path.withCString { cwd in minis_spawn_pty(shellPath, cwd, &master) }
        }
        guard pid > 0, master >= 0 else { throw TerminalBackendError.spawn(errno) }
        guard minis_resize_pty(master, size.columns, size.rows) == 0 else {
            let code = errno
            Darwin.close(master)
            _ = Darwin.kill(-pid, SIGTERM)
            throw TerminalBackendError.io(code)
        }

        let id = UUID()
        let pair = AsyncStream<TerminalEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let handle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let process = TerminalProcess(pid: pid, handle: handle, continuation: pair.continuation)
        sessions[id] = process

        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { pair.continuation.yield(.output(data)) }
        }
        Task.detached(priority: .utility) { [weak self] in
            let exitCode = minis_wait_exit_code(pid)
            await self?.finished(id: id, exitCode: exitCode)
        }
        return (id, pair.stream)
    }

    public func input(_ data: Data, sessionID: UUID) async throws {
        guard let session = sessions[sessionID] else { throw TerminalBackendError.unknownSession }
        var offset = 0
        while offset < data.count {
            let count: Int = data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(session.handle.fileDescriptor, base.advanced(by: offset), data.count - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw TerminalBackendError.io(errno)
            }
            offset += count
        }
    }

    public func resize(_ size: TerminalSize, sessionID: UUID) async throws {
        guard let session = sessions[sessionID] else { throw TerminalBackendError.unknownSession }
        guard minis_resize_pty(session.handle.fileDescriptor, size.columns, size.rows) == 0 else { throw TerminalBackendError.io(errno) }
        _ = Darwin.kill(-session.pid, SIGWINCH)
    }

    public func signal(_ signal: Int32, sessionID: UUID) async {
        guard let session = sessions[sessionID] else { return }
        _ = Darwin.kill(-session.pid, signal)
    }

    public func close(sessionID: UUID) async {
        guard let session = sessions[sessionID] else { return }
        _ = Darwin.kill(-session.pid, SIGHUP)
        _ = Darwin.kill(-session.pid, SIGTERM)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            _ = Darwin.kill(-session.pid, SIGKILL)
        }
    }

    private func finished(id: UUID, exitCode: Int32) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.handle.readabilityHandler = nil
        try? session.handle.close()
        session.continuation.yield(.exited(exitCode))
        session.continuation.finish()
    }

    private nonisolated func resolvedShell() -> String {
        let path = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: path) ? path : "/bin/zsh"
    }
}
