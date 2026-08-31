import Foundation

enum FileContextFormatter {
    static let safetyNotice = "Attached file context (paths only; no file contents were read and no command was run):"

    static func message(for urls: [URL]) -> String {
        guard !urls.isEmpty else { return "" }
        return safetyNotice + "\n" + urls.map { "- \($0.path)" }.joined(separator: "\n")
    }
}
