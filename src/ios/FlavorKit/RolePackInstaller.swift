import Foundation

/// Installs the bundled Role Pack into existing Soul/Skill stores (idempotent).
/// Empty-shell phase: load + log + seed SOUL on first launch; skills/schema later.
@MainActor
enum RolePackInstaller {
    static let installerApiVersion = 1

    private static let logger = AppLogger(category: "RolePack")
    private static let stateKeyPrefix = "rolePack.installState."

    struct InstallState: Codable, Equatable {
        var flavorId: String
        var packId: String
        var installedVersion: String
        var installerApiUsed: Int
        var lastResult: String
        var lastError: String?
    }

    private static var stateKey: String {
        stateKeyPrefix + FlavorRegistry.current.flavorId
    }

    /// Call once at launch after memory dirs are ready (or safely before — SOUL ensure is defensive).
    static func installIfNeeded() {
        let flavor = FlavorRegistry.current
        guard let packRoot = packRootURL(for: flavor) else {
            logger.info("[RolePack] no RolePack in bundle for flavor=\(flavor.flavorId) — skip")
            return
        }

        let manifest = loadManifest(from: packRoot) ?? .emptyOpenMinis
        if manifest.installerApi > installerApiVersion {
            logger.error("[RolePack] pack installer_api=\(manifest.installerApi) > host \(installerApiVersion) — skip")
            persist(InstallState(
                flavorId: flavor.flavorId,
                packId: manifest.id,
                installedVersion: manifest.version,
                installerApiUsed: installerApiVersion,
                lastResult: "skipped_api",
                lastError: "pack requires installer_api \(manifest.installerApi)"
            ))
            return
        }

        var soulResult = "absent"
        if flavor.defaults.preferBundledSoulOnFirstLaunch,
           let soul = manifest.soul,
           soul.mode != "none" {
            soulResult = applySoulIfNeeded(packRoot: packRoot, soul: soul)
        }

        // Skills: empty-shell packs ship zero skills. Full import lands with skill-creator coexistence later.
        let skillCount = manifest.skills.count
        if skillCount > 0, flavor.defaults.installSkillsEnabled {
            logger.info("[RolePack] \(skillCount) skills declared — deferred import (empty-shell phase)")
        }

        var actionsCount = 0
        if let rel = manifest.quickActionsPath {
            let url = packRoot.appendingPathComponent(rel)
            if let data = try? Data(contentsOf: url),
               let file = try? JSONDecoder().decode(RolePackQuickActionsFile.self, from: data) {
                actionsCount = file.actions.count
                RolePackRuntime.shared.quickActions = file.actions
            }
        }

        RolePackRuntime.shared.manifest = manifest
        RolePackRuntime.shared.packRootURL = packRoot

        logger.info(
            "[RolePack] flavor=\(flavor.flavorId) pack=\(manifest.id) version=\(manifest.version) " +
            "soul=\(soulResult) skills=\(skillCount) quick_actions=\(actionsCount) result=ok"
        )

        persist(InstallState(
            flavorId: flavor.flavorId,
            packId: manifest.id,
            installedVersion: manifest.version,
            installerApiUsed: installerApiVersion,
            lastResult: "ok",
            lastError: nil
        ))
    }

    // MARK: - Paths

    private static func packRootURL(for flavor: FlavorConfig) -> URL? {
        let name = flavor.pack.resourceDir
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        // Folder reference sometimes resolves as a directory next to the json
        if let base = Bundle.main.resourceURL {
            let candidate = base.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func loadManifest(from packRoot: URL) -> RolePackManifest? {
        let url = packRoot.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            logger.info("[RolePack] manifest.json missing at \(url.path)")
            return nil
        }
        do {
            return try JSONDecoder().decode(RolePackManifest.self, from: data)
        } catch {
            logger.error("[RolePack] manifest decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - SOUL

    /// first_launch_only: write pack SOUL only when SOUL.md does not exist yet.
    private static func applySoulIfNeeded(packRoot: URL, soul: RolePackManifest.SoulSpec) -> String {
        let policy = soul.applyPolicy
        let dest = SoulStore.fileURL
        let fm = FileManager.default

        if fm.fileExists(atPath: dest.path) {
            return "skipped_exists"
        }

        guard policy == "first_launch_only" || policy == "upgrade_if_untouched" else {
            return "skipped_policy"
        }

        let src = packRoot.appendingPathComponent(soul.path)
        guard let data = try? Data(contentsOf: src),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "absent"
        }

        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.data(using: .utf8)?.write(to: dest, options: .atomic)
            SoulStore.refreshCache()
            return "applied"
        } catch {
            logger.error("[RolePack] SOUL write failed: \(error.localizedDescription)")
            return "failed"
        }
    }

    // MARK: - State

    private static func persist(_ state: InstallState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    static func lastState() -> InstallState? {
        guard let data = UserDefaults.standard.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(InstallState.self, from: data)
    }
}

/// In-memory pack surface for UI (quick actions, etc.).
@MainActor
final class RolePackRuntime: ObservableObject {
    static let shared = RolePackRuntime()

    @Published var manifest: RolePackManifest?
    @Published var quickActions: [RolePackQuickAction] = []
    var packRootURL: URL?

    private init() {}
}
