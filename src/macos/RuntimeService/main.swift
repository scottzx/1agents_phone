import Foundation
import MinisDesktopCore
import Darwin
import MinisPOSIX

@main
struct MinisRuntimeService {
    static func main() async {
        let store: DesktopStore
        let override = ProcessInfo.processInfo.environment["MINIS_RUNTIME_BASE_URL"].map(URL.init(fileURLWithPath:))
        let lockURL: URL = {
            if let override { return override.appendingPathComponent("runtime.lock") }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return support.appendingPathComponent("Minis/Runtime/runtime.lock")
        }()
        guard let instanceLock = try? RuntimeInstanceLock(url: lockURL) else {
            FileHandle.standardError.write(Data("Another Minis Runtime already owns the desktop store.\n".utf8))
            Darwin.exit(EX_TEMPFAIL)
        }
        _ = instanceLock
        do { store = try DesktopStore(baseURL: override) }
        catch {
            FileHandle.standardError.write(Data("Minis Runtime database error: \(error.localizedDescription)\n".utf8))
            Darwin.exit(EX_CANTCREAT)
        }
        await importLegacyStoreIfNeeded(into: store)
        let host = RuntimeServiceHost(runtime: AgentRuntime(store: store), writer: RuntimeOutputWriter())
        let input = FileHandle.standardInput
        while true {
            switch input.readFrame(maxBytes: 1_048_576) {
            case .eof:
                await host.finishInput()
                return
            case .empty:
                continue
            case .oversize:
                await host.writeUnscopedError("Runtime request exceeds the 1 MiB frame limit.")
            case .frame(let data):
                do {
                    let request = try JSONDecoder.runtime.decode(RuntimeRequest.self, from: data)
                    await host.submit(request)
                } catch {
                    await host.writeUnscopedError("Malformed Runtime request: \(error.localizedDescription)")
                }
            }
        }
    }
}

private func importLegacyStoreIfNeeded(into store: DesktopStore) async {
    let alreadyImported = (try? await store.metadata(Bool.self, for: "legacy.ios.import.v1")) == true
    guard !alreadyImported else { return }
    let environment = ProcessInfo.processInfo.environment
    let explicit = environment["MINIS_LEGACY_CHATSTORE_PATH"].map(URL.init(fileURLWithPath:))
    let historical = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/MinisChat/minis.db")
    guard let source = [explicit, historical].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
    do {
        let result = try await LegacyChatStoreImporter(databaseURL: source).importInto(store)
        try await store.setMetadata(true, for: "legacy.ios.import.v1")
        FileHandle.standardError.write(Data("Imported legacy ChatStore: \(result.conversations) sessions, \(result.messages) messages.\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("Legacy ChatStore import skipped: \(error.localizedDescription)\n".utf8))
    }
}

private final class RuntimeInstanceLock {
    private let descriptor: Int32

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = minis_acquire_instance_lock(url.path)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let value = Data("\(getpid())\n".utf8)
        _ = value.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    deinit {
        minis_release_instance_lock(descriptor)
    }
}

private actor RuntimeServiceHost {
    private struct ActiveRun {
        let sessionID: String?
        let task: Task<Void, Never>
    }

    private let runtime: AgentRuntime
    private let writer: RuntimeOutputWriter
    private var active: [UUID: ActiveRun] = [:]

    init(runtime: AgentRuntime, writer: RuntimeOutputWriter) {
        self.runtime = runtime
        self.writer = writer
    }

    func submit(_ request: RuntimeRequest) {
        if request.method == "session.cancel" || request.method == "group.cancel" || request.method == "tool.cancel" {
            cancel(request)
            return
        }
        let task = Task { [runtime, writer] in
            await runtime.installEventSink(for: request.requestID) { event in writer.write([event]) }
            _ = await runtime.handle(request)
            await runtime.removeEventSink(for: request.requestID)
            writer.write([RuntimeEvent(requestID: request.requestID, name: "response.completed")])
            self.finished(request.requestID)
        }
        active[request.requestID] = ActiveRun(sessionID: request.sessionID, task: task)
    }

    func finishInput() async {
        let tasks = active.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        _ = await runtime.handle(RuntimeRequest(method: "shutdown"))
    }

    func writeUnscopedError(_ message: String) async {
        writer.write([RuntimeEvent(name: "runtime.error", error: message)])
    }

    private func cancel(_ request: RuntimeRequest) {
        let explicitRequestID: UUID? = {
            guard case .object(let object) = request.payload,
                  case .string(let raw)? = object["requestId"] else { return nil }
            return UUID(uuidString: raw)
        }()
        let matches = active.filter { key, run in
            explicitRequestID == key || (request.sessionID != nil && run.sessionID == request.sessionID)
        }
        for (_, run) in matches { run.task.cancel() }
        Task { [writer] in
            writer.write([
                RuntimeEvent(requestID: request.requestID, name: "session.updated", sessionID: request.sessionID, payload: .object(["state": .string(RuntimeState.cancelled.rawValue)])),
                RuntimeEvent(requestID: request.requestID, name: "response.completed")
            ])
        }
    }

    private func finished(_ requestID: UUID) {
        active.removeValue(forKey: requestID)
    }
}

private final class RuntimeOutputWriter: @unchecked Sendable {
    private let output = FileHandle.standardOutput
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder.runtime
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func write(_ events: [RuntimeEvent]) {
        lock.lock()
        defer { lock.unlock() }
        for event in events {
            guard var data = try? encoder.encode(event) else { continue }
            data.append(10)
            try? output.write(contentsOf: data)
        }
    }
}

private enum InputFrame {
    case frame(Data)
    case empty
    case oversize
    case eof
}

private extension FileHandle {
    func readFrame(maxBytes: Int) -> InputFrame {
        var data = Data()
        var exceeded = false
        while let byte = try? read(upToCount: 1), !byte.isEmpty {
            if byte[byte.startIndex] == 10 {
                if exceeded { return .oversize }
                return data.isEmpty ? .empty : .frame(data)
            }
            if data.count < maxBytes { data.append(byte) } else { exceeded = true }
        }
        if exceeded { return .oversize }
        return data.isEmpty ? .eof : .frame(data)
    }
}
