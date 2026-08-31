import Foundation
import Darwin

public protocol RuntimeClient: Sendable {
    func request(_ request: RuntimeRequest) async throws -> [RuntimeEvent]
    func events() async -> AsyncStream<RuntimeEvent>
    func shutdown() async
}

public actor DirectRuntimeClient: RuntimeClient {
    private let runtime: AgentRuntime
    private var active: [UUID: (sessionID: String?, task: Task<[RuntimeEvent], Never>)] = [:]

    public init(runtime: AgentRuntime) {
        self.runtime = runtime
    }

    public func request(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        if ["session.cancel", "group.cancel", "tool.cancel"].contains(request.method) {
            for (_, run) in active where request.sessionID != nil && run.sessionID == request.sessionID { run.task.cancel() }
            return await runtime.handle(request)
        }
        let task = Task { await runtime.handle(request) }
        active[request.requestID] = (request.sessionID, task)
        let events = await task.value
        active.removeValue(forKey: request.requestID)
        return events
    }

    public func events() async -> AsyncStream<RuntimeEvent> { await runtime.events() }

    public func shutdown() async {
        for run in active.values { run.task.cancel() }
        active.removeAll()
        _ = await runtime.handle(RuntimeRequest(method: "shutdown"))
    }
}

public enum RuntimeClientError: LocalizedError, Sendable {
    case helperNotFound(URL)
    case launchFailed(String)
    case disconnected
    case writeFailed(String)
    case safeMode

    public var errorDescription: String? {
        switch self {
        case .helperNotFound(let url): "Runtime helper not found at \(url.path)."
        case .launchFailed(let message): "Runtime helper failed to launch: \(message)"
        case .disconnected: "Runtime helper disconnected."
        case .writeFailed(let message): "Unable to write to Runtime helper: \(message)"
        case .safeMode: "The Runtime helper crashed repeatedly. Relaunch Minis to leave safe mode."
        }
    }
}

