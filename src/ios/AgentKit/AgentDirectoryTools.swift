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
                description: "Send a message to another assistant in the roster. It arrives in that assistant's own conversation as a clearly attributed message from you, it answers with its own persona, memory and tools, and — if you waited — its reply comes back to you here. Use it to consult a colleague who knows a domain you do not, or to hand something over that belongs to them. It is NOT a way to get work done cheaply: a peer answers as itself, on its own terms, and the user can read the whole exchange; for work that just needs doing, spawn_subagent is the right tool. The other assistant cannot see this conversation, your memory or your persona, so the message must carry everything it needs.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. '问健身教练拉伸方案'). Use the same language as the user."),
                    "agent_id": AgentToolParam(type: .string, description: "The recipient's agent_id, from list_agents or create_agent."),
                    "message": AgentToolParam(type: .string, description: "What you want to say. Self-contained — it starts with none of your context. Write it as one colleague to another, in the user's language, and say plainly what you want back."),
                    "wait_seconds": AgentToolParam(type: .integer, description: "Seconds to park here waiting for its reply (default 0 = deliver and return immediately WITHOUT a reply, max 240). Size it to what you asked: a quick question 30-60, real work 120-240. Waiting does not block the other assistant."),
                    "interrupt": AgentToolParam(type: .boolean, description: "If the recipient is mid-turn, sending fails by default. Set true to cut its current turn short and deliver anyway — only when what you are sending genuinely supersedes what it is doing. It may be answering the user right now."),
                ],
                required: ["tool_title", "agent_id", "message"],
                propertyOrdering: ["tool_title", "agent_id", "message", "wait_seconds", "interrupt"]
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
        - send_agent_message: say something to one of them. `wait_seconds` \
        parks you here until it answers, which is the only way its reply \
        reaches you — send with 0 and the answer goes to its conversation, not \
        to you.
        - create_agent: hire a new one. It shows up in the user's roster \
        immediately.

        Message a colleague when it genuinely knows something you do not, or \
        when the matter is theirs. Do not route ordinary work through them \
        because it feels like delegation — a peer answers as itself, in its \
        own conversation, where the user can read it. \(insteadOfDelegating)

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

        You may also be put in a GROUP with some of them — several assistants \
        and the user in one room. A group turn arrives tagged with the room's \
        name and the other participants, and it comes with its own rules, \
        which the tag block spells out. The one worth knowing in advance: in a \
        room nobody hears you unless you @ them by name, so hand off \
        explicitly or let the conversation end. Your 1:1 tools are not the way \
        to reach someone who is standing in the same room as you.

        """
    }
}
