import Foundation
import MinisAppleDomain
import MinisProviderDomain

public struct RuntimeToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ProviderToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ProviderConversationMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String?
    public let toolCallID: String?
    public let toolCalls: [ProviderToolCall]?

    public init(role: String, content: String?, toolCallID: String? = nil, toolCalls: [ProviderToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}

public struct ProviderTurn: Sendable, Equatable {
    public let content: String?
    public let toolCalls: [ProviderToolCall]

    public init(content: String?, toolCalls: [ProviderToolCall] = []) {
        self.content = content
        self.toolCalls = toolCalls
    }
}

public protocol ToolCallingProviderRunner: ProviderRunner {
    func complete(
        messages: [ProviderConversationMessage],
        systemPrompt: String?,
        tools: [RuntimeToolDefinition],
        configuration: ProviderConfiguration
    ) async throws -> ProviderTurn
}

enum RuntimeToolError: LocalizedError {
    case invalidArguments(String)
    case unavailable(String)
    case outsideWorkspace(String)
    case approvalDenied
    case oversizedFile

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail): "Invalid tool arguments: \(detail)"
        case .unavailable(let name): "Tool is unavailable: \(name)"
        case .outsideWorkspace(let path): "The path is outside the granted workspace: \(path)"
        case .approvalDenied: "The user denied this macOS operation."
        case .oversizedFile: "The file exceeds the 1 MiB read limit."
        }
    }
}

struct RuntimeToolExecutor: Sendable {
    let shell: MacCommandExecutionBackend
    let workspace: URL
    let sessionID: String
    let agentID: String?

    static let definitions: [RuntimeToolDefinition] = [
        RuntimeToolDefinition(
            name: "shell_execute",
            description: "Run a non-interactive command in the explicitly granted macOS workspace. stdout and stderr are returned separately.",
            parameters: schema(properties: [
                "command": .object(["type": .string("string"), "description": .string("Shell script to execute.")]),
                "timeout_seconds": .object(["type": .string("integer"), "description": .string("Optional timeout from 1 to 600 seconds.")])
            ], required: ["command"])
        ),
        RuntimeToolDefinition(
            name: "file_read",
            description: "Read a UTF-8 text file inside the granted workspace.",
            parameters: schema(properties: ["path": .object(["type": .string("string"), "description": .string("Workspace-relative file path.")])], required: ["path"])
        ),
        RuntimeToolDefinition(
            name: "file_write",
            description: "Create or replace a UTF-8 text file inside the granted workspace.",
            parameters: schema(properties: [
                "path": .object(["type": .string("string"), "description": .string("Workspace-relative file path.")]),
                "content": .object(["type": .string("string"), "description": .string("Complete UTF-8 file contents.")])
            ], required: ["path", "content"])
        ),
        RuntimeToolDefinition(
            name: "file_list",
            description: "List a directory inside the granted workspace.",
            parameters: schema(properties: ["path": .object(["type": .string("string"), "description": .string("Workspace-relative directory path, or '.' for the root.")])], required: ["path"])
        ),
        RuntimeToolDefinition(
            name: "memory_read",
            description: "Read a Markdown memory file from this Agent's persistent memory directory.",
            parameters: schema(properties: ["path": .object(["type": .string("string"), "description": .string("Memory-relative path such as GLOBAL.md.")])], required: ["path"])
        ),
        RuntimeToolDefinition(
            name: "memory_write",
            description: "Create or replace a Markdown memory file for this Agent.",
            parameters: schema(properties: [
                "path": .object(["type": .string("string"), "description": .string("Memory-relative .md path.")]),
                "content": .object(["type": .string("string"), "description": .string("Complete Markdown contents.")])
            ], required: ["path", "content"])
        ),
        RuntimeToolDefinition(
            name: "skill_list",
            description: "List the Skills installed for the Minis desktop Runtime.",
            parameters: schema(properties: [:], required: [])
        ),
        RuntimeToolDefinition(
            name: "skill_read",
            description: "Read the SKILL.md instructions for an installed desktop Skill.",
            parameters: schema(properties: ["name": .object(["type": .string("string"), "description": .string("Exact Skill directory name from skill_list.")])], required: ["name"])
        )
    ]

    static func availableDefinitions(allowShell: Bool) -> [RuntimeToolDefinition] {
        allowShell ? definitions : definitions.filter { $0.name != "shell_execute" }
    }

