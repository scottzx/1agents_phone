//
//  ChatHistorySearch.swift
//  Minis
//
//  Keyword search over past conversations, as a tool.
//
//  The query itself already existed — ChatStore has backed `minis-sessions-cli`
//  for a while — but only through the shell, which means only an agent with
//  `shell_execute` could reach it and only by remembering a CLI's flags. As a
//  first-class tool it is available to exactly the role that should have it:
//  a subagent doing a piece of work. A 总管 does not get it, for the same
//  reason it gets no shell — twenty snippets of old conversation is precisely
//  the kind of bulk that its transcript exists to stay free of. It dispatches
//  the lookup instead, and the subagent brings back the answer.
//
//  This also pays off the one cost of giving group members their own thread:
//  an agent cannot see a room's history from its 1:1 conversation, but it can
//  ask a subagent to go and read it.
//

import Foundation

enum ChatHistorySearchTool {

    static let name = "search_chat_history"

    /// Upper bound on hits per call. Twenty 400-character snippets is already
    /// most of a context window's patience.
    static let maxResults = 20

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: name,
            description: "Search the user's past conversations by keyword — their 1:1 chats with each assistant, and the group rooms those assistants talk in. Use it when the answer depends on something that was said before and is not in front of you: what the user decided, what they said they preferred, what a colleague already concluded, when something was last discussed. Returns dated snippets with who said them and which conversation they came from. It searches message text only, not files or tool output; for files use file_read.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. '搜索关于定价的历史对话'). Use the same language as the user."),
                "keywords": AgentToolParam(type: .string, description: "Space-separated words that must ALL appear in a matching message. Two or three specific terms work best — one broad word returns noise, and a whole sentence matches nothing, since these are substring matches rather than a semantic search. Search in the language the conversation was held in."),
                "scope": AgentToolParam(type: .string, description: "Which conversations to look at. 'all' (default) is everything the user can see. 'this_agent' is only the conversations of the agent that dispatched you — use it when the question is about what THIS assistant was told. 'groups' is only group rooms, for what was said in a discussion. 'sessions' searches the session_ids you pass, which is how you follow up on an earlier hit.", enumValues: ["all", "this_agent", "groups", "sessions"]),
                "session_ids": AgentToolParam(type: .string, description: "Required when scope is 'sessions'. Comma-separated session ids from an earlier result."),
                "since": AgentToolParam(type: .string, description: "Only messages on or after this date, as YYYY-MM-DD. Use it when the user says 'last week' or 'since we started' — an unbounded search over a long history returns the oldest coincidental match as readily as the relevant recent one."),
                "until": AgentToolParam(type: .string, description: "Only messages on or before this date, as YYYY-MM-DD."),
                "limit": AgentToolParam(type: .integer, description: "Maximum hits to return (default 10, max 20). Raise it only when you are genuinely surveying rather than looking something up."),
            ],
            required: ["tool_title", "keywords"],
            propertyOrdering: ["tool_title", "keywords", "scope", "session_ids", "since", "until", "limit"]
        )
    }

    /// Run one call and format what the model sees back.
    @MainActor
    static func handle(input: [String: Any], callerAgentId: String?) async -> String {
        let keywords = stringList(input["keywords"])
        guard !keywords.isEmpty else {
            return "Error: `keywords` is required — at least one word to look for."
        }

        let scope: ChatStore.ChatHistoryScope
        switch (input["scope"] as? String)?.lowercased() ?? "all" {
        case "this_agent":
            guard let callerAgentId else {
                return "Error: this task is not attached to an assistant, so 'this_agent' has nothing to scope to. Use scope 'all'."
            }
            scope = .agent(callerAgentId)
        case "groups":
            scope = .groups
        case "sessions":
            let ids = stringList(input["session_ids"])
            guard !ids.isEmpty else {
                return "Error: scope 'sessions' needs `session_ids`. They come from a previous search result."
            }
            scope = .sessions(ids)
        default:
            scope = .all
        }

        let limit = min(max(intValue(input["limit"]) ?? 10, 1), maxResults)
        let hits = await ChatStore.shared.searchChatHistory(
            keywords: keywords,
            scope: scope,
            limit: limit,
            startDate: date(input["since"]),
            endDate: date(input["until"])
        )

        guard !hits.isEmpty else {
            return """
                No messages matched \(keywords.joined(separator: " + ")).

                These are substring matches, so try fewer or shorter keywords, \
                or the words the user would actually have typed. If a second \
                search also comes up empty, say plainly that it was never \
                discussed rather than reconstructing what it might have said.
                """
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = ["\(hits.count) matching message(s), newest first:"]
        for hit in hits {
            lines.append("")
            lines.append("[\(formatter.string(from: hit.createdAt))] \(await describeSource(hit))")
            lines.append("session_id: \(hit.sessionId)")
            lines.append(hit.snippet)
        }
        lines.append("")
        lines.append(
            "Snippets are trimmed around the keyword, so read them as pointers "
                + "rather than as the whole exchange — search again with scope "
                + "'sessions' and that session_id if you need what came around one. "
                + "Quote what you found accurately and say when it was said; do not "
                + "smooth over a snippet that contradicts what you expected."
        )
        return lines.joined(separator: "\n")
    }

    /// "群聊「产品圆桌」· 市场专家说" / "与 健身教练 的私聊 · 用户说"
    @MainActor
    private static func describeSource(_ hit: ChatStore.ChatHistoryHit) async -> String {
        let speaker: String
        if hit.role == "user" {
            speaker = String(localized: "用户")
        } else if let sender = hit.senderAgentId,
                  let agent = await AgentStore.shared.loadAgent(sender) {
            speaker = agent.name
        } else if let owner = hit.agentId,
                  let agent = await AgentStore.shared.loadAgent(owner) {
            speaker = agent.name
        } else {
            speaker = String(localized: "助手")
        }

        let title = hit.sessionTitle ?? String(localized: "未命名会话")
        switch hit.spawnRole {
        case GroupSessionRole.group:
            return String(localized: "群聊「\(title)」· \(speaker)说")
        case GroupSessionRole.member:
            return String(localized: "群聊「\(title)」中 \(speaker) 自己的思路")
        default:
            return String(localized: "私聊「\(title)」· \(speaker)说")
        }
    }

    // MARK: - Argument coercion
    //
    // Same normalization AgentDirectoryCoordinator does, and for the same
    // reason: providers are inconsistent about JSON types, and a well-formed
    // call that merely arrived stringly-typed should not be rejected.

    /// Accepts a real JSON array, or the space/comma-separated string the
    /// schema asks for. Providers send both for the same declared parameter,
    /// and memory_get's handler already had to tolerate the same pair.
    private static func stringList(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let single = value as? String {
            return single
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: raw)
    }
}
