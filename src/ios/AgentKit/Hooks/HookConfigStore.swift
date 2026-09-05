//
//  HookConfigStore.swift
//  Minis
//
//  Where hook bindings live on disk, and how the three layers combine.
//
//  Lives under AgentKit rather than Agent/ on purpose: AgentKit is one of the
//  project's synchronized folder groups, so a new file here is picked up by the
//  build without a project.pbxproj edit.
//
//  Authoritative copy sits in MinisConfig (NOT the FileProvider root) — hook
//  bindings are machinery, not a user document, and putting them in "On My
//  iPhone → Minis" invites edits that silently change how every turn behaves.
//  A read-only mirror is written into the sandbox so an agent can `file_read`
//  the rules it is running under; writes always go through this store.
//

import Foundation

private let logger = AppLogger(category: "Hooks")

@MainActor
final class HookConfigStore: ObservableObject {
    static let shared = HookConfigStore()

    /// Master switch. When off, `HookRunner` short-circuits every event and the
    /// app behaves exactly as it did before hooks existed.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    static let enabledKey = "hooks.enabled"

    private let fm = FileManager.default
    private var cache: [String: HookConfig] = [:]

    private init() {
        // Default ON: with no bindings declared the engine is a no-op, so the
        // switch defaults to "the framework is wired" rather than "dormant".
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    // MARK: - Paths

    private var rootDir: URL {
        AIChatViewModel.minisConfigRoot.appendingPathComponent("hooks", isDirectory: true)
    }

    private var rootfsMirrorDir: URL {
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("alpine-rootfs/data/var/minis/config/hooks")
    }

    /// `global.json`, `agents/<id>.json`, `sessions/<id>.json`.
    private func relativePath(scope: HookScope, id: String?) -> String {
        switch scope {
        case .global: return "global.json"
        case .agent: return "agents/\(sanitize(id ?? "unknown")).json"
        case .session: return "sessions/\(sanitize(id ?? "unknown")).json"
        }
    }

    /// Ids come from UUIDs and agent ids, but a hand-edited or synced id could
    /// carry a slash and escape the hooks directory. Reduce to a flat name.
    private func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return cleaned.isEmpty ? "unknown" : String(cleaned)
    }

    // MARK: - Read

    func config(scope: HookScope, id: String? = nil) -> HookConfig {
        let key = relativePath(scope: scope, id: id)
        if let cached = cache[key] { return cached }
        let url = rootDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url) else {
            cache[key] = .empty
            return .empty
        }
        do {
            let config = try JSONDecoder().decode(HookConfig.self, from: data)
            cache[key] = config
            return config
        } catch {
            // A malformed layer must not take the other layers down with it —
            // and must not silently look like "no rules configured" either.
            logger.error("[Hooks] \(key) is not valid hook config: \(String(describing: error)) — treating as empty")
            cache[key] = .empty
            return .empty
        }
    }

    /// The bindings in effect for one session, narrowest layer last.
    func resolvedBindings(sessionId: String?, agentId: String?) -> [ResolvedHookBinding] {
        guard isEnabled else { return [] }
        return HookEngine.merge(
            global: config(scope: .global),
            agent: agentId.map { config(scope: .agent, id: $0) } ?? .empty,
            session: sessionId.map { config(scope: .session, id: $0) } ?? .empty
        )
    }

    // MARK: - Write

    func save(_ config: HookConfig, scope: HookScope, id: String? = nil) {
        let key = relativePath(scope: scope, id: id)
        let url = rootDir.appendingPathComponent(key)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            cache[key] = config
            mirrorToRootfs(data: data, relativePath: key)
            objectWillChange.send()
        } catch {
            logger.error("[Hooks] failed to save \(key): \(String(describing: error))")
        }
    }

    /// Flip one binding's `enabled` at the layer it was declared in.
    func setEnabled(_ enabled: Bool, bindingID: String, scope: HookScope, id: String?) {
        var config = config(scope: scope, id: id)
        guard let index = config.bindings.firstIndex(where: { $0.id == bindingID }) else { return }
        config.bindings[index].enabled = enabled
        save(config, scope: scope, id: id)
    }

    /// Switch off a broader layer's binding from a narrower one, by
    /// redeclaring the same id with `enabled: false`. This is how a session
    /// opts out of a global rule without editing the global file.
    func overrideDisabled(_ binding: HookBinding, at scope: HookScope, id: String?) {
        var config = config(scope: scope, id: id)
        var copy = binding
        copy.enabled = false
        if let index = config.bindings.firstIndex(where: { $0.id == binding.id }) {
            config.bindings[index] = copy
        } else {
            config.bindings.append(copy)
        }
        save(config, scope: scope, id: id)
    }

    func reload() {
        cache.removeAll()
        objectWillChange.send()
    }

    // MARK: - Mirror

    /// Best-effort: the sandbox copy is a convenience for the agent, never the
    /// source of truth, so a failure here must not fail the save.
    private func mirrorToRootfs(data: Data, relativePath: String) {
        let url = rootfsMirrorDir.appendingPathComponent(relativePath)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
