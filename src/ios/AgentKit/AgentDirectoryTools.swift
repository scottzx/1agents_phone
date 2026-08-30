//
//  AgentDirectoryTools.swift
//  Minis
//
//  The roster as a tool surface: an agent can hire a colleague, look up who
//  else exists, and talk to them.
//
//  These three sit deliberately OUTSIDE the orchestrator/standalone split that
//  SubagentTools lives on. Dispatching work is a property of how an agent
//  works; knowing your colleagues is a property of being an agent at all, so
//  the 总管 and the 全能助手 both get the same surface. What gates them instead
//  is `agentRole`: only a `.main` session sees them, for the same reason a
//  subagent cannot spawn subagents — an executor that could mint agents or
//  start conversations between them would make the graph unbounded and leave
//  the user with a roster nobody asked for.
//
//  On the messaging shape
//  ----------------------
//  Modelled on Grok Bot's `task(resume:)`: a message addressed at an EXISTING
//  agent id rather than a fresh spawn, delivered into the conversation that
//  agent already has, with the same two rules that design settled on —
//
//    - a busy target is a refusal, not a queue. Silently stacking messages
//      behind a running turn hides the contention; `interrupt: true` is the
//      explicit opt-in, and it is the caller who has to decide.
//    - waiting for the reply is a parameter, not the default. `wait_seconds`
//      parks the caller inside its tool call exactly like `check_subagent`
//      does, so the reply can be folded into the same turn; 0 posts and moves
//      on.
//
//  Group A2A extends that same tool rather than adding a parallel verb. A
//  direct message is `is_group:false + agent_id[] + message`; a pseudo-group
//  message is `is_group:true + group_id + agent_id[] + message`. The latter writes one public line into
//  the group's shared transcript, then the group orchestrator projects that
//  transcript into each addressed member's private group-member session.
//
//  The one thing that is NOT borrowed: a subagent's transcript is scratch, but
//  a peer agent's main session is a conversation the user reads. So an inbound
//  message lands as a visibly attributed user turn, not a hidden injection.
//

import Foundation

enum AgentDirectoryTools {

    static let names: Set<String> = ["create_agent", "list_agents", "send_agent_message"]

    /// Upper bound on a single `send_agent_message` park, in seconds. Shared
    /// with the dispatch tools so a caller cannot park longer waiting on a
    /// colleague than it can waiting on its own subagent.
    static var maxWaitSeconds: Int { SubagentTools.maxWaitSeconds }

