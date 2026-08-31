//
//  AgentProfile.swift
//  Minis
//
//  A persistent Agent: the identity a conversation belongs to, rather than a
//  property of one throwaway session.
//
//  Before this type existed the app had exactly one agent — a global SOUL.md
//  plus a hardcoded tool array — and "which agent am I talking to" was answered
//  at compile time by the Flavor. An AgentProfile makes that a runtime entity:
//  its persona, memory, model and tool ceiling all key off `id`.
//
//  Storage is split deliberately:
//    - metadata (this struct)  → `agents` table in minis.db, owned by ChatStore
//    - persona body + memory   → /var/minis/agents/<id>/ on disk
//  The body lives on disk so the agent can `file_read` its own SOUL.md and
//  memory the same way it reads everything else, matching how SkillStore and
//  the existing global SoulStore already work.
//

import Foundation

// Shared Apple-domain model. UI-only color rendering lives in AgentAccent.swift.

/// How much of the tool surface an agent is allowed to see.
///
/// This is the mechanism that keeps a long-lived main session clean. An
/// orchestrator physically cannot call `shell_execute`, so its transcript
/// cannot fill up with shell output no matter what the model decides to do —
/// the guarantee is structural, not a line in the system prompt.
public enum AgentToolPolicy: String, Codable, CaseIterable, Sendable {
    /// Dispatch + memory + read-only. No shell, no writes, no browser.
    case orchestrator
    /// The full historical toolset, and no ability to dispatch. This is what
    /// migrated pre-Agent sessions get, so existing behavior is unchanged.
    case standalone

    var displayName: String {
        switch self {
        case .orchestrator: return String(localized: "总管模式")
        case .standalone: return String(localized: "全能模式")
        }
    }

    var explanation: String {
        switch self {
        case .orchestrator:
            return String(localized: "自己不干重活。需要执行的任务派给子 Agent，主会话只保留对话和结论，上下文不会被工具日志淹没。")
        case .standalone:
            return String(localized: "拥有全部工具，自己动手执行。适合工具型 Agent；长期使用会让会话上下文增长很快。")
        }
    }
}

/// The role a running agent loop is playing. Drives both prompt assembly and
/// tool-set construction (see `AIChatViewModel.agentRole`).
public enum AgentRunRole: String, Codable, Sendable {
    /// A persistent agent's own long-lived main session.
    case main
    /// A headless subagent working one dispatched task in a scratch session.
    case executor
}

public struct AgentProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    var name: String
    /// Character avatar. One or two emoji — deliberately not an image, so
    /// creating an agent never needs a picker or a crop step.
    var emoji: String
    /// Short role label shown under the name, e.g. "总管" / "健身教练".
    var title: String
    /// One-line description used as the roster subtitle.
    var summary: String
    /// Hex accent (`#RRGGBB`) used for the avatar chip.
    var accentColor: String
    /// The agent's single long-lived conversation. `nil` until first opened.
    var mainSessionId: String?
    /// Model entry to bind on the main session and on every subagent this
    /// agent dispatches. `nil` falls through to the app-wide default.
    var defaultModelEntryId: String?
    var toolPolicy: AgentToolPolicy
    var memoryEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var sortOrder: Int

    var isArchived: Bool { archivedAt != nil }

    /// Identifier of the agent every pre-existing session is migrated onto.
    /// Kept stable (not a UUID) so migration is idempotent across launches.
    public static let defaultAgentId = "agent-default"

    public init(
        id: String = UUID().uuidString,
        name: String,
        emoji: String = "🤖",
        title: String = "",
        summary: String = "",
        accentColor: String = "#5B8DEF",
        mainSessionId: String? = nil,
        defaultModelEntryId: String? = nil,
        toolPolicy: AgentToolPolicy = .orchestrator,
        memoryEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.title = title
        self.summary = summary
        self.accentColor = accentColor
        self.mainSessionId = mainSessionId
        self.defaultModelEntryId = defaultModelEntryId
        self.toolPolicy = toolPolicy
        self.memoryEnabled = memoryEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.sortOrder = sortOrder
    }

    // MARK: - Equatable / Hashable
    //
    // Mirrors the cheap-comparison contract ChatSession established (see the
    // long note on `ChatSession.==`): the roster is diffed by SwiftUI on every
    // transaction flush, so avoid deep-comparing the long `summary` string.
    // `updatedAt` is its change proxy — every mutation bumps it.
    public static func == (lhs: AgentProfile, rhs: AgentProfile) -> Bool {
        lhs.id == rhs.id
            && lhs.updatedAt == rhs.updatedAt
            && lhs.name == rhs.name
            && lhs.emoji == rhs.emoji
            && lhs.title == rhs.title
            && lhs.mainSessionId == rhs.mainSessionId
            && lhs.toolPolicy == rhs.toolPolicy
            && lhs.archivedAt == rhs.archivedAt
            && lhs.sortOrder == rhs.sortOrder
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(updatedAt)
    }
}

// MARK: - Per-agent filesystem layout

public extension AgentProfile {

    /// Root of every agent's private directory tree, in host terms.
    ///
    /// Lives beside `memory/` and `skills/` inside the App Group container so
    /// the FileProvider extension and the iSH bind mount both pick it up with
    /// the machinery that already exists for those roots.
    nonisolated static var agentsPersistentDir: URL {
        #if os(macOS)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Minis", isDirectory: true)
            .appendingPathComponent("Agents", isDirectory: true)
        #else
        AIChatViewModel.minisAppGroupRoot.appendingPathComponent("agents", isDirectory: true)
        #endif
    }

    /// Linux-side path of the same root, as the agent sees it.
    nonisolated static let agentsLinuxDir = "/var/minis/agents"

    nonisolated static func directory(for agentId: String) -> URL {
        agentsPersistentDir.appendingPathComponent(sanitize(agentId), isDirectory: true)
    }

    nonisolated static func soulURL(for agentId: String) -> URL {
        directory(for: agentId).appendingPathComponent("SOUL.md")
    }

    nonisolated static func memoryDir(for agentId: String) -> URL {
        directory(for: agentId).appendingPathComponent("memory", isDirectory: true)
    }

    nonisolated static func linuxDirectory(for agentId: String) -> String {
        "\(agentsLinuxDir)/\(sanitize(agentId))"
    }

    var directory: URL { Self.directory(for: id) }
    var soulURL: URL { Self.soulURL(for: id) }
    var memoryDir: URL { Self.memoryDir(for: id) }
    var linuxDirectory: String { Self.linuxDirectory(for: id) }

    /// Guard against an id ever escaping its own folder. Ids are generated
    /// internally (UUIDs or the fixed default), so this only ever matters for
    /// rows that arrive from disk or a future sync path.
    nonisolated static func sanitize(_ agentId: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(agentId.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.isEmpty ? defaultAgentId : cleaned
    }

    /// Create the agent's directory tree if missing. Safe on every launch.
    nonisolated static func ensureDirectories(for agentId: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: memoryDir(for: agentId), withIntermediateDirectories: true)
    }
}