/// Long-lived, request-multiplexed stdio client. The helper emits a private
/// `response.completed` sentinel after each request; all preceding events keep
/// their documented names and sequence numbers.
public actor StdioRuntimeClient: RuntimeClient {
    private struct Pending {
        var events: [RuntimeEvent]
        let continuation: CheckedContinuation<[RuntimeEvent], Error>
    }

    private let executableURL: URL
    private var process: Process?
    private var processGeneration: UUID?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending: [UUID: Pending] = [:]
    private var readBuffer = Data()
    private var restartCount = 0
    private var isShuttingDown = false
    private var eventSubscribers: [UUID: AsyncStream<RuntimeEvent>.Continuation] = [:]

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func request(_ request: RuntimeRequest) async throws -> [RuntimeEvent] {
        try startIfNeeded()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[request.requestID] = Pending(events: [], continuation: continuation)
                do {
                    var data = try JSONEncoder.runtime.encode(request)
                    data.append(10)
                    try input?.write(contentsOf: data)
                } catch {
                    pending.removeValue(forKey: request.requestID)
                    continuation.resume(throwing: RuntimeClientError.writeFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            Task { await self.cancelPending(request) }
        }
    }

    public func shutdown() async {
        isShuttingDown = true
        if process?.isRunning == true {
            _ = try? await request(RuntimeRequest(method: "shutdown"))
        }
        output?.readabilityHandler = nil
        input?.closeFile()
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(1))
                if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
            }
        }
        failPending(RuntimeClientError.disconnected)
        processGeneration = nil
        process = nil
        input = nil
        output = nil
    }

    public func events() async -> AsyncStream<RuntimeEvent> {
        let id = UUID()
        let pair = AsyncStream<RuntimeEvent>.makeStream(bufferingPolicy: .bufferingNewest(4_096))
        eventSubscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return pair.stream
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        if isShuttingDown { throw RuntimeClientError.disconnected }
        // `Process.terminationHandler` is asynchronous. A request can arrive
        // after the child has exited but before its callback enters this
        // actor; consume that crash here before starting a replacement so it
        // cannot bypass the one-restart safe-mode budget.
        if process != nil {
            output?.readabilityHandler = nil
            processGeneration = nil
            process = nil
            input = nil
            output = nil
            failPending(RuntimeClientError.disconnected)
            if !isShuttingDown { restartCount += 1 }
        }
        guard restartCount <= 1 else { throw RuntimeClientError.safeMode }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw RuntimeClientError.helperNotFound(executableURL)
        }
        let process = Process()
        let generation = UUID()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = executableURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        do { try process.run() }
        catch { throw RuntimeClientError.launchFailed(error.localizedDescription) }

        self.process = process
        self.processGeneration = generation
        self.input = stdinPipe.fileHandleForWriting
        self.output = stdoutPipe.fileHandleForReading
        readBuffer.removeAll(keepingCapacity: true)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consume(data, generation: generation) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.helperExited(generation: generation) }
        }
    }

    private func consume(_ data: Data, generation: UUID) {
        guard generation == processGeneration else { return }
        guard !data.isEmpty else { return }
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 10) {
            let frame = readBuffer[..<newline]
            readBuffer.removeSubrange(...newline)
            guard !frame.isEmpty,
                  let event = try? JSONDecoder.runtime.decode(RuntimeEvent.self, from: Data(frame)),
                  let requestID = event.requestID,
                  var item = pending[requestID] else { continue }
            if event.name == "response.completed" {
                pending.removeValue(forKey: requestID)
                item.continuation.resume(returning: item.events)
            } else {
                for subscriber in eventSubscribers.values { subscriber.yield(event) }
                item.events.append(event)
                pending[requestID] = item
            }
        }
        if readBuffer.count > 1_048_576 {
            readBuffer.removeAll(keepingCapacity: false)
            failPending(RuntimeClientError.disconnected)
            process?.terminate()
        }
    }

    private func cancelPending(_ request: RuntimeRequest) {
        guard let item = pending.removeValue(forKey: request.requestID) else { return }
        item.continuation.resume(throwing: CancellationError())
        let cancellation = RuntimeRequest(method: "tool.cancel", sessionID: request.sessionID, payload: .object(["requestId": .string(request.requestID.uuidString)]))
        if var data = try? JSONEncoder.runtime.encode(cancellation) {
            data.append(10)
            try? input?.write(contentsOf: data)
        }
    }

    private func helperExited(generation: UUID) async {
        // Process termination callbacks are delivered asynchronously. An old
        // helper may report its exit after a later request has already started
        // the replacement; only the current generation may tear down stdio or
        // advance the crash counter.
        guard generation == processGeneration else { return }
        output?.readabilityHandler = nil
        processGeneration = nil
        process = nil
        input = nil
        output = nil
        failPending(RuntimeClientError.disconnected)
        // A later request may restart once. Repeated crashes leave the client
        // in safe mode until the user relaunches the app.
        guard !isShuttingDown else { return }
        restartCount += 1
        guard restartCount == 1 else { return }
        do {
            _ = try await request(RuntimeRequest(method: "initialize"))
            _ = try await request(RuntimeRequest(method: "runtime.snapshot"))
        } catch {
            restartCount = 2
        }
    }

    private func failPending(_ error: Error) {
        let active = pending.values
        pending.removeAll()
        for item in active { item.continuation.resume(throwing: error) }
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventSubscribers.removeValue(forKey: id)
    }
}

public struct UnavailableRuntimeClient: RuntimeClient {
    private let error: RuntimeClientError

    public init(error: RuntimeClientError) {
        self.error = error
    }

    public func request(_ request: RuntimeRequest) async throws -> [RuntimeEvent] { throw error }
    public func events() async -> AsyncStream<RuntimeEvent> { AsyncStream { $0.finish() } }
    public func shutdown() async {}
}
