import Foundation

/// Role Pack manifest (JSON). Matches the Flavor/Pack assembly contract.
struct RolePackManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var id: String
    var version: String
    var flavorIds: [String]
    var installerApi: Int
    var soul: SoulSpec?
    var skills: [SkillSpec]
    var quickActionsPath: String?
    var systemBindings: SystemBindings?
    var meta: Meta?

    struct SoulSpec: Codable, Equatable, Sendable {
        var mode: String
        var path: String
        var applyPolicy: String

        enum CodingKeys: String, CodingKey {
            case mode, path
            case applyPolicy = "apply_policy"
        }
    }

    struct SkillSpec: Codable, Equatable, Sendable {
        var id: String
        var path: String
        var enabled: Bool
    }

    /// Declares iOS system sources of truth for the vertical (not App-owned DBs).
    struct SystemBindings: Codable, Equatable, Sendable {
        var tasks: Binding?
        var calendar: Binding?
        var customers: Binding?

        struct Binding: Codable, Equatable, Sendable {
            var source: String
            var writeThrough: Bool?

            enum CodingKeys: String, CodingKey {
                case source
                case writeThrough = "write_through"
            }
        }
    }

    struct Meta: Codable, Equatable, Sendable {
        var title: String?
        var description: String?
        var locale: String?
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, version
        case flavorIds = "flavor_ids"
        case installerApi = "installer_api"
        case soul, skills
        case quickActionsPath = "quick_actions_path"
        case systemBindings = "system_bindings"
        case meta
    }

    static let emptyOpenMinis = RolePackManifest(
        schemaVersion: 1,
        id: "openminis-default",
        version: "0.0.0",
        flavorIds: ["openminis"],
        installerApi: 1,
        soul: nil,
        skills: [],
        quickActionsPath: nil,
        systemBindings: nil,
        meta: Meta(title: "OpenMinis", description: "Default empty pack", locale: "en")
    )
}

struct RolePackQuickAction: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var icon: String?
    var kind: String
    var prompt: String?
    var skillHint: String?

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, icon, kind, prompt
        case skillHint = "skill_hint"
    }
}

struct RolePackQuickActionsFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var actions: [RolePackQuickAction]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case actions
    }
}