    func execute(_ call: ProviderToolCall) async throws -> String {
        let arguments = try Self.arguments(call.arguments)
        switch call.name {
        case "shell_execute":
            guard let command = arguments.string("command"), !command.isEmpty else { throw RuntimeToolError.invalidArguments("shell_execute.command") }
            let requestedTimeout = arguments.int("timeout_seconds") ?? 120
            let timeout = TimeInterval(min(max(requestedTimeout, 1), 600))
            let result = try await shell.execute(CommandRequest(command: command, workingDirectory: workspace, sessionID: sessionID, agentID: agentID, timeout: timeout))
            return try Self.resultJSON([
                "stdout": result.stdout,
                "stderr": result.stderr,
                "exitCode": Int(result.exitCode),
                "cancelled": result.wasCancelled
            ])
        case "file_read":
            let url = try resolved(arguments, key: "path", forWriting: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if (attributes[.size] as? NSNumber)?.intValue ?? 0 > 1_048_576 { throw RuntimeToolError.oversizedFile }
            return try String(contentsOf: url, encoding: .utf8)
        case "file_write":
            guard let content = arguments.string("content") else { throw RuntimeToolError.invalidArguments("file_write.content") }
            let url = try resolved(arguments, key: "path", forWriting: true)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            return try Self.resultJSON(["path": relativePath(url), "bytesWritten": content.utf8.count])
        case "file_list":
            let url = try resolved(arguments, key: "path", forWriting: false)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            return try Self.resultJSON(["path": relativePath(url), "entries": Array(names.prefix(2_000)), "truncated": names.count > 2_000])
        case "memory_read":
            let url = try resolvedInternal(arguments, key: "path", root: memoryRoot, forWriting: false)
            return try limitedText(at: url)
        case "memory_write":
            guard let content = arguments.string("content") else { throw RuntimeToolError.invalidArguments("memory_write.content") }
            let url = try resolvedInternal(arguments, key: "path", root: memoryRoot, forWriting: true)
            guard url.pathExtension.lowercased() == "md" else { throw RuntimeToolError.invalidArguments("memory files must use the .md extension") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            return try Self.resultJSON(["path": url.lastPathComponent, "bytesWritten": content.utf8.count])
        case "skill_list":
            return try Self.resultJSON(["skills": DesktopContextAssembler.availableSkills()])
        case "skill_read":
            guard let name = arguments.string("name"), !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent else { throw RuntimeToolError.invalidArguments("skill_read.name") }
            let root = DesktopContextAssembler.globalSkillsDirectory.resolvingSymlinksInPath()
            let url = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("SKILL.md").resolvingSymlinksInPath()
            guard Self.contains(url, root: root) else { throw RuntimeToolError.outsideWorkspace(url.path) }
            return try limitedText(at: url)
        default:
            throw RuntimeToolError.unavailable(call.name)
        }
    }

    private var memoryRoot: URL {
        if let agentID { return AgentProfile.memoryDir(for: agentID) }
        return DesktopContextAssembler.applicationSupportRoot.appendingPathComponent("Memory", isDirectory: true)
    }

    private func limitedText(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if (attributes[.size] as? NSNumber)?.intValue ?? 0 > 1_048_576 { throw RuntimeToolError.oversizedFile }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func resolvedInternal(_ arguments: [String: JSONValue], key: String, root: URL, forWriting: Bool) throws -> URL {
        guard let raw = arguments.string(key), !raw.isEmpty, !raw.hasPrefix("/") else { throw RuntimeToolError.invalidArguments("\(key) must be a relative path") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let requested = root.appendingPathComponent(raw).standardizedFileURL
        let checked = forWriting
            ? requested.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(requested.lastPathComponent).standardizedFileURL
            : requested.resolvingSymlinksInPath()
        guard Self.contains(checked, root: canonicalRoot) else { throw RuntimeToolError.outsideWorkspace(requested.path) }
        return checked
    }

    private func resolved(_ arguments: [String: JSONValue], key: String, forWriting: Bool) throws -> URL {
        guard let raw = arguments.string(key), !raw.isEmpty, !raw.hasPrefix("/") else { throw RuntimeToolError.invalidArguments("\(key) must be a relative path") }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let requested = workspace.appendingPathComponent(raw).standardizedFileURL
        let checked: URL
        if forWriting {
            let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
            checked = parent.appendingPathComponent(requested.lastPathComponent).standardizedFileURL
        } else {
            checked = requested.resolvingSymlinksInPath()
        }
        guard Self.contains(checked, root: root) else { throw RuntimeToolError.outsideWorkspace(requested.path) }
        return checked
    }

    private func relativePath(_ url: URL) -> String {
        let root = workspace.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root { return "." }
        return String(path.dropFirst(min(path.count, root.count + 1)))
    }

    private static func contains(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func arguments(_ raw: String) throws -> [String: JSONValue] {
        guard let data = raw.data(using: .utf8), case .object(let value) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw RuntimeToolError.invalidArguments("expected a JSON object")
        }
        return value
    }

    private static func resultJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func schema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
}
