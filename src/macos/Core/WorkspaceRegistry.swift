import Foundation

public enum WorkspaceError: LocalizedError, Sendable, Equatable {
    case missingDirectory
    case notGranted(URL)

    public var errorDescription: String? {
        switch self {
        case .missingDirectory: "The selected workspace is not a readable directory."
        case .notGranted(let url): "Access outside the granted workspace requires approval: \(url.path)"
        }
    }
}

/// Runtime-owned workspace grants. The V1 policy permits session commands to
/// operate only in the explicitly selected project directory.
public actor WorkspaceRegistry {
    private var workspaces: [String: URL] = [:]

    public init() {}

    @discardableResult
    public func grant(_ url: URL, id: String = UUID().uuidString) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.missingDirectory
        }
        workspaces[id] = url.standardizedFileURL
        return id
    }

    public func url(for id: String) -> URL? { workspaces[id] }

    public func revoke(_ id: String) { workspaces.removeValue(forKey: id) }

    public func all() -> [String: URL] { workspaces }
}
