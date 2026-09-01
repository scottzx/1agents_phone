import Foundation

/// A group member gets the same public `send_agent_message` verb as a normal
/// chat, but with a narrower schema. Conditional private/group fields were
/// easy for smaller OpenAI-compatible models to ignore, producing a visible
/// `@名字` sentence instead of a tool call. Requiring `group_id` and removing
/// private-only knobs makes the group contract unambiguous without changing
/// the unified tool semantics.
enum GroupA2AToolDefinitions {
    static func make(from directoryTools: [AgentToolDefinition]) -> [AgentToolDefinition] {
        guard let list = directoryTools.first(where: { $0.name == "list_agents" }),
              let send = directoryTools.first(where: { $0.name == "send_agent_message" }) else {
            return []
        }

        let groupParameters = send.parameters.filter { key, _ in
            key != "wait_seconds" && key != "interrupt"
        }
        let groupSend = AgentToolDefinition(
            name: send.name,
            description: "Send the current public group utterance to one or more group members. In this group session is_group MUST be true, group_id MUST be copied from the group context, agent_id MUST be a JSON list, and message MUST contain plain prose without @ mentions. Use [\"at_all\"] only when the current assistant is the group owner. This tool call, not visible @name text, is what wakes the recipients.",
            parameters: groupParameters,
            required: ["tool_title", "is_group", "group_id", "agent_id", "message"],
            propertyOrdering: ["tool_title", "is_group", "group_id", "agent_id", "message"]
        )
        return [list, groupSend]
    }
}

// MARK: - Tool Definitions (Canonical)

extension AIChatViewModel {

    /// [T-ios-vision-branch-mismatch #182] THE single source of truth for
    /// "can the model that will actually receive this turn see images itself".
    ///
    /// Both the `read_image` registration (which picks the tool DESCRIPTION) and
    /// its handler (which picks pixels-vs-Vision-Group) must agree, or the model
    /// is told one thing and handed another. They previously each wrote
    /// `selectedModel.capabilities.supportedModalities.contains(.imageInput)` —
    /// textually identical, yet wrong: `selectedModel` is the @Published UI
    /// property, while the REQUEST is built from `resolveCurrentEntry()` (see
    /// `activeModel` in runAgentLoop). With group routing or a session binding
    /// those are different models, so a text-only model could be registered with
    /// the Vision Group tool description and then served by the native pixel
    /// branch — returning metadata and no description at all.
    ///
    /// Resolve from the same entry the request uses, and fall back to
    /// `selectedModel` only when that resolution fails.
    var activeModelHasNativeVision: Bool {
        let model = resolveCurrentEntry()?.model ?? selectedModel
        return model.capabilities.supportedModalities.contains(.imageInput)
    }

    // MARK: - Tool Definitions (Canonical)

