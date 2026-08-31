//
//  GroupMentionRouter.swift
//  Minis
//
//  Who speaks next in a group. Pure functions over values — no store, no view
//  model, no actor — so the routing rules can be tested exhaustively without a
//  model call, a database or a device.
//
//  The turn-taking mechanics (round rotation, the delta window, the `(pass)`
//  protocol) are grok-bot 0.18's, from
//  modules/grok-bot-0.18-reconstructed/source/host/groups/group-chat.ts. Two
//  things here are deliberately NOT grok's:
//
//  1. **Routing policy.** grok's default is broadcast — a message with no
//     mentions wakes everybody. Ours is directed; see `resolveResponders`.
//
//  2. **Mentions address an id, not a name.** grok matches the text `@ann`
//     against a member called "Ann". That is how WeChat does it, and it is
//     wrong for the same reasons: rename an agent and every past mention
//     silently re-points or dies, two agents with similar names are a coin
//     flip, and a model that gets one character wrong addresses nobody with no
//     way to notice. Every real IM stores the id and shows the name — Slack
//     `<@U024BE7LH>`, Discord `<@123456789>`, Matrix a matrix.to link — so
//     that is what a stored group message carries too:
//
//         canonical (DB, LLM prompt, routing):  你说得对 <@a3f1…> 来看下
//         rendered  (UI, hardware, history):    你说得对 @市场专家 来看下
//
//     `encode` goes name → token on the way in from the composer, `render`
//     goes token → name at every presentation boundary, and `parseMentions`
//     only trusts tokens. Bare names still resolve as a tolerated fallback so a
//     model that forgets the format is not silently ignored — but a token, when
//     present, is authoritative and exact.
//

import Foundation

// Shared Apple-domain mention parsing and routing.

public enum GroupMentionRouter {

    // MARK: - Wire format

    /// Addresses the whole room. Not a member id, and no agent id can collide
    /// with it: `AgentProfile.sanitize` produces UUIDs or `agent-default`.
    static let everyoneId = "everyone"

    /// The canonical form of one mention: `<@id>`.
    ///
    /// Discord's shape rather than Slack's `<@id|label>`, because the label
    /// would be a second thing for a model to get right and it is never read —
    /// `render` looks the name up from the roster anyway. The parser still
    /// tolerates a label, so a model that writes one is not punished for it.
    static func token(for id: String) -> String { "<@\(id)>" }

    static var everyoneToken: String { token(for: everyoneId) }

    /// `<@id>` or `<@id|label>`. The id charset matches `AgentProfile.sanitize`.
    private static let tokenPattern = try? NSRegularExpression(
        pattern: "<@([A-Za-z0-9_-]{1,64})(\\|[^>]*)?>"
    )

    /// Every mention token in `text`, as (range, id) in source order.
    private static func tokens(in text: String) -> [(range: NSRange, id: String)] {
        guard let tokenPattern else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return tokenPattern.matches(in: text, range: full).compactMap { match in
            guard let idRange = Range(match.range(at: 1), in: text) else { return nil }
            return (match.range, String(text[idRange]))
        }
    }

    /// Case-folded copy of `chars`, one element per element.
    ///
    /// NOT `Array(text.lowercased())`: lowercasing is not length-preserving in
    /// every script (Turkish `İ` folds to two scalars), and the matcher indexes
    /// the folded array with offsets computed on the original. A one-off
    /// mismatch there is an out-of-bounds crash on a message someone typed, so
    /// the fold is done per character and pinned to the same length.
    private static func caseFolded(_ chars: [Character]) -> [Character] {
        chars.map { character in
            guard let folded = character.lowercased().first else { return character }
            return folded
        }
    }

    // MARK: - Encode / render

