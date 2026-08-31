import Foundation
import MinisAppleDomain

enum DesktopContextAssembler {
    static func prompt(for agent: RuntimeAgentRecord) -> String {
        AgentProfile.ensureDirectories(for: agent.id)
        var sections = [
            "You are \(agent.name)\(agent.title.isEmpty ? "" : ", \(agent.title)"). \(agent.summary)",
            "Runtime capabilities: os=macos-host; shell=the user's login shell; package manager may be Homebrew; paths are native macOS paths, never /var/minis."
        ]
        if let soul = read(AgentProfile.soulURL(for: agent.id), limit: 64_000), !soul.isEmpty {
            sections.append("Agent persona (SOUL.md):\n\(soul)")
        }
        let memoryFiles = recentMarkdown(in: AgentProfile.memoryDir(for: agent.id), maximum: 6)
        let memories = memoryFiles.compactMap { url -> String? in
            guard let body = read(url, limit: 24_000), !body.isEmpty else { return nil }
            return "### \(url.lastPathComponent)\n\(body)"
        }
        if !memories.isEmpty { sections.append("Long-term memory:\n" + memories.joined(separator: "\n\n")) }
        let skills = availableSkills()
        if !skills.isEmpty {
            sections.append("Available desktop Skills (use skill_read before following one):\n" + skills.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    static var globalSkillsDirectory: URL {
        applicationSupportRoot.appendingPathComponent("Skills", isDirectory: true)
    }

    static func availableSkills() -> [String] {
        let values = (try? FileManager.default.contentsOfDirectory(at: globalSkillsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return values.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }.map(\.lastPathComponent).sorted()
    }

    static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Minis", isDirectory: true)
    }

    private static func recentMarkdown(in directory: URL, maximum: Int) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "md" }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }.prefix(maximum).map { $0 }
    }

    private static func read(_ url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