    /// The tool set for this turn, gated by the owning agent's policy.
    ///
    /// [T-agent-orchestrator-toolcut] An orchestrator's session is the agent's
    /// ONE long-lived conversation — it is never replaced, only compacted. If
    /// that transcript accumulates shell output, page text and file contents,
    /// the agent's usable memory is spent on task exhaust within a day. The
    /// fix is structural rather than prompt-level: an orchestrator is simply
    /// not handed `shell_execute` / `file_write` / `file_edit` / `browser_use`,
    /// so no amount of model misbehavior can put that output in its history.
    /// The heavy tools live on the executor subagents it dispatches, whose
    /// scratch sessions absorb the noise and hand back only a conclusion.
    ///
    /// `.standalone` is the historical full toolset and stays the default for
    /// any session that predates the Agent migration.
    func makeAgentTools() -> [AgentToolDefinition] {
        let policy = effectiveToolPolicy

        // [T-memory-toggle-gates-injection-and-tools-ios] memory_get and
        // memory_write are conditionally registered. When the per-session
        // toggle is off, drop both tool definitions so the LLM never sees
        // them. The system prompt also switches to a "memory disabled"
        // wording (see baseSystemPrompt below) so the model can correctly
        // tell the user to re-enable memory via /memory or Settings.
        let includeMemoryTools = memoryEnabled

        // [T-agent-subagent-memory-readonly] Memory WRITING belongs to the
        // persistent agent alone. A subagent runs in a throwaway session but
        // its `agentId` is the parent's, so `memory_write` would append to the
        // agent's real daily log — a temporary task editing a permanent
        // asset, with the orchestrator never seeing what was written. Reading
        // stays on (a task benefits from knowing the user's preferences); the
        // write is routed back through the orchestrator, which is the one
        // holding the conversation and can judge what is worth keeping.
        let includeMemoryWrite = includeMemoryTools && agentRole != .executor

        var tools: [AgentToolDefinition] = []

        // Dispatch tools — orchestrators only. An executor that could spawn
        // further executors would make task trees unbounded and untraceable.
        if policy == .orchestrator {
            tools.append(contentsOf: SubagentTools.definitions)
        }

        // Roster tools — every agent's OWN conversation, both policies, and
        // never a subagent's. Creating colleagues and talking to them is part
        // of being the thing the user talks to; an executor handed these could
        // mint agents and start conversations between them off the back of one
        // dispatched task, which is the same unbounded-graph problem that
        // keeps `spawn_subagent` off executors.
        //
        // A group member keeps list + send. send_agent_message switches to its
        // explicit `is_group + group_id + agent_id[]` shape there and publishes through the
        // shared transcript; create_agent stays out because changing the roster
        // is unrelated to taking a group turn.
        if agentRole == .main {
            if groupId == nil {
                tools.append(contentsOf: AgentDirectoryTools.definitions)
            } else {
                tools.append(contentsOf: GroupA2AToolDefinitions.make(from: AgentDirectoryTools.definitions))
            }
        }

        // History search — everyone except orchestrators, which is to say every
        // subagent (an executor's effectiveToolPolicy is always .standalone).
        // A 总管 is deliberately left out for the same reason it has no shell:
        // twenty snippets of old conversation is exactly the bulk its
        // transcript exists to stay clear of. It dispatches the lookup instead.
        if policy == .standalone {
            tools.append(ChatHistorySearchTool.definition)
        }

        // Heavy, transcript-polluting tools — everyone except orchestrators.
        if policy == .standalone {
            tools.append(
                AgentToolDefinition(
                    name: "shell_execute",
                    description: "Execute a command in an isolated Linux process (iSH/Alpine Linux). The command runs via /bin/sh -c with stdout and stderr captured separately via pipes. Each invocation spawns a fresh process — there is no shared terminal session. Default timeout is 15 minutes.",
                    parameters: [
                        "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Install Python data analysis packages', 'List files in home directory'). Use the same language as the user."),
                        "command": AgentToolParam(type: .string, description: "The shell command to execute. Supports multi-line commands directly — no special escaping needed. Keep under 1000 chars; for longer scripts, write to a file with file_write first, then run it."),
                        "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default: 900). Use a larger value for long-running commands like package installs."),
                        "delay": AgentToolParam(type: .integer, description: "Delay in seconds before execution begins. The tool blocks the agent flow during this wait WITHOUT occupying the iSH shell, so other concurrent tasks can use it. Use this instead of sleep commands to avoid resource contention."),
                    ],
                    required: ["tool_title", "command"],
                    propertyOrdering: ["tool_title", "command", "timeout", "delay"]
                )
            )
        }

        // Reading is safe for both roles: an orchestrator needs to be able to
        // look at a file the user points it at, or re-read a result an
        // executor left in the shared workspace, without dispatching for it.
        tools.append(
            AgentToolDefinition(
                name: "file_read",
                description: "Read a file from the Linux filesystem. Faster than shell_execute for reading files — no shell overhead. Returns file content with metadata. Rejects binary files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Read Python script contents', 'Check system configuration file'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to read (e.g. /var/minis/workspace/data.csv)"),
                    "offset": AgentToolParam(type: .integer, description: "1-based line number to start reading from (default: 1). Ignored when direction is 'tail'."),
                    "lines": AgentToolParam(type: .integer, description: "Maximum number of lines to return (default: all lines up to max_length)"),
                    "max_length": AgentToolParam(type: .integer, description: "Maximum character length of returned content (default: 15000)"),
                    "direction": AgentToolParam(type: .string, description: "Read direction: 'head' (from start, default) or 'tail' (from end of file)"),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "offset", "lines", "direction", "max_length"]
            )
        )

        if policy == .standalone {
            tools.append(
                AgentToolDefinition(
                    name: "file_write",
                    description: "Write content to a file on the Linux filesystem. Faster than shell_execute for writing files. Creates the file if it doesn't exist. Use append mode to add to existing files.",
                    parameters: [
                        "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Create Python statistics script', 'Write configuration file'). Use the same language as the user."),
                        "path": AgentToolParam(type: .string, description: "Absolute Linux path to write (e.g. /root/test.txt)"),
                        "content": AgentToolParam(type: .string, description: "The text content to write to the file"),
                        "append": AgentToolParam(type: .boolean, description: "If true, append to existing file instead of overwriting (default: false)"),
                        "create_dirs": AgentToolParam(type: .boolean, description: "If true, create parent directories if they don't exist (default: false)"),
                    ],
                    required: ["tool_title", "path", "content"],
                    propertyOrdering: ["tool_title", "path", "content", "append", "create_dirs"]
                )
            )
            tools.append(
                AgentToolDefinition(
                    name: "file_edit",
                    description: "Make targeted edits to an existing file using exact string replacement. ALWAYS use file_read first to see the current file contents before editing. Prefer file_edit over file_write when modifying existing files — only the changed part needs to be specified. The old_string must match exactly one location in the file (including whitespace/indentation), unless replace_all is true.",
                    parameters: [
                        "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Fix typo in Python script', 'Update config value'). Use the same language as the user."),
                        "path": AgentToolParam(type: .string, description: "Absolute Linux path to the file to edit (e.g. /root/script.py)"),
                        "old_string": AgentToolParam(type: .string, description: "The exact text to find in the file. Must match precisely including whitespace and indentation. Must be unique in the file unless replace_all is true."),
                        "new_string": AgentToolParam(type: .string, description: "The replacement text. Use empty string to delete old_string."),
                        "replace_all": AgentToolParam(type: .boolean, description: "If true, replace ALL occurrences of old_string (default: false)"),
                    ],
                    required: ["tool_title", "path", "old_string", "new_string"],
                    propertyOrdering: ["tool_title", "path", "old_string", "new_string", "replace_all"]
                )
            )
            tools.append(
                AgentToolDefinition(
                    name: "browser_use",
                    description: "Control a web browser with up to 3 tabs. Do NOT use this tool for minis:// action URLs (open_terminal, views, settings) — those are app deep links, use Markdown links in chat instead. The browser supports both web URLs and minis:// resource URLs. Use minis:// URLs to preview session files (e.g. navigate to minis://workspace/index.html). Sub-resources (JS, CSS, images, fonts) referenced via minis:// absolute paths or relative paths within HTML pages resolve correctly. Use navigate to open URLs, screenshot to see the page (returns an image), click/type to interact with elements, get_text/get_readable to extract content, scroll to navigate long pages, scroll_and_collect to scroll through infinite-scroll/virtual-rendered pages (like Twitter/X timelines) and accumulate unique content items across scroll positions in a single call, find_elements to discover interactive elements, get_page_info for page metadata, get_backbone to get a structural overview of the page DOM as a simplified tree, fetch to download files/resources using the page's session (returns metadata and a minis:// URL), new_tab to open an additional tab, close_tab to close a tab, and list_tabs to see all open tabs. Use set_viewport with viewport_width + viewport_height to override the viewport for the current session (e.g. before screenshotting a 1920×1080 HTML composition that would otherwise be cropped to the phone viewport); pass reset=true to drop the session override and fall back to the global browser setting. Use get_cookies to retrieve cookies for the current page URL / current site root domain only (including HttpOnly cookies). get_cookies supports optional 'keyword' (filter by cookie name) and 'fuzzy' (true=contains match, false=exact match, default true). It returns only a summary and an offload env file path — raw cookie values are NOT included in the tool response. To reuse cookies in shell commands: `. /var/minis/offloads/env_cookies_xxx.sh && command`. You may define alias variables when needed. Use set_cookies to write cookies into the current page's cookie store via the native cookie store (so even HttpOnly cookies, which JS cannot set, land). Pass a 'cookies' array of objects, each with name + value (required) and optional domain (defaults to the current page host), path (defaults to '/'), secure, http_only, and expires (Unix timestamp in seconds; omit for a session cookie). Use wait_for_dom_stable to wait until the page DOM stops changing (useful after navigation or interactions that trigger async data loading — polls every 0.5s, resolves when mutation rate gradient is stable for 3+ intervals, default timeout 10s). Use tab_id to target a specific tab (defaults to the most recently used tab).",
                    parameters: [
                        "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Open Wikipedia homepage', 'Take screenshot of current page'). Use the same language as the user."),
                        "action": AgentToolParam(type: .string, description: "The browser action to perform", enumValues: BrowserAction.allCases.map(\.rawValue)),
                        "url": AgentToolParam(type: .string, description: "URL to navigate to (for navigate action) or resource to download (for fetch action)"),
                        "selector": AgentToolParam(type: .string, description: "CSS selector for targeting elements (click, type, get_text, scroll, hover, find_elements). For scroll: specify a scrollable container to scroll (e.g. 'div.timeline'); if omitted, auto-detects the best scrollable element."),
                        "text": AgentToolParam(type: .string, description: "Text to type (for type action)"),
                        "coordinate_x": AgentToolParam(type: .integer, description: "X coordinate for click (alternative to selector)"),
                        "coordinate_y": AgentToolParam(type: .integer, description: "Y coordinate for click (alternative to selector)"),
                        "direction": AgentToolParam(type: .string, description: "Scroll direction", enumValues: ["up", "down"]),
                        "amount": AgentToolParam(type: .integer, description: "Scroll amount in pixels (default: 500)"),
                        "script": AgentToolParam(type: .string, description: "JavaScript code to execute (for execute_js action). The script runs inside an async function wrapper — `await` and top-level `return` are both supported (e.g. `var r = await fetch(url); return await r.json()`)."),
                        "user_agent": AgentToolParam(type: .string, description: "User agent profile to switch to", enumValues: ["desktop_safari", "mobile_safari"]),
                        "max_depth": AgentToolParam(type: .integer, description: "Maximum tree depth for get_backbone (default: 5)"),
                        "scroll_count": AgentToolParam(type: .integer, description: "Number of scroll steps for scroll_and_collect (default: 10, max: 20). Each step scrolls by 'amount' pixels and waits for new content."),
                        "item_selector": AgentToolParam(type: .string, description: "CSS selector for individual content items in scroll_and_collect (e.g. 'article', '[data-testid=\"tweet\"]'). If omitted, auto-detects repeated elements."),
                        "tab_id": AgentToolParam(type: .integer, description: "Target tab ID (optional, defaults to most recently used tab). Use list_tabs to see available tabs."),
                        "keywords": AgentToolParam(type: .string, description: "Filter cookies by name (for get_cookies). A space-separated string or array of strings. With fuzzy=true (default), ALL keywords must appear in the cookie name (case-insensitive). With fuzzy=false, cookie name must exactly equal any one of the provided keywords (case-insensitive). Omit to return all cookies for the current site."),
                        "fuzzy": AgentToolParam(type: .boolean, description: "Whether keyword matching is fuzzy (contains-all) or exact-any (for get_cookies, default: true)."),
                        "cookies": AgentToolParam(type: .string, description: "For set_cookies: a JSON array of cookie objects to write. Pass it as a JSON array (a JSON-encoded string of the array is also accepted). Each object: {\"name\": str (required), \"value\": str (required), \"domain\": str (optional, defaults to current page host), \"path\": str (optional, defaults to \"/\"), \"secure\": bool (optional), \"http_only\": bool (optional — sets an HttpOnly cookie that JS cannot read/set), \"expires\": int (optional, Unix timestamp in seconds; omit for a session cookie)}. Field-name variants from common cookie exports are accepted: httpOnly (=http_only), expirationDate (=expires), sameSite, and case/camel variants — so you can paste cookies verbatim from browser extensions (EditThisCookie / Cookie-Editor) or Playwright/Puppeteer storage."),
                        "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds for wait_for_dom_stable (default: 10). The action polls every 0.5s and resolves when DOM mutation rate stabilizes."),
                        "viewport_width": AgentToolParam(type: .integer, description: "Viewport width in CSS pixels for set_viewport (e.g. 1920). Required together with viewport_height unless reset=true."),
                        "viewport_height": AgentToolParam(type: .integer, description: "Viewport height in CSS pixels for set_viewport (e.g. 1080). Required together with viewport_width unless reset=true."),
                        "reset": AgentToolParam(type: .boolean, description: "For set_viewport: when true, clear the session-level viewport override and fall back to the global browser setting."),
                        "full_page": AgentToolParam(type: .boolean, description: "For screenshot: capture the entire scrollable page by temporarily resizing the WebView to document.documentElement.scrollHeight. Default false captures viewport only. Capped at 32768px tall; when capped, result text includes 'Truncated: true' and the original height."),
                    ],
                    required: ["tool_title", "action"],
                    propertyOrdering: ["tool_title", "action", "tab_id", "url", "selector", "text", "coordinate_x", "coordinate_y", "direction", "amount", "scroll_count", "item_selector", "script", "user_agent", "max_depth", "keywords", "fuzzy", "cookies", "timeout", "viewport_width", "viewport_height", "reset", "full_page"]
                )
            )
        }

        if includeMemoryWrite {
            tools.append(AgentToolDefinition(
                name: "memory_write",
                description: "Write a memory entry to today's daily log (YYYY-MM-DD.md). Memories persist across all sessions. Each entry is prepended with a timestamp. Save: user preferences, recurring patterns, key facts, project conventions, reusable knowledge. Avoid saving passwords, API keys, tokens, or secrets unless the user explicitly confirms after being warned. Keep entries concise and general-purpose. GLOBAL.md is read-only (user-maintained via Settings).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Save user preference for Python', 'Note today's project context'). Use the same language as the user."),
                    "content": AgentToolParam(type: .string, description: "The memory content to write. Use concise Markdown with a short heading (## Topic) and context about what was done/learned."),
                ],
                required: ["tool_title", "content"],
                propertyOrdering: ["tool_title", "content"]
            ))
        }

        if includeMemoryTools {
            tools.append(AgentToolDefinition(
                name: "memory_get",
                description: "Retrieve memories from persistent storage. Supports keyword-based fuzzy search across memory files. Returns matching lines with surrounding context. Use this to recall previous knowledge, user preferences, or past notes.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Recall user preferences', 'Search past notes'). Use the same language as the user."),
                    "scope": AgentToolParam(type: .string, description: "Memory scope to search: 'daily' for daily logs only, 'all' for daily logs + GLOBAL.md.", enumValues: ["daily", "all"]),
                    "keywords": AgentToolParam(type: .string, description: "Space-separated keywords for fuzzy matching (e.g. 'python preference' or 'API key setup'). All keywords must appear in a line or its surrounding context for a match. Leave empty to return full memory files."),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title", "scope", "keywords"]
            ))
        }

        // [T-ios-vision-group #182] Expose read_image when the model can see
        // images ITSELF, or when a Vision Group is configured to see them on its
        // behalf. Previously a text-only model simply never got this tool, so an
        // image on disk was invisible to it with no recourse. The handler picks
        // the matching branch: native models get pixels, others get the Vision
        // Group's description as text.
        //
        // `isConfigured` is strict (group must resolve AND hold a usable
        // image-capable member), so we never advertise a tool whose non-native
        // path has nothing behind it.
        let nativeVision = activeModelHasNativeVision
        // Evaluate FIRST, not inside the `||` below: short-circuiting on
        // `nativeVision` would skip the call, and this read is also what keeps
        // `isConfiguredCached` — which the off-main T264 placeholder builder
        // relies on — up to date.
        let visionGroupConfigured = VisionGroupResolver.isConfigured
        if nativeVision || visionGroupConfigured {
            // Describe what this model will ACTUALLY receive. Promising "the
            // image is returned directly" to a text-only model would set up a
            // false expectation and invite it to re-call the tool when no pixels
            // arrive; the non-native branch returns a written description instead.
            let readImageDescription = nativeVision
                ? "Read an image file from the Linux filesystem and return it for visual analysis. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, or any visual output. The image is returned directly for your analysis along with metadata (dimensions, file size)."
                : "Read an image file from the Linux filesystem and return a written description of it. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, user-attached photos, or any visual output. You cannot see images directly, so the image is analyzed by a separate vision model and you receive its detailed description plus a transcription of any visible text, along with metadata (dimensions, file size). Because you cannot look again yourself, use the optional 'prompt' argument to ask for exactly what you need from the image — that is your only way to follow up on specific details."
            // [T-ios-vision-group-t264 #182] The `prompt` argument is what makes
            // the non-native branch usable for anything but a generic caption:
            // the host model can't look at the image, so this is its only lever
            // for directing the describing model. On the native branch the model
            // sees the pixels itself, so the argument is documented as optional
            // context rather than a question.
            let promptDescription = nativeVision
                ? "Optional. A note about what you are looking for in the image. Recorded alongside the result; the image itself is returned to you in full either way."
                : "Optional. A specific question or instruction about the image, e.g. 'transcribe the table', 'what error message is shown in this screenshot', 'describe the people and their expressions'. This is passed to the vision model that reads the image for you, so ask for exactly the detail you need. If omitted, a generic detailed description with full text transcription is returned."
            tools.append(AgentToolDefinition(
                name: "read_image",
                description: readImageDescription,
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'View generated bar chart', 'Inspect downloaded screenshot'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Linux path (e.g. /var/minis/attachments/chart.png) or minis:// URL (e.g. minis://attachments/chart.png)"),
                    "prompt": AgentToolParam(type: .string, description: promptDescription),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "prompt"]
            ))
        }

        return tools
    }

}