    static var definitions: [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "create_agent",
                description: "Create a new persistent assistant. It appears in the user's roster immediately, with its own long-lived conversation, its own memory and its own persona — this is hiring a colleague, not starting a task. Use it when the user asks for a new assistant, or when a recurring area of their life clearly deserves a dedicated one (a fitness coach, a work 总管, a study partner). For one-off work use spawn_subagent instead: a new agent that gets used once is clutter the user has to clean up. Returns the new agent_id, which send_agent_message can address right away.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. '创建健身教练助手' / 'Create a research assistant'). Use the same language as the user."),
                    "name": AgentToolParam(type: .string, description: "The assistant's name, as the user will see it in the roster. Short and human — a name, not a job description."),
                    "title": AgentToolParam(type: .string, description: "Short role label shown next to the name, 2-6 characters/words (e.g. '总管', '健身教练', 'Research')."),
                    "summary": AgentToolParam(type: .string, description: "One line describing what it is for, shown as the roster subtitle. Written for the user, in their language."),
                    "persona": AgentToolParam(type: .string, description: "The assistant's character, written as its SOUL.md body and injected into every one of its conversations. Write it in the second person ('You are ...'): who it is, how it speaks, what it cares about, what it should never do. This is the only thing that makes the new agent different from a blank one — a vague persona produces a colleague indistinguishable from you, so be specific."),
                    "work_mode": AgentToolParam(type: .string, description: "How it works. 'orchestrator' (总管模式): no shell/file-write/browser of its own — it dispatches subagents and keeps its conversation clean. The right default for anything the user will talk to daily. 'standalone' (全能模式): the full execution toolset, does the work itself; pick it for a hands-on tool-shaped agent, accepting that its context fills up faster.", enumValues: ["orchestrator", "standalone"]),
                    "emoji": AgentToolParam(type: .string, description: "One or two emoji used as its avatar (default 🤖). Pick something that reads as this agent at a glance."),
                    "accent_color": AgentToolParam(type: .string, description: "Avatar tint as #RRGGBB. Omit to have one picked from the app palette."),
                ],
                required: ["tool_title", "name", "title", "summary", "persona", "work_mode"],
                propertyOrdering: ["tool_title", "name", "title", "summary", "persona", "work_mode", "emoji", "accent_color"]
            ),
            AgentToolDefinition(
                name: "list_agents",
                description: "List the assistants that exist in this app, with the agent_id needed to message each one, what it is for, and whether it is busy right now. Call it before send_agent_message rather than guessing an id, and when the user refers to another assistant by name.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title"]
            ),
            AgentToolDefinition(
                name: "send_agent_message",
                description: "Talk to other assistants with one unified addressing shape. Private broadcast: pass is_group:false, agent_id as a list, and message; the same message is delivered to every listed assistant's main conversation. Pseudo-group message: pass is_group:true, group_id, agent_id as a list, and message; the line is written to that group's shared transcript and listed members receive the projected shared context in their own group-member sessions. In group mode, agent_id: [\"at_all\"] addresses every other member; if at_all appears with ids, at_all wins and the ids are ignored. The sender must belong to the group, and only its owner assistant may use at_all.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. '问健身教练拉伸方案'). Use the same language as the user."),
                    "is_group": AgentToolParam(type: .boolean, description: "false: private broadcast to the agent_id list. true: post a visible message to the specified pseudo-group's shared transcript."),
                    "group_id": AgentToolParam(type: .string, description: "Required only when is_group is true: the explicit group id whose shared transcript receives this message. Copy it from the group context; never guess it."),
                    "agent_id": AgentToolParam(type: .stringArray, description: "Recipients as a list of agent ids. In group mode every id must be a member. Group owners use [\"at_all\"] to address everyone; if it appears alongside ids, at_all wins."),
                    "message": AgentToolParam(type: .string, description: "What you want to say. Self-contained — it starts with none of your context. Write it as one colleague to another, in the user's language, and say plainly what you want back."),
                    "wait_seconds": AgentToolParam(type: .integer, description: "Private mode only: seconds to wait for the reply (default 0, max 240). Group mode is routed by the group orchestrator and does not return peer replies through this tool call."),
                    "interrupt": AgentToolParam(type: .boolean, description: "Private mode only: if true, interrupt a busy recipient before delivery. Never applies to group mode."),
                ],
                required: ["tool_title", "is_group", "agent_id", "message"],
                propertyOrdering: ["tool_title", "is_group", "group_id", "agent_id", "message", "wait_seconds", "interrupt"]
            ),
        ]
    }

    /// The shared prompt block describing this surface.
    ///
    /// One text, injected into BOTH the orchestrator prompt and the standalone
    /// one, because the rules it states are about the roster rather than about
    /// how a particular agent works — and because two divergent copies of a
    /// protocol both sides have to follow is how inter-agent etiquette rots.
    ///
    /// `canDispatch` is the single genuine difference: the "that's a subagent's
    /// job" escape hatch only exists for an orchestrator, and pointing a
    /// standalone agent at a tool it was never handed is how a model ends up
    /// insisting it dispatched something it could not.
    static func promptSection(canDispatch: Bool) -> String {
        let insteadOfDelegating = canDispatch
            ? "Work that simply needs doing is a subagent's job, not a colleague's."
            : "Work that simply needs doing, you do yourself."

        return """
        ## Your colleagues

        Other assistants live in this app alongside you. Each has its own \
        persona, its own memory and its own long-running conversation with the \
        user, and none of them can see yours.

        - list_agents: who exists, what each is for, and whether it is busy.
        - send_agent_message: use `is_group: false` + an `agent_id` list for \
        a private broadcast, or `is_group: true` + explicit `group_id` + an \
        `agent_id` list for a group's shared transcript. `wait_seconds` \
        applies only to private messages.
        - create_agent: hire a new one. It shows up in the user's roster \
        immediately.

        Message a colleague when it genuinely knows something you do not, or \
        when the matter is theirs. Do not route ordinary work through them \
        because it feels like delegation — a peer answers as itself, in its \
        own conversation, where the user can read it. \(insteadOfDelegating)

        ## send_agent_message call format

        `is_group` is required. `agent_id` is always a JSON list, even when it
        has only one recipient. Never use the old scalar agent_id form or an
        `agent_ids` field.

        - Private broadcast: `{ "is_group": false, "agent_id": ["<agent-id>"],
          "message": "..." }`. Omit group_id. Every listed agent receives the
          same private message. wait_seconds and interrupt work only here.
        - Group A2A: `{ "is_group": true, "group_id": "<group-id>",
          "agent_id": ["<member-id>"], "message": "..." }`. This writes one
          public line to the shared transcript and wakes only those members.
        - Group owner broadcast: `{ "is_group": true, "group_id": "<group-id>",
          "agent_id": ["at_all"], "message": "..." }`. Only the owner may
          use at_all. If at_all appears with any ids, at_all wins and the ids
          are ignored.

        In group mode, put recipients only in agent_id and keep message as
        plain visible prose: do not put @name, <@id>, agent_ids, or an at_all
        parameter inside the message.

        Create an agent when the user asks for one, or when some standing part \
        of their life clearly wants a dedicated assistant rather than a corner \
        of yours. Give it a real persona, tell the user it now exists and \
        where to find it, and stop there — do not create a second agent as a \
        way of solving one task.

        When a message from another assistant arrives in YOUR conversation it \
        is shown as such. Answer it as you would answer a colleague: if they \
        are waiting, your final reply for that turn is what they receive \
        verbatim, so make it stand on its own and skip the clarifying question \
        nobody is there to answer. The user is reading over your shoulder \
        either way.

        A GROUP is a shared transcript projected into one private member \
        session per assistant, not a permanently open chat connection. When a \
        group turn gives you its group_id, use the Group A2A format above to \
        hand off. That public message is \
        what wakes those members; a private agent_id message does not.

        """
    }
}
