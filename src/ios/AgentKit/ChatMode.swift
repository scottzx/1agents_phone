import Foundation

/// How much agent scaffolding a chat session hands to the model.
///
/// [T-lite-mode-small-local-models] A 2B on-device reasoning model never
/// emitted a single structured tool call against the standard setup. Two
/// causes, both structural rather than promptable: it is fine-tuned to think
/// and then PRINT the answer (a ```bash block instead of a `tool_calls`
/// entry), and the standard turn hands it ~15 tool schemas behind a
/// multi-thousand-token operator prompt — far past the point where a model
/// that size can still attend to which tool matches the request.
///
/// Lite mode is the counterpart: one tool (`shell_execute`), a prompt short
/// enough to stay in view, and skills still reachable because loading one is
/// just `cat`-ing its SKILL.md. It changes nothing for the cloud models the
/// full mode was written for — it is a per-session choice, and `.normal`
/// remains the default.
enum ChatMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The historical full toolset and operator prompt.
    case normal
    /// `shell_execute` only, plus a minimal prompt. For small local models.
    case lite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return String(localized: "Standard Mode", comment: "Chat mode: full tools and prompt")
        case .lite: return String(localized: "Lite Mode", comment: "Chat mode: shell-only, minimal prompt")
        }
    }

    var explanation: String {
        switch self {
        case .normal:
            return String(localized: "Full toolset and instructions. Best for cloud models.",
                          comment: "Chat mode explanation: standard")
        case .lite:
            return String(localized: "Shell tool only, short prompt, skills still load. For small on-device models that ignore tool calls.",
                          comment: "Chat mode explanation: lite")
        }
    }

    /// SF Symbol shown on the composer's mode button.
    var iconName: String {
        switch self {
        case .normal: return "slider.horizontal.3"
        case .lite: return "leaf"
        }
    }
}

/// App-wide default seeded into every new session (see
/// `ChatStore.createSession`). Updated whenever the user picks a mode in the
/// composer, so "I am working with the local model today" survives starting a
/// new chat. Existing sessions keep their stored value.
enum ChatModePreferences {
    static let defaultsKey = "chat.mode.default"

    static var globalDefault: ChatMode {
        get {
            (UserDefaults.standard.string(forKey: defaultsKey))
                .flatMap(ChatMode.init(rawValue:)) ?? .normal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

/// The whole system prompt for a `.lite` turn.
///
/// Deliberately flat and short. Every line either tells the model how to emit
/// a tool call, or names a path it cannot guess. Anything a small model would
/// skim past (the minis:// scheme, the apple-* CLI catalog, memory policy,
/// scheduling caveats) is left out — in lite mode those tools aren't
/// registered anyway.
enum LiteModePrompt {

    static func render(agentId: String?, timeString: String) -> String {
        let name = SystemPromptBuilder.agentDisplayName(for: agentId)
        return """
        You are \(name), an AI assistant running on the user's iPhone. You have a real Linux sandbox (Alpine Linux, BusyBox ash) on the device and one tool to drive it.

        Tool: shell_execute — runs a command via /bin/sh -c and returns its stdout and stderr.

        How to use it (important):
        - To run a command you MUST emit a real shell_execute tool call. Writing the command in a ```bash code block does NOT run it, and the user sees nothing happen.
        - Never say you ran, checked, installed or created something unless a tool call actually returned that result.
        - One command per call. Read the result, then decide the next call.
        - When the question needs no command — chat, explanation, translation, something you already know — just answer. Do not call the tool to look busy.
        - After a command returns, answer the user in their own language. Quote output only when it is short and relevant.

        The sandbox:
        - Install packages with `apk add <pkg>`; run `which <cmd>` first, many are already there.
        - Read with `cat`, write with `cat > file << 'EOF' … EOF`, search with `find` / `grep`.
        - /var/minis/workspace — scratch space for THIS chat only.
        - /var/minis/shared — the only storage that outlives this chat.
        - /var/minis/attachments — media you want to show; embed it as ![desc](minis://attachments/<file>).
        - Skills are reusable instructions. A list of them may appear later in this prompt; when one fits the task, load it by running the command `cat /var/minis/skills/<name>/SKILL.md` through shell_execute, then follow what it says. The path is a file to read, never a command to run.

        Current time (approximate): \(timeString) (\(TimeZone.current.identifier)).
        """
    }

    /// The single tool a `.lite` turn registers.
    ///
    /// `tool_title` — required on every tool in the standard set so the UI can
    /// label the card — is dropped here: it is a non-blocking field (see
    /// `preflightNonBlockingFields`), the card falls back to the command
    /// itself, and every extra required property is one more thing a 2B model
    /// can get wrong before it ever reaches `command`.
    static var toolDefinitions: [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "shell_execute",
                description: "Run a shell command on the device's Linux sandbox and return its output. Use it for files, scripts, package installs, network requests — anything a terminal can do.",
                parameters: [
                    "command": AgentToolParam(type: .string, description: "The shell command to run, e.g. `ls -la /var/minis/workspace`."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default: 900)."),
                ],
                required: ["command"],
                propertyOrdering: ["command", "timeout"]
            )
        ]
    }
}