    /// Composer text → canonical text: `@市场专家` becomes `<@a3f1…>`.
    ///
    /// Runs once, on send. The composer stays plain text showing `@名字`,
    /// because it is a UITextView and cannot draw a chip the way Slack's
    /// rich composer does — so the readable form is what the user edits and
    /// the id form is what gets stored. Same split Telegram uses for a typed
    /// `@username`, which it resolves to a `text_mention` entity at send time.
    ///
    /// Existing tokens are left alone, so encoding twice is a no-op.
    ///
    /// Two members with the same display name resolve to the earlier one in
    /// roster order. That is a real ambiguity in the text the user typed and
    /// there is nothing better to do with it; the `@` picker is the way to be
    /// unambiguous.
    public static func encode(_ text: String, members: [GroupMember]) -> String {
        guard text.contains("@") else { return text }

        // Protect existing tokens from the name pass below: an id could
        // otherwise contain something that looks like a handle.
        var protectedRanges: [Range<Int>] = []
        let chars = Array(text)
        for token in tokens(in: text) {
            guard let range = Range(token.range, in: text) else { continue }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            protectedRanges.append(start..<end)
        }

        // Longest handle first, same rule parseMentions uses, so `@小明` cannot
        // claim text inside `@小明明`.
        var candidates: [(handle: [Character], id: String)] = everyoneHandles
            .map { (Array($0.lowercased()), everyoneId) }
        for member in members {
            for handle in handles(for: member) {
                candidates.append((Array(handle), member.id))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.handle.count != rhs.handle.count { return lhs.handle.count > rhs.handle.count }
            return (lhs.id == everyoneId) && (rhs.id != everyoneId)
        }

        let lower = caseFolded(chars)
        var replacements: [(range: Range<Int>, id: String)] = []
        var claimed = [Bool](repeating: false, count: chars.count)
        for range in protectedRanges {
            for index in range where index < claimed.count { claimed[index] = true }
        }

        for candidate in candidates {
            for range in mentionRanges(in: lower,
                                       handle: candidate.handle,
                                       requireTrailingBoundary: isASCIIAlphanumeric(candidate.handle)) {
                guard !(range.contains { claimed[$0] }) else { continue }
                for index in range { claimed[index] = true }
                replacements.append((range, candidate.id))
            }
        }
        guard !replacements.isEmpty else { return text }

        // Apply back to front so earlier offsets stay valid.
        var result = chars
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(replacement.range, with: Array(token(for: replacement.id)))
        }
        return String(result)
    }

    /// Canonical text → readable text: `<@a3f1…>` becomes `@市场专家`.
    ///
    /// Applied at every boundary where a human or a model reads the message —
    /// the transcript UI, the projected history in a turn prompt, the text sent
    /// to the device. The stored row and the routing input stay canonical.
    ///
    /// A token for an agent that has left the roster renders as
    /// `@已退出的成员` rather than as a raw id: the line stays readable, and it
    /// stays honest about who is no longer here.
    public static func render(_ text: String, members: [GroupMember]) -> String {
        let found = tokens(in: text)
        guard !found.isEmpty else { return text }

        var result = text
        // Back to front, so each replacement leaves earlier ranges valid.
        for token in found.reversed() {
            guard let range = Range(token.range, in: result) else { continue }
            let name: String
            if token.id == everyoneId {
                name = String(localized: "所有人")
            } else if let member = members.first(where: { $0.id == token.id }) {
                name = member.name
            } else {
                name = String(localized: "已退出的成员")
            }
            result.replaceSubrange(range, with: "@" + name)
        }
        return result
    }

    // MARK: - Handles

    /// Tokens that address the whole room. Matched with the same boundary rule
    /// as a member handle, so `@allow` is not `@all`.
    static let everyoneHandles = ["所有人", "全体", "everyone", "all"]

    /// The names one member answers to. Mirrors grok's `memberMentionHandles`
    /// (full name, name without spaces, first word) plus `title`, which is how
    /// a user naturally addresses a role-shaped agent ("@市场专家") rather than
    /// by its given name.
    static func handles(for member: GroupMember) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func add(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            result.append(value)
        }

