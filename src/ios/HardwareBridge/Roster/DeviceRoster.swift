import Foundation

// The identity payloads the phone pushes down to agent_link hardware.
//
// The device needs to answer "who is in this conversation and what do they look
// like" before it can render anything richer than a line of text — the CuiCan
// board's 240x240 round LCD draws a name and a colored node per speaker.
//
// Kept deliberately transport-free: DeviceRosterService produces these, and
// AgentLinkCodec/HardwareBLECentral decide whether they travel as a 0x33
// IoActuate write or as fragmented 0x37 frames. The same structs also serialize
// unchanged for the DEBUG JSON-RPC path, which is how this is testable with no
// firmware attached.
//
// Wire keys are single letters on the member records because a roster shares
// the ~470-byte GATT budget with everything else; the conversation and state
// payloads use readable keys because they are small and are the shapes the
// hardware team is building against (Docs/DEMO_PRD.md §5).

/// Endpoint ids the board registers with `agent_link_register_io` as
/// `AGENT_IO_OUT`. Adding one costs a `register_io` call on the board and
/// nothing in the agent_link SDK — 0x33 routes by id.
enum DeviceEndpoint {
    /// Plain text on the existing screen endpoint. Predates this file.
    static let screen = "screen0"
    /// Roster JSON. Route A only: a roster that outgrows one GATT write must
    /// use the fragmented 0x37 command instead.
    static let roster = "roster0"
    /// One chat message with its sender, so the device can show whose turn it
    /// is without the phone having to re-send the roster each time.
    static let chat = "chat0"
    /// Roundtable state machine transitions (DEMO_PRD.md §5).
    static let state = "state0"
}

/// What a roster member is. `self` exists so a group roster can mark the
/// device holder's own row; the device does not draw an avatar for it today.
enum DeviceParticipantKind: String, Codable, Equatable {
    case agent
    case user
}

struct DeviceParticipant: Equatable, Codable {
    let id: String
    let kind: DeviceParticipantKind
    let name: String
    /// One or two emoji. AgentProfile deliberately stores an emoji rather than
    /// an image, which is why this pushes down in a few dozen bytes and needs
    /// no bitmap pipeline or L2CAP blob transfer.
    let emoji: String
    /// `#RRGGBB`. The board tints the speaker's node with this.
    let accentColor: String
    /// Short role label, e.g. "总管" / "市场专家". May be empty.
    let title: String

    enum CodingKeys: String, CodingKey {
        case id
        case kind = "k"
        case name = "n"
        case emoji = "e"
        case accentColor = "c"
        case title = "t"
    }
}

/// Today every hardware link is one `direct` conversation with one agent. The
/// `group` case is the whole reason this type exists now rather than later:
/// when the roundtable lands, the same snapshot carries several members and the
/// firmware side needs no change.
enum DeviceConversationKind: String, Codable, Equatable {
    case direct
    case group
}

struct DeviceConversation: Equatable, Codable {
    let id: String
    let kind: DeviceConversationKind
    let title: String
}

/// One row of the device's chat list.
///
/// `DeviceConversation` describes the *bound* conversation — the one `chat0`
/// and `state0` are scoped to. This describes a conversation the device may
/// *switch to*, which is why it carries an avatar and a member list: the board
/// draws the whole list on connect, before any turn has run, and cannot ask
/// the phone what a row looks like.
///
/// `memberIds` is index-significant. It is `GroupProfile.memberIds` verbatim,
/// so the slot a member occupies here is the same slot
/// `DeviceRoundtableState.speaking(slot:isOwner:)` lights up.
struct DeviceConversationEntry: Equatable, Codable {
    let id: String
    let kind: DeviceConversationKind
    let title: String
    /// One or two emoji. Group avatar or the agent's own.
    let emoji: String
    /// `#RRGGBB` for the row's border and avatar chip.
    let accentColor: String
    /// The member allowed to `@所有人`, drawn as the centre node. Nil for a
    /// direct conversation and for a group with no owner.
    let ownerId: String?
    /// Participant ids, resolved against the snapshot's `members`.
    let memberIds: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case emoji = "e"
        case accentColor = "c"
        case ownerId = "own"
        case memberIds = "m"
    }
}

struct DeviceRosterSnapshot: Equatable, Codable {
    /// Bumped on every change. The device caches by rev so a reconnect that
    /// replays an identical roster costs no redraw.
    let rev: UInt32
    /// The conversation the device's next turn belongs to. Still first, and
    /// still mandatory, because `chat0` and `state0` are scoped to it — and
    /// because firmware that predates `conversations` reads only this.
    let conversation: DeviceConversation
    /// Every agent referenced anywhere in `conversations`, deduplicated. The
    /// entries hold ids only, so a member shared by four groups costs its name,
    /// emoji and color once.
    let members: [DeviceParticipant]
    /// The device's whole chat list — groups and one-to-one agents together, in
    /// draw order. Empty means "no catalog", which is what a single-session
    /// bind produces and what the device falls back to handling on its own.
    let conversations: [DeviceConversationEntry]

    enum CodingKeys: String, CodingKey {
        case rev
        case conversation = "conv"
        case members
        case conversations = "convs"
    }

