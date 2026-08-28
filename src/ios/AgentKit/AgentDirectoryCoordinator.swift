//
//  AgentDirectoryCoordinator.swift
//  Minis
//
//  Turns `create_agent` / `list_agents` / `send_agent_message` into real work.
//
//  Structured like SubagentCoordinator (tools in, model-readable text out) so
//  the two dispatch surfaces stay symmetrical, but the runtime is different in
//  one way that drives everything below: the recipient of an inter-agent
//  message is not a scratch session we own, it is a conversation the user
//  reads and may be typing into right now. So delivery is written to be
//  non-destructive — the recipient's composer draft is preserved, a running
//  turn is refused rather than silently pre-empted, and the message lands as a
//  visibly attributed user turn instead of a hidden injection.
//
//  Loop safety
//  -----------
//  Two agents can each hold the other's id, so A→B→A is one prompt away. The
//  busy check already breaks the tight case (A is parked inside its tool call,
//  so it is processing, so B's reply-send is refused) — but only while A
//  waits. `relayOrigin` closes the rest: it records the live from→to edges of
//  every in-flight relay, and a send is refused if the recipient is already
//  upstream in the caller's chain, or if that chain is `maxHops` long.
//

import Foundation

@MainActor
final class AgentDirectoryCoordinator {
    static let shared = AgentDirectoryCoordinator()

    private let logger = AppLogger(category: "AgentDirectory")

    /// Live relay edges: recipient session → sender session. An entry exists
    /// from the moment a message is delivered until the recipient's turn ends,
    /// which is exactly the window in which a reply could bounce back.
    private var relayOrigin: [String: String] = [:]

    /// How many agents one message may pass through. Three is enough for
    /// "ask a colleague, who asks a specialist" and short enough that a
    /// runaway relay costs a handful of turns rather than a token budget.
    private static let maxHops = 3

    /// Palette the create-agent UI offers, reused so an agent the model
    /// created looks like one the user created.
    private static let palette = ["#5B8DEF", "#E0A33E", "#4CAF7D", "#C46BC4", "#E4694E", "#5AA9C4"]

    private init() {}

    // MARK: - Entry point

    func handle(
        toolName: String,
        input: [String: Any],
        callerSessionId: String,
        callerAgentId: String?
    ) async -> String {
        switch toolName {
        case "create_agent":
            return await handleCreate(input: input)
        case "list_agents":
            return await handleList(callerAgentId: callerAgentId)
        case "send_agent_message":
            return await handleSend(
                input: input,
                callerSessionId: callerSessionId,
                callerAgentId: callerAgentId
            )
        default:
            return "Unknown agent-directory tool: \(toolName)"
        }
    }

    // MARK: - create_agent

    private func handleCreate(input: [String: Any]) async -> String {
        let name = string(input["name"])
        guard !name.isEmpty else {
            return "Error: `name` is required — the new assistant needs something for the user to call it."
        }
        let persona = string(input["persona"])
        guard !persona.isEmpty else {
            return "Error: `persona` is required. Without it the new assistant is a blank copy of the default one, which is not worth a roster slot."
        }

        let policy = AgentToolPolicy(rawValue: string(input["work_mode"]).lowercased()) ?? .orchestrator
        let emoji = string(input["emoji"])
        let accent = normalizedHex(string(input["accent_color"]))
            ?? Self.palette[AgentStore.shared.agents.count % Self.palette.count]

        let agent = await AgentStore.shared.create(
            name: name,
            emoji: emoji,
            title: string(input["title"]),
            summary: string(input["summary"]),
            accentColor: accent,
            toolPolicy: policy,
            personaBody: persona
        )
        logger.info("created agent \(agent.id.prefix(8)) name=\(name) policy=\(policy.rawValue)")

        return """
            Assistant created.
            agent_id: \(agent.id)
            name: \(agent.emoji) \(agent.name)\(agent.title.isEmpty ? "" : " (\(agent.title))")
            mode: \(policy.rawValue)

            It is in the user's roster now, with its own conversation — they \
            can open it from the home screen. It has no history and has not \
            been told anything; use send_agent_message with this agent_id if \
            it needs a first instruction from you.

            Tell the user it exists, in one line, in your own voice. Do not \
            list what tools it has or explain how agents work.
            """
    }

    // MARK: - list_agents