        let name = member.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        add(name)
        add(name.components(separatedBy: .whitespacesAndNewlines).joined())
        if let first = name.split(separator: " ").first { add(String(first)) }
        add(member.title)

        return result
    }

    // MARK: - Matching

    /// What one message addresses.
    struct MentionScan: Equatable {
        var isEveryone: Bool
        /// Member ids in roster order, not in the order they appear in the text.
        var memberIds: [String]
        /// True when something was matched by NAME rather than by token — an
        /// agent that wrote `@市场专家` instead of copying `<@id>`. Routed the
        /// same way, but surfaced so the bridge log can say the model is not
        /// following the format, which is the only symptom before the day a
        /// rename makes it address nobody.
        var usedLooseNameMatch: Bool

        init(isEveryone: Bool, memberIds: [String], usedLooseNameMatch: Bool = false) {
            self.isEveryone = isEveryone
            self.memberIds = memberIds
            self.usedLooseNameMatch = usedLooseNameMatch
        }

        static let none = MentionScan(isEveryone: false, memberIds: [])
    }

    /// Validation failures for the structured A2A group-message tool. Kept in
    /// this pure layer so permission and addressing rules have unit tests and
    /// cannot drift away from the text mention router.
    enum A2AError: Error, Equatable {
        case senderNotInGroup
        case noTargets
        case targetNotInGroup(String)
        case cannotTargetSelf
        case everyoneRequiresOwner
        case messageContainsMentions
    }

    /// Build the canonical transcript line emitted by
    /// `send_agent_message(is_group:group_id:agent_id[]:message:)`.
    ///
    /// The structured target parameters are authoritative. Mentions inside
    /// `message` are rejected so a non-owner cannot smuggle `<@everyone>` (or
    /// an undeclared extra recipient) through the free-text field.
    static func composeA2AMessage(
        message: String,
        targetAgentIds: [String],
        mentionEveryone: Bool,
        senderAgentId: String,
        members: [GroupMember],
        ownerAgentId: String?
    ) -> Result<String, A2AError> {
        guard members.contains(where: { $0.id == senderAgentId }) else {
            return .failure(.senderNotInGroup)
        }

        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyMentions = parseMentions(in: body, members: members)
        guard !body.contains("<@"), !bodyMentions.isEveryone, bodyMentions.memberIds.isEmpty else {
            return .failure(.messageContainsMentions)
        }

        if mentionEveryone {
            guard senderAgentId == ownerAgentId else {
                return .failure(.everyoneRequiresOwner)
            }
            return .success("\(everyoneToken) \(body)")
        }

        let requested = Set(targetAgentIds)
        guard !requested.isEmpty else { return .failure(.noTargets) }
        let memberIds = Set(members.map(\.id))
        if let invalid = targetAgentIds.first(where: { !memberIds.contains($0) }) {
            return .failure(.targetNotInGroup(invalid))
        }
        guard !requested.contains(senderAgentId) else { return .failure(.cannotTargetSelf) }

        // Roster order gives persistence and tests a deterministic canonical
        // line even when a provider emits the ids in a different order.
        let tokens = members
            .map(\.id)
            .filter { requested.contains($0) }
            .map { token(for: $0) }
            .joined(separator: " ")
        return .success("\(tokens) \(body)")
    }

    /// Parse the mentions in one message.
    ///
    /// Two passes, in this order:
    ///
    /// 1. **Tokens** — `<@id>`. Exact, positional, and immune to renames; this
    ///    is what an agent is told to emit and what `encode` writes for the
    ///    user. An id that is not in this room is ignored rather than guessed
    ///    at, so a mention either addresses the right member or nobody.
    /// 2. **Bare names**, over whatever text the tokens did not claim. Purely a
    ///    safety net for a model that wrote `@市场专家` instead of copying the
    ///    token: it cannot change where a correct token routes, only rescue a
    ///    message that would otherwise wake no one. Reported via
    ///    `usedLooseNameMatch`.
    ///
    /// The name pass carries two departures from grok's `hasMentionAt`, both
    /// forced by Chinese:
    ///
    /// - **Trailing boundary is conditional.** grok requires a non-word
    ///   character after the handle, which makes `@ann` miss `@anna`. Applied
    ///   to CJK it also makes `@市场专家你好` miss, because `你` is a letter and
    ///   Chinese does not put a space after a mention. So the trailing boundary
    ///   is required only for handles that are pure ASCII alphanumerics. The
    ///   leading boundary is required always.
    /// - **Longest handle wins**, since without a trailing boundary `@小明`
    ///   would otherwise match inside `@小明明`.
    static func parseMentions(in text: String, members: [GroupMember]) -> MentionScan {
        guard !text.isEmpty, text.contains("@") else { return .none }

        var isEveryone = false
        var matched = Set<String>()
        var usedLooseNameMatch = false

        let chars = Array(text)

        // --- Pass 1: tokens ---
        var claimed = [Bool](repeating: false, count: chars.count)
        let memberIdSet = Set(members.map(\.id))
        for token in tokens(in: text) {
            if let range = Range(token.range, in: text) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                for index in max(0, start)..<min(end, claimed.count) { claimed[index] = true }
            }
            if token.id == everyoneId {
                isEveryone = true
            } else if memberIdSet.contains(token.id) {
                matched.insert(token.id)
            }
            // An id that resolves to nobody in this room is dropped on purpose.
            // Guessing at the nearest member is how a mention silently reaches
            // the wrong agent.
        }

        // --- Pass 2: bare names, over the unclaimed text ---
        let lower = caseFolded(chars)
        var candidates: [(handle: [Character], memberId: String?)] = everyoneHandles
            .map { (Array($0.lowercased()), nil) }
        for member in members where !matched.contains(member.id) {
            for handle in handles(for: member) {
                candidates.append((Array(handle), member.id))
            }
        }
        // Longest first; on a tie an @everyone token wins, so a member literally
        // named "all" cannot shadow addressing the room.
        candidates.sort { lhs, rhs in
            if lhs.handle.count != rhs.handle.count { return lhs.handle.count > rhs.handle.count }
            return (lhs.memberId == nil) && (rhs.memberId != nil)
        }

        for candidate in candidates {
            guard !candidate.handle.isEmpty else { continue }
            if let id = candidate.memberId, matched.contains(id) { continue }
            if candidate.memberId == nil && isEveryone { continue }
            let requireTrailing = isASCIIAlphanumeric(candidate.handle)
            var claimedAny = false
            for range in mentionRanges(in: lower,
                                       handle: candidate.handle,
                                       requireTrailingBoundary: requireTrailing) {
                guard !(range.contains { claimed[$0] }) else { continue }
                for index in range { claimed[index] = true }
                claimedAny = true
            }
            guard claimedAny else { continue }
            usedLooseNameMatch = true
            if let id = candidate.memberId { matched.insert(id) } else { isEveryone = true }
        }

        return MentionScan(
            isEveryone: isEveryone,
            memberIds: members.map(\.id).filter { matched.contains($0) },
            usedLooseNameMatch: usedLooseNameMatch
        )
    }

    /// Every `@handle` span in `chars` that clears the boundary rules.
    private static func mentionRanges(
        in chars: [Character],
        handle: [Character],
        requireTrailingBoundary: Bool
    ) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let end = chars.count - handle.count
        guard end >= 1 else { return ranges }

        for index in 0...(end - 1) where chars[index] == "@" {
            // Leading boundary: `foo@all` is an address, not a mention.
            if index > 0, isWordCharacter(chars[index - 1]) { continue }
            let start = index + 1
            var matches = true
            for offset in 0..<handle.count where chars[start + offset] != handle[offset] {
                matches = false
                break
            }
            guard matches else { continue }
            let tail = start + handle.count
            if requireTrailingBoundary, tail < chars.count, isWordCharacter(chars[tail]) { continue }
            ranges.append(index..<tail)
        }
        return ranges
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isASCIIAlphanumeric(_ handle: [Character]) -> Bool {
        !handle.isEmpty && handle.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // MARK: - Routing

    /// Who should speak, and why.
    public struct Resolution: Equatable, Sendable {
        /// Member ids in roster order. Empty means the room goes quiet.
        public var responderIds: [String]
        public var reason: Reason
        /// Members that used `@所有人` without being the group owner. Their
        /// broadcast was ignored (their named mentions still count). Surfaced
        /// rather than swallowed so the bridge log can explain a quiet room.
        public var downgradedEveryoneBy: [String]
        /// Members that addressed someone by NAME instead of by `<@id>` token.
        /// It worked, but only by the fallback in `parseMentions` — worth a log
        /// line, because the day one of them is renamed it stops working.
        public var usedLooseNamesBy: [String]

        public enum Reason: String, Equatable, Sendable {
            /// Addressed to the whole room by the user or the owner.
            case everyone
            /// Explicitly named.
            case mentioned
            /// A user message with no mention continues with whoever spoke last.
            case lastSpeaker
            /// Nobody has spoken yet, so it goes to the owner.
            case owner
            /// No owner either — the first member takes it.
            case firstMember
            /// Nobody was addressed. The room stays quiet.
            case none
        }

        public init(
            responderIds: [String],
            reason: Reason,
            downgradedEveryoneBy: [String] = [],
            usedLooseNamesBy: [String] = []
        ) {
            self.responderIds = responderIds
            self.reason = reason
            self.downgradedEveryoneBy = downgradedEveryoneBy
            self.usedLooseNamesBy = usedLooseNamesBy
        }

        public static let quiet = Resolution(responderIds: [], reason: .none)
    }

    /// Resolve one round of responders.
    ///
    /// - Parameters:
    ///   - newMessages: what was said since the last time this was called — the
    ///     user's message on round 0, the previous round's member messages
    ///     after that.
    ///   - history: the full transcript, `newMessages` included. Only used for
    ///     the "no mention" fallback.
    ///
    /// The window is the NEW messages, not everything back to the last user
    /// message as in grok. grok can accumulate because its default is broadcast
    /// and its only stop condition is the round cap; here a mention is the sole
    /// wake-up signal, so re-reading an already-answered `@市场专家` every round
    /// would keep re-waking that member until the cap ran out.
    ///
    /// The rules, in order:
    ///
    /// - `@所有人` → everyone. The user may always do this; a member may only
    ///   if it is the group owner. A non-owner's broadcast is downgraded to its
    ///   named mentions (possibly none).
    /// - Named `@` → exactly those members.
    /// - Neither, and the batch contains a **user** message → the member who
    ///   spoke most recently, so plain follow-up questions keep talking to whom
    ///   the user was already talking to. Falls back to the owner, then to the
    ///   first member, when no member has spoken yet.
    /// - Neither, and the batch is only **member** messages → nobody. Agents
    ///   must address each other explicitly; silence ends the exchange.
    ///
    /// A member never answers itself: senders in this batch are always removed.
    public static func resolveResponders(
        members: [GroupMember],
        newMessages: [GroupMessage],
        history: [GroupMessage],
        ownerAgentId: String?
    ) -> Resolution {
        guard !members.isEmpty, !newMessages.isEmpty else { return .quiet }

        var isEveryone = false
        var mentioned = Set<String>()
        var downgraded: [String] = []
        var loose: [String] = []
        var senders = Set<String>()
        var sawUserMessage = false

        for message in newMessages {
            let scan = parseMentions(in: message.text, members: members)
            switch message.speaker {
            case .user:
                sawUserMessage = true
                if scan.isEveryone { isEveryone = true }
            case .member(let senderId):
                senders.insert(senderId)
                // A member writing a bare name is the signal that it is not
                // copying the token; the user's composer is encoded on send, so
                // this only ever fires for an agent.
                if scan.usedLooseNameMatch, !loose.contains(senderId) {
                    loose.append(senderId)
                }
                if scan.isEveryone {
                    if senderId == ownerAgentId {
                        isEveryone = true
                    } else if !downgraded.contains(senderId) {
                        downgraded.append(senderId)
                    }
                }
            }
            mentioned.formUnion(scan.memberIds)
        }
        mentioned.subtract(senders)

        let order = members.map(\.id)

        if isEveryone {
            return Resolution(
                responderIds: order.filter { !senders.contains($0) },
                reason: .everyone,
                downgradedEveryoneBy: downgraded,
                usedLooseNamesBy: loose
            )
        }
        if !mentioned.isEmpty {
            return Resolution(
                responderIds: order.filter { mentioned.contains($0) },
                reason: .mentioned,
                downgradedEveryoneBy: downgraded,
                usedLooseNamesBy: loose
            )
        }
        guard sawUserMessage else {
            return Resolution(responderIds: [], reason: .none,
                              downgradedEveryoneBy: downgraded, usedLooseNamesBy: loose)
        }

        // Unaddressed user message: continue with whoever spoke last.
        let priorCount = max(0, history.count - newMessages.count)
        let prior = history.prefix(priorCount)
        if let lastSpeaker = prior.reversed().compactMap({ $0.speaker.memberId }).first,
           order.contains(lastSpeaker) {
            return Resolution(
                responderIds: [lastSpeaker],
                reason: .lastSpeaker,
                downgradedEveryoneBy: downgraded,
                usedLooseNamesBy: loose
            )
        }
        if let owner = ownerAgentId, order.contains(owner) {
            return Resolution(responderIds: [owner], reason: .owner,
                              downgradedEveryoneBy: downgraded, usedLooseNamesBy: loose)
        }
        return Resolution(
            responderIds: [order[0]],
            reason: .firstMember,
            downgradedEveryoneBy: downgraded,
            usedLooseNamesBy: loose
        )
    }

    // MARK: - Turn taking

    /// Round N starts with member N. One line, and it removes the first-mover
    /// bias that would otherwise make the same agent set the frame every time
    /// (grok's `orderRoundSpeakers`).
    public static func orderRoundSpeakers<T>(_ ids: [T], round: Int) -> [T] {
        guard !ids.isEmpty else { return [] }
        let offset = ((round % ids.count) + ids.count) % ids.count
        return Array(ids[offset...] + ids[..<offset])
    }

    /// What a member has not seen yet: everything after the last thing it said.
    /// A member that has never spoken gets the whole transcript
    /// (grok's `messagesSinceMemberLastSpoke`).
    public static func messagesSinceMemberLastSpoke(
        _ history: [GroupMessage],
        memberId: String
    ) -> [GroupMessage] {
        guard let index = history.lastIndex(where: { $0.speaker.memberId == memberId }) else {
            return history
        }
        return Array(history[(index + 1)...])
    }

    // MARK: - The pass protocol

    /// Explicit silence. A member with nothing to add says so, and the room
    /// notices — this is what lets a conversation end because it is over rather
    /// than because a counter ran out.
    public static func isPass(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let stripped = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "()（）。.。 "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["pass", "略过", "跳过", "无", "不发言"].contains(stripped)
    }

    /// True while a partial stream could still turn out to be a pass.
    ///
    /// Used by the streaming UI: rendering a bubble the instant the first token
    /// arrives makes every passing member flash into the transcript and vanish.
    /// (grok's `isPotentialPassPrefix`.)
    static func isPotentialPassPrefix(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if isPass(trimmed) { return true }
        let stripped = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "()（）"))
            .lowercased()
        guard !stripped.isEmpty else { return true }
        return ["pass", "略过", "跳过", "不发言"].contains { $0.hasPrefix(stripped) }
    }
}
