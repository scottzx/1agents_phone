import Foundation

public enum NativeCapabilityAvailability: String, Codable, Sendable, Equatable {
    case available
    case unavailable
    case differentBehavior
    case requiresPermission
}

public struct NativeCapabilityDescriptor: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let availability: NativeCapabilityAvailability
    public let detail: String

    public init(id: String, availability: NativeCapabilityAvailability, detail: String) {
        self.id = id
        self.availability = availability
        self.detail = detail
    }
}

/// The GUI-hosted native surface advertised by the desktop Runtime. Unsupported
/// iOS-only capabilities remain explicit instead of being hallucinated into
/// the Agent prompt or failing after a model has already selected them.
public enum NativeToolCatalog {
    public static let capabilities: [NativeCapabilityDescriptor] = [
        .init(id: "system_open", availability: .available, detail: "Open a URL or file with the user's default macOS application."),
        .init(id: "clipboard_read", availability: .available, detail: "Read plain text from the macOS pasteboard."),
        .init(id: "clipboard_write", availability: .available, detail: "Replace plain text on the macOS pasteboard."),
        .init(id: "notification_post", availability: .requiresPermission, detail: "Post a local macOS notification after system authorization."),
        .init(id: "calendar", availability: .requiresPermission, detail: "List and create Calendar events through the visible macOS app."),
        .init(id: "contacts", availability: .requiresPermission, detail: "Search Contacts through the visible macOS app; contacts are never modified."),
        .init(id: "reminders", availability: .requiresPermission, detail: "List and create Reminders through the visible macOS app."),
        .init(id: "photos", availability: .unavailable, detail: "Photos is not exposed by the desktop Runtime in this build."),
        .init(id: "health", availability: .unavailable, detail: "HealthKit is unavailable on macOS Minis."),
        .init(id: "nfc", availability: .unavailable, detail: "NFC is unavailable on macOS Minis.")
    ]

    public static let definitions: [RuntimeToolDefinition] = [
        RuntimeToolDefinition(
            name: "system_open",
            description: "Open a URL or workspace file in its default macOS app. This is executed by the visible Minis app.",
            parameters: schema(properties: ["target": stringProperty("URL or absolute file path to open.")], required: ["target"])
        ),
        RuntimeToolDefinition(
            name: "clipboard_read",
            description: "Read plain text currently on the macOS clipboard.",
            parameters: schema(properties: [:], required: [])
        ),
        RuntimeToolDefinition(
            name: "clipboard_write",
            description: "Replace the macOS clipboard with plain text.",
            parameters: schema(properties: ["text": stringProperty("Text to place on the clipboard.")], required: ["text"])
        ),
        RuntimeToolDefinition(
            name: "notification_post",
            description: "Post a local macOS notification. The user may need to grant notification permission.",
            parameters: schema(properties: [
                "title": stringProperty("Notification title."),
                "body": stringProperty("Notification body.")
            ], required: ["title", "body"])
        ),
        RuntimeToolDefinition(
            name: "calendar_list",
            description: "List macOS Calendar events in an ISO-8601 time range. Calendar permission is requested by the visible Minis app.",
            parameters: schema(properties: [
                "start": stringProperty("Inclusive ISO-8601 start. Defaults to the start of today."),
                "end": stringProperty("Exclusive ISO-8601 end. Defaults to seven days after start."),
                "limit": integerProperty("Maximum events to return, from 1 through 200.")
            ], required: [])
        ),
        RuntimeToolDefinition(
            name: "calendar_create",
            description: "Create an event in the user's default macOS Calendar after Calendar permission is granted.",
            parameters: schema(properties: [
                "title": stringProperty("Event title."),
                "start": stringProperty("ISO-8601 event start."),
                "end": stringProperty("ISO-8601 event end, later than start."),
                "notes": stringProperty("Optional event notes."),
                "allDay": boolProperty("Whether the event is all-day.")
            ], required: ["title", "start", "end"])
        ),
        RuntimeToolDefinition(
            name: "contacts_search",
            description: "Search names, organizations, email addresses and phone numbers in macOS Contacts. This tool is read-only.",
            parameters: schema(properties: [
                "query": stringProperty("Name or organization to search for."),
                "limit": integerProperty("Maximum contacts to return, from 1 through 100.")
            ], required: ["query"])
        ),
        RuntimeToolDefinition(
            name: "reminders_list",
            description: "List macOS Reminders. Reminder permission is requested by the visible Minis app.",
            parameters: schema(properties: [
                "completed": boolProperty("When provided, return only completed or incomplete reminders."),
                "limit": integerProperty("Maximum reminders to return, from 1 through 200.")
            ], required: [])
        ),
        RuntimeToolDefinition(
            name: "reminders_create",
            description: "Create a reminder in the user's default macOS Reminders list.",
            parameters: schema(properties: [
                "title": stringProperty("Reminder title."),
                "due": stringProperty("Optional ISO-8601 due date."),
                "notes": stringProperty("Optional reminder notes.")
            ], required: ["title"])
        )
    ]

    public static func contains(_ name: String) -> Bool {
        definitions.contains(where: { $0.name == name })
    }

    /// Native operations with visible or persistent side effects always need
    /// an explicit, one-shot decision from the GUI host. Read-only queries do
    /// not, and TCC authorization remains a separate system-level boundary.
    public static func requiresExplicitApproval(_ name: String) -> Bool {
        switch name {
        case "system_open", "clipboard_write", "notification_post", "calendar_create", "reminders_create": true
        default: false
        }
    }

    public static func approvalSummary(name: String, arguments: JSONValue) -> String {
        let object: [String: JSONValue]
        if case .object(let value) = arguments { object = value } else { object = [:] }
        func string(_ key: String) -> String? {
            guard case .string(let value)? = object[key], !value.isEmpty else { return nil }
            return value
        }
        switch name {
        case "system_open": return "Open \(string("target") ?? "the requested URL or file")"
        case "clipboard_write": return "Replace the clipboard with model-provided text"
        case "notification_post": return "Post notification: \(string("title") ?? "Untitled")"
        case "calendar_create":
            return "Create calendar event: \(string("title") ?? "Untitled")\nStart: \(string("start") ?? "unspecified")\nEnd: \(string("end") ?? "unspecified")"
        case "reminders_create":
            return "Create reminder: \(string("title") ?? "Untitled")\nDue: \(string("due") ?? "unspecified")"
        default: return "Run native tool \(name)"
        }
    }

    public static func arguments(for call: ProviderToolCall) throws -> JSONValue {
        guard let data = call.arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value else {
            throw RuntimeToolError.invalidArguments("\(call.name) expects a JSON object")
        }
        return value
    }

    public static func resultString(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder.runtime.encode(value), as: UTF8.self)
    }

    private static func stringProperty(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerProperty(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func boolProperty(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func schema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false)
        ])
    }
}