    private func handleList(callerAgentId: String?) async -> String {
        await AgentStore.shared.refresh()
        let roster = AgentStore.shared.agents
        guard !roster.isEmpty else {
            return "No assistants in the roster yet. create_agent adds one."
        }

        var lines: [String] = []
        for agent in roster {
            var entry = "agent_id: \(agent.id)"
            entry += "\nname: \(agent.emoji) \(agent.name)"
            if !agent.title.isEmpty { entry += " (\(agent.title))" }
            entry += "\nmode: \(agent.toolPolicy.rawValue)"
            if !agent.summary.isEmpty { entry += "\nabout: \(agent.summary)" }
            if agent.id == callerAgentId {
                entry += "\nnote: this is you — you cannot message yourself."
            } else if let main = agent.mainSessionId, isBusy(sessionId: main) {
                entry += "\nstatus: busy (mid-turn right now)"
            } else {
                entry += "\nstatus: idle"
            }
            lines.append(entry)
        }

        return lines.joined(separator: "\n\n") + """


            Address one with send_agent_message. Each of them has its own \
            memory and cannot see this conversation, so whatever you send has \
            to carry its own context.
            """
    }

    // MARK: - send_agent_message

    private func handleSend(
        input: [String: Any],
        callerSessionId: String,
        callerAgentId: String?
    ) async -> String {
        let targetId = string(input["agent_id"])
        guard !targetId.isEmpty else {
            return "Error: `agent_id` is required. Call list_agents to see who exists."
        }
        let message = string(input["message"])
        guard !message.isEmpty else {
            return "Error: `message` is required."
        }
        guard targetId != callerAgentId else {
            return "Error: that agent_id is you. To think something through, just think it — do not message yourself."
        }
        guard let target = await AgentStore.shared.loadAgent(targetId) else {
            return "No assistant with agent_id \(targetId). Call list_agents for the current roster."
        }
        guard !target.isArchived else {
            return "\(target.name) is archived and is not part of the roster any more. Tell the user rather than working around it."
        }

        let waitSeconds = min(max(int(input["wait_seconds"]) ?? 0, 0), AgentDirectoryTools.maxWaitSeconds)
        let interrupt = bool(input["interrupt"]) ?? false

        guard let targetSession = await AgentStore.shared.openMainSession(for: targetId), !targetSession.isEmpty else {
            return "Could not open \(target.name)'s conversation, so the message was not delivered."
        }

        // Loop guard — see the note at the top of this file.
        if let refusal = relayRefusal(from: callerSessionId, to: targetSession, targetName: target.name) {
            return refusal
        }

        let (vm, isFresh) = ViewModelCache.shared.getOrCreate(for: targetSession)
        if isFresh { await vm.loadSession() }

        if vm.isProcessing || isBusy(sessionId: targetSession) {
            guard interrupt else {
                return """
                    \(target.name) is mid-turn right now, so the message was NOT delivered.

                    It may be answering the user. Either wait and send again, \
                    or resend with interrupt: true if what you have genuinely \
                    supersedes what it is doing.
                    """
            }
            vm.cancel()
            // cancel() flips isProcessing synchronously, so send() below would
            // be accepted immediately — but the cancelled loop is still tearing
            // down and writing to the transcript. A short settle keeps the
            // interrupted turn and the incoming message from interleaving in a
            // conversation the user actually reads.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let sender = await senderLabel(agentId: callerAgentId)
        let inbound = envelope(from: sender, message: message, awaitingReply: waitSeconds > 0)

        // Preserve whatever the user had half-typed in that conversation.
        // send() clears inputText synchronously, so restoring right after the
        // call puts their draft back untouched.
        let draft = vm.inputText
        let messageCountBeforeSend = vm.messages.count
        vm.inputText = inbound
        vm.send()
        let accepted = vm.isProcessing
        vm.inputText = draft

        guard accepted else {
            return """
                \(target.name) did not accept the message — its conversation is \
                at or near its context limit and is waiting on the user to \
                compact it. Nothing was delivered. Tell the user plainly \
                instead of retrying.
                """
        }

        relayOrigin[targetSession] = callerSessionId
        SessionBadgeStore.shared.pushFront(.unread, for: targetSession)
        logger.info("relayed message to agent=\(targetId.prefix(8)) wait=\(waitSeconds)s interrupt=\(interrupt)")

        guard waitSeconds > 0 else {
            scheduleRelayCleanup(targetSession: targetSession, vm: vm)
            return """
                Message delivered to \(target.name). You did not wait, so its \
                reply goes to its own conversation and you will not see it — \
                send with wait_seconds if you need the answer. Do not tell the \
                user you will report back on what it says.
                """
        }

        let landed = await awaitTurn(vm: vm, seconds: waitSeconds)

        guard landed else {
            // Edge deliberately left in place — the recipient is still mid-turn
            // and could still try to answer us, which is exactly what the loop
            // guard exists to catch. The cleanup task retires it.
            scheduleRelayCleanup(targetSession: targetSession, vm: vm)
            return """
                \(target.name) is still working on it after \(waitSeconds)s and \
                the wait ran out. Its answer will land in its own conversation, \
                not here. Either send again with a longer wait_seconds, or tell \
                the user where the answer will show up — do not promise to \
                bring it back yourself.
                """
        }

        relayOrigin[targetSession] = nil

        guard let reply = lastAssistantText(vm: vm, after: messageCountBeforeSend), !reply.isEmpty else {
            return """
                \(target.name) received the message but produced no text reply. \
                Say so plainly rather than inventing what it might have said.
                """
        }

        return """
            \(target.name) replied:

            \(reply)

            That is their answer, in their words. Use it, attribute it to them \
            when it matters, and disagree with it if you have reason to — you \
            are the one talking to the user.
            """
    }

    // MARK: - Relay bookkeeping

    /// Refuse a send that would close a loop, or run one too deep.
    private func relayRefusal(from caller: String, to target: String, targetName: String) -> String? {
        var chain: [String] = [caller]
        var cursor = caller
        var hops = 0
        while let upstream = relayOrigin[cursor], hops < Self.maxHops * 2 {
            chain.append(upstream)
            cursor = upstream
            hops += 1
        }
        if chain.contains(target) {
            return """
                Not delivered: \(targetName) is already upstream in this exchange \
                — the message you are answering came from them, directly or \
                through someone else. Answering it here is the reply; sending \
                one back starts a loop. End your turn with the answer instead.
                """
        }
        if chain.count > Self.maxHops {
            return """
                Not delivered: this message has already been passed between \
                \(Self.maxHops) assistants. Handle it yourself or tell the user \
                it needs their call, rather than passing it along again.
                """
        }
        return nil
    }

    /// Drop the relay edge once the recipient's turn ends. Used on the paths
    /// where we are not parked waiting for it ourselves.
    private func scheduleRelayCleanup(targetSession: String, vm: AIChatViewModel) {
        Task { [weak self] in
            // Bounded: a turn that outlives this has long since stopped being
            // part of the relay we are guarding.
            let deadline = Date().addingTimeInterval(TimeInterval(AgentDirectoryTools.maxWaitSeconds))
            while vm.isProcessing, Date() < deadline {
                if Task.isCancelled { break }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
            self?.relayOrigin[targetSession] = nil
        }
    }

    // MARK: - Delivery helpers

    /// Park until the recipient's turn ends. Returns false if the wait ran out
    /// with the turn still going.
    private func awaitTurn(vm: AIChatViewModel, seconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while vm.isProcessing && Date() < deadline {
            // The caller's own turn is suspended inside this tool call, so a
            // tighter poll buys nothing — same reasoning as the dispatch
            // tools' 1s granularity.
            if Task.isCancelled { return false }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return false }
        }
        return !vm.isProcessing
    }

    /// The recipient's answer: the text of the assistant turn that followed our
    /// message. Bounded by `after` so a stalled turn cannot hand back the reply
    /// to whatever the user asked previously.
    private func lastAssistantText(vm: AIChatViewModel, after index: Int) -> String? {
        guard index <= vm.messages.count else { return nil }
        let fresh = vm.messages.suffix(from: min(index, vm.messages.count))
        guard let last = fresh.last(where: { $0.role == .assistant }) else { return nil }
        let joined = last.blocks
            .filter { $0.kind == .text }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// How the message is presented in the recipient's transcript. The header
    /// is visible to the user on purpose: an assistant they never addressed
    /// speaking in their conversation should never look like it came from them.
    private func envelope(from sender: String, message: String, awaitingReply: Bool) -> String {
        var text = String(localized: "📨 来自助手「\(sender)」的消息：") + "\n\n" + message
        if awaitingReply {
            text += "\n\n" + String(localized: "（对方正在等你的回复，你这一轮的最终文字会原样回传给它。）")
        }
        return text
    }

    private func senderLabel(agentId: String?) async -> String {
        guard let agentId, let agent = await AgentStore.shared.loadAgent(agentId) else {
            return String(localized: "另一个助手")
        }
        let emoji = agent.emoji.isEmpty ? "" : agent.emoji + " "
        return emoji + agent.name
    }

    private func isBusy(sessionId: String) -> Bool {
        if let vm = ViewModelCache.shared.get(for: sessionId), vm.isProcessing { return true }
        return SessionActivityTracker.shared.isActive(sessionId)
    }

    // MARK: - Argument coercion
    //
    // Providers are inconsistent about JSON types — a boolean can arrive as
    // "true" and an integer as "30" — so the tool layer normalizes rather than
    // failing on a well-formed call that was merely stringly typed.

    private func string(_ value: Any?) -> String {
        guard let value = value as? String else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let s = value as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
        if let i = value as? Int { return i != 0 }
        return nil
    }

    /// Accept `#RRGGBB` or a bare `RRGGBB`; reject anything else so a bad value
    /// falls through to the palette rather than to AgentAccent's grey fallback.
    private func normalizedHex(_ raw: String) -> String? {
        var value = raw
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, UInt32(value, radix: 16) != nil else { return nil }
        return "#" + value.uppercased()
    }
}
