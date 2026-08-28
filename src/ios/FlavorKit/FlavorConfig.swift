import Foundation

/// Build-time / bundle identity for a vertical App Target.
/// See `docs/specs/flavor-pack-contract.md`.
struct FlavorConfig: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var flavorId: String
    var displayName: String
    var pack: PackRef
    var rootExperience: RootExperience
    var sceneModuleId: String?
    var branding: Branding
    var defaults: Defaults

    struct PackRef: Codable, Equatable, Sendable {
        var resourceDir: String
        var id: String
        var minInstallerApi: Int

        enum CodingKeys: String, CodingKey {
            case resourceDir = "resource_dir"
            case id
            case minInstallerApi = "min_installer_api"
        }
    }

    enum RootExperience: String, Codable, Equatable, Sendable {
        case standardChat = "standard_chat"
        case sceneHome = "scene_home"
        case chatWithRail = "chat_with_rail"
        /// Home is the agent roster; a conversation is reached through an
        /// agent rather than created fresh. See AgentListView.
        case agentRoster = "agent_roster"
    }

    struct Branding: Codable, Equatable, Sendable {
        var chatPlaceholder: String?
        var onboardingTitle: String?
        var onboardingBody: String?

        enum CodingKeys: String, CodingKey {
            case chatPlaceholder = "chat_placeholder"
            case onboardingTitle = "onboarding_title"
            case onboardingBody = "onboarding_body"
        }
    }

    struct Defaults: Codable, Equatable, Sendable {
        var preferBundledSoulOnFirstLaunch: Bool
        var installSkillsEnabled: Bool
        var showAdvancedSettings: Bool

        enum CodingKeys: String, CodingKey {
            case preferBundledSoulOnFirstLaunch = "prefer_bundled_soul_on_first_launch"
            case installSkillsEnabled = "install_skills_enabled"
            case showAdvancedSettings = "show_advanced_settings"
        }

        static let `default` = Defaults(
            preferBundledSoulOnFirstLaunch: true,
            installSkillsEnabled: true,
            showAdvancedSettings: true
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case flavorId = "flavor_id"
        case displayName = "display_name"
        case pack
        case rootExperience = "root_experience"
        case sceneModuleId = "scene_module_id"
        case branding
        case defaults
    }

    /// Builtin fallback when the bundle has no FlavorConfig.json (legacy / misconfigured).
    static let openMinisFallback = FlavorConfig(
        schemaVersion: 1,
        flavorId: "openminis",
        displayName: "Minis",
        pack: PackRef(resourceDir: "RolePack", id: "openminis-default", minInstallerApi: 1),
        rootExperience: .agentRoster,
        sceneModuleId: nil,
        branding: Branding(
            chatPlaceholder: nil,
            onboardingTitle: nil,
            onboardingBody: nil
        ),
        defaults: .default
    )
}

/// Loads `FlavorConfig.json` from the main bundle. Never fails hard — falls back to openminis.
enum FlavorRegistry {
    private static let logger = AppLogger(category: "Flavor")

    /// Cached after first successful (or fallback) load.
    private static var cached: FlavorConfig?

    static var current: FlavorConfig {
        if let cached { return cached }
        let loaded = loadFromBundle() ?? .openMinisFallback
        cached = loaded
        return loaded
    }

    /// Force re-read (tests / rare hot-reload).
    static func reload() {
        cached = nil
        _ = current
    }

    private static func loadFromBundle() -> FlavorConfig? {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "FlavorConfig", withExtension: "json") else {
            logger.info("[Flavor] FlavorConfig.json missing — using openminis fallback")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let config = try decoder.decode(FlavorConfig.self, from: data)
            logger.info("[Flavor] loaded flavor_id=\(config.flavorId) pack=\(config.pack.id) root=\(config.rootExperience.rawValue)")
            return config
        } catch {
            logger.error("[Flavor] FlavorConfig.json decode failed: \(error.localizedDescription)")
            return nil
        }
    }
}