    init(
        rev: UInt32,
        conversation: DeviceConversation,
        members: [DeviceParticipant],
        conversations: [DeviceConversationEntry] = []
    ) {
        self.rev = rev
        self.conversation = conversation
        self.members = members
        self.conversations = conversations
    }

    // Hand-written so an absent `convs` decodes as empty rather than throwing,
    // and so an empty one is left off the wire entirely — a bound-session push
    // stays byte-identical to what it was before the catalog existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rev = try container.decode(UInt32.self, forKey: .rev)
        conversation = try container.decode(DeviceConversation.self, forKey: .conversation)
        members = try container.decode([DeviceParticipant].self, forKey: .members)
        conversations = try container.decodeIfPresent(
            [DeviceConversationEntry].self, forKey: .conversations
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rev, forKey: .rev)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(members, forKey: .members)
        if !conversations.isEmpty {
            try container.encode(conversations, forKey: .conversations)
        }
    }

    /// Sender lookup the chat payload relies on.
    func member(_ id: String) -> DeviceParticipant? {
        members.first { $0.id == id }
    }

    /// Resolves what the device reported it opened. The board echoes back the
    /// entry id it was given, so this is an exact match, not a heuristic.
    func entry(_ id: String) -> DeviceConversationEntry? {
        conversations.first { $0.id == id }
    }

    /// Whether the device would draw exactly what it is already drawing.
    ///
    /// `rev` and the bound conversation are excluded on purpose: with a catalog
    /// present the board builds its chat list from `convs` alone and never
    /// reads `conv`, so a selection — which the device itself initiated — would
    /// otherwise cost a multi-fragment resend of the entire roster, in the same
    /// window as the audio round trip that the board has the least RAM for.
    ///
    /// Without a catalog the board *does* build its list from `conv`, so there
    /// a binding change is a real redraw and still has to go down.
    func rendersSameAs(_ other: DeviceRosterSnapshot?) -> Bool {
        guard let other,
              members == other.members,
              conversations == other.conversations else { return false }
        return !conversations.isEmpty || conversation == other.conversation
    }
}

/// One message pushed to the device with its sender attached.
///
/// This is the forward-compatibility hinge. `screen0` carries bare text, so a
/// group conversation would have no way to say who is speaking and the firmware
/// would need re-plumbing when the roundtable ships. With `from` present from
/// the start, today's single-agent case is just a roster of one.
struct DeviceChatMessage: Equatable, Codable {
    let conversationId: String
    /// Participant id, resolved against the last roster the device cached.
    let from: String
    /// Monotonic per conversation, so the device can spot a dropped frame.
    let sequence: UInt32
    let text: String

    enum CodingKeys: String, CodingKey {
        case conversationId = "conv"
        case from
        case sequence = "seq"
        case text
    }
}

/// The eight round-screen states from DEMO_PRD.md §5. Raw values are the
/// document's strings verbatim — work package B is building the LVGL state
/// machine against exactly these, so they are a contract, not a naming choice.
enum DeviceRoundtableState: String, Codable, Equatable, CaseIterable {
    case idle
    case listening
    case thinking
    case marketSpeaking = "market_speaking"
    case productSpeaking = "product_speaking"
    case techSpeaking = "tech_speaking"
    case moderatorSpeaking = "moderator_speaking"
    case done

    /// Which state lights up for the member in roster position `slot`.
    ///
    /// The raw values above are a firmware contract, so a general group cannot
    /// invent a `member4_speaking`: the 240x240 round screen draws exactly
    /// three outer nodes plus a centre, and work package B is building against
    /// those names. So a group is projected onto the same four positions — the
    /// owner is the centre, the first three other members are the outer nodes —
    /// and anyone beyond that shows as `thinking`, which reads on the device as
    /// "the room is working" rather than as a wrong name lighting up.
    static func speaking(slot: Int, isOwner: Bool) -> DeviceRoundtableState {
        if isOwner { return .moderatorSpeaking }
        switch slot {
        case 0: return .marketSpeaking
        case 1: return .productSpeaking
        case 2: return .techSpeaking
        default: return .thinking
        }
    }
}

/// The state event shape from DEMO_PRD.md §5, including its literal
/// `"type":"state"` discriminator.
struct DeviceStateEvent: Equatable, Codable {
    let state: DeviceRoundtableState
    /// Display name of whoever the state refers to, e.g. "市场专家".
    let name: String
    /// One short line the screen may show under the node. The board is
    /// explicitly not asked to lay out long text (PRD §11).
    let textBrief: String

    private let type = "state"

    enum CodingKeys: String, CodingKey {
        case type
        case state
        case name
        case textBrief = "text_brief"
    }

    init(state: DeviceRoundtableState, name: String, textBrief: String = "") {
        self.state = state
        self.name = name
        self.textBrief = textBrief
    }

    // `type` is a constant discriminator, so it encodes but never decodes.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(DeviceRoundtableState.self, forKey: .state)
        name = try container.decode(String.self, forKey: .name)
        textBrief = try container.decodeIfPresent(String.self, forKey: .textBrief) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(state, forKey: .state)
        try container.encode(name, forKey: .name)
        try container.encode(textBrief, forKey: .textBrief)
    }
}

enum DeviceRosterJSON {
    /// `.sortedKeys` keeps output byte-stable across runs, which is what makes
    /// fragment-boundary tests meaningful and lets the device dedupe by rev.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
