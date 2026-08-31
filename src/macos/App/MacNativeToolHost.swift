import AppKit
import Contacts
import EventKit
import Foundation
import MinisDesktopCore
import UserNotifications

/// Executes the small, explicitly brokered set of macOS-native tools. The
/// runtime never receives direct access to AppKit; it emits an invocation and
/// the app returns a serializable result through `native.resolve`.
@MainActor
final class MacNativeToolHost {
    enum Outcome {
        case success(JSONValue)
        case failure(String)
    }

    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()

    func invoke(name: String, arguments: JSONValue) async -> Outcome {
        do {
            switch name {
            case "system_open":
                return try openSystemURL(arguments)
            case "clipboard_read":
                return readClipboard()
            case "clipboard_write":
                return try writeClipboard(arguments)
            case "notification_post":
                return try await postNotification(arguments)
            case "calendar_list":
                return try await listCalendarEvents(arguments)
            case "calendar_create":
                return try await createCalendarEvent(arguments)
            case "contacts_search":
                return try await searchContacts(arguments)
            case "reminders_list":
                return try await listReminders(arguments)
            case "reminders_create":
                return try await createReminder(arguments)
            default:
                return .failure("Unsupported native tool: \(name)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func openSystemURL(_ arguments: JSONValue) throws -> Outcome {
        let object = try object(arguments)
        let explicitTarget = nativeString(object, "target")
        let target: URL
        if let rawURL = nativeString(object, "url") ?? explicitTarget,
           let url = URL(string: rawURL), url.scheme != nil {
            target = url
        } else if let path = nativeString(object, "path") ?? explicitTarget, !path.isEmpty {
            target = URL(fileURLWithPath: path)
        } else {
            throw NativeToolError.invalidArgument("system_open requires a URL or path.")
        }
        guard NSWorkspace.shared.open(target) else {
            throw NativeToolError.operationFailed("macOS could not open \(target.absoluteString).")
        }
        return .success(.object(["opened": .bool(true), "url": .string(target.absoluteString)]))
    }

    private func readClipboard() -> Outcome {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        return .success(.object(["text": .string(text)]))
    }

    private func writeClipboard(_ arguments: JSONValue) throws -> Outcome {
        let object = try object(arguments)
        guard let text = nativeString(object, "text") ?? nativeString(object, "value") else {
            throw NativeToolError.invalidArgument("clipboard_write requires text.")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw NativeToolError.operationFailed("macOS could not write to the clipboard.")
        }
        return .success(.object(["written": .bool(true), "length": .int(text.count)]))
    }

    private func postNotification(_ arguments: JSONValue) async throws -> Outcome {
        let object = try object(arguments)
        guard let title = nativeString(object, "title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw NativeToolError.invalidArgument("notification_post requires a title.")
        }
        let center = UNUserNotificationCenter.current()
        try await ensureNotificationAuthorization(center)

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = nativeString(object, "subtitle") ?? ""
        content.body = nativeString(object, "body") ?? nativeString(object, "text") ?? ""
        if object.bool("sound") != false { content.sound = .default }

        let identifier = UUID().uuidString
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        return .success(.object(["posted": .bool(true), "notificationId": .string(identifier)]))
    }

    private func listCalendarEvents(_ arguments: JSONValue) async throws -> Outcome {
        try await ensureEventAuthorization(.event)
        let values = try object(arguments)
        let calendar = Calendar.current
        let start = try nativeDate(values, "start") ?? calendar.startOfDay(for: Date())
        let end = try nativeDate(values, "end") ?? calendar.date(byAdding: .day, value: 7, to: start)!
        guard end > start else { throw NativeToolError.invalidArgument("calendar_list end must be later than start.") }
        let limit = nativeLimit(values, default: 50, maximum: 200)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                JSONValue.object([
                    "id": .string(event.eventIdentifier ?? event.calendarItemIdentifier),
                    "title": .string(event.title ?? ""),
                    "start": .string(nativeISO8601(event.startDate)),
                    "end": .string(nativeISO8601(event.endDate)),
                    "allDay": .bool(event.isAllDay),
                    "calendar": .string(event.calendar.title),
                    "location": event.location.map(JSONValue.string) ?? .null,
                    "notes": event.notes.map(JSONValue.string) ?? .null
                ])
            }
        return .success(.object([
            "events": .array(Array(events)),
            "start": .string(nativeISO8601(start)),
            "end": .string(nativeISO8601(end))
        ]))
    }

    private func createCalendarEvent(_ arguments: JSONValue) async throws -> Outcome {
        try await ensureEventAuthorization(.event)
        let values = try object(arguments)
        guard let title = nativeString(values, "title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw NativeToolError.invalidArgument("calendar_create requires a title.")
        }
        guard let start = try nativeDate(values, "start"), let end = try nativeDate(values, "end"), end > start else {
            throw NativeToolError.invalidArgument("calendar_create requires valid start/end ISO-8601 dates and end must be later.")
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw NativeToolError.operationFailed("No writable default Calendar is available.")
        }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = values.bool("allDay") ?? false
        event.notes = nativeString(values, "notes")
        event.calendar = calendar
        try eventStore.save(event, span: .thisEvent, commit: true)
        return .success(.object([
            "created": .bool(true),
            "id": .string(event.eventIdentifier ?? event.calendarItemIdentifier),
            "calendar": .string(calendar.title)
        ]))
    }

    private func searchContacts(_ arguments: JSONValue) async throws -> Outcome {
        try await ensureContactsAuthorization()
        let values = try object(arguments)
        guard let query = nativeString(values, "query")?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw NativeToolError.invalidArgument("contacts_search requires a query.")
        }
        let limit = nativeLimit(values, default: 25, maximum: 100)
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContacts(matchingName: query)
        request.unifyResults = true
        var matches: [JSONValue] = []
        try contactStore.enumerateContacts(with: request) { contact, stop in
            matches.append(.object([
                "id": .string(contact.identifier),
                "name": .string(CNContactFormatter.string(from: contact, style: .fullName) ?? ""),
                "organization": .string(contact.organizationName),
                "emails": .array(contact.emailAddresses.map { .string(String($0.value)) }),
                "phones": .array(contact.phoneNumbers.map { .string($0.value.stringValue) })
            ]))
            if matches.count >= limit { stop.pointee = true }
        }
        return .success(.object(["contacts": .array(matches), "query": .string(query)]))
    }

    private func listReminders(_ arguments: JSONValue) async throws -> Outcome {
        try await ensureEventAuthorization(.reminder)
        let values = try object(arguments)
        let reminders = await fetchReminders(matching: eventStore.predicateForReminders(in: nil))
        let completed = values.bool("completed")
        let limit = nativeLimit(values, default: 50, maximum: 200)
        let output = reminders
            .filter { completed == nil || $0.completed == completed }
            .sorted { ($0.due ?? "\u{10ffff}") < ($1.due ?? "\u{10ffff}") }
            .prefix(limit)
            .map { reminder in
                JSONValue.object([
                    "id": .string(reminder.id),
                    "title": .string(reminder.title),
                    "completed": .bool(reminder.completed),
                    "due": reminder.due.map(JSONValue.string) ?? .null,
                    "list": .string(reminder.list),
                    "notes": reminder.notes.map(JSONValue.string) ?? .null
                ])
            }
        return .success(.object(["reminders": .array(Array(output))]))
    }

    private func createReminder(_ arguments: JSONValue) async throws -> Outcome {
        try await ensureEventAuthorization(.reminder)
        let values = try object(arguments)
        guard let title = nativeString(values, "title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw NativeToolError.invalidArgument("reminders_create requires a title.")
        }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw NativeToolError.operationFailed("No writable default Reminders list is available.")
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = nativeString(values, "notes")
        reminder.calendar = calendar
        if let due = try nativeDate(values, "due") {
            reminder.dueDateComponents = Calendar.current.dateComponents(in: .current, from: due)
        }
        try eventStore.save(reminder, commit: true)
        return .success(.object([
            "created": .bool(true),
            "id": .string(reminder.calendarItemIdentifier),
            "list": .string(calendar.title)
        ]))
    }

    private func ensureEventAuthorization(_ entity: EKEntityType) async throws {
        let status = EKEventStore.authorizationStatus(for: entity)
        if status == .fullAccess { return }
        if status == .notDetermined {
            let granted: Bool
            switch entity {
            case .event: granted = try await eventStore.requestFullAccessToEvents()
            case .reminder: granted = try await eventStore.requestFullAccessToReminders()
            @unknown default: granted = false
            }
            if granted { return }
        }
        let label = entity == .event ? "Calendar" : "Reminders"
        throw NativeToolError.permissionDenied("\(label) access is disabled for Minis in System Settings.")
    }

    private func ensureContactsAuthorization() async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return
        case .notDetermined:
            guard try await contactStore.requestAccess(for: .contacts) else {
                throw NativeToolError.permissionDenied("Contacts permission was not granted.")
            }
        default:
            throw NativeToolError.permissionDenied("Contacts access is disabled for Minis in System Settings.")
        }
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [ReminderSnapshot] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).map { reminder in
                    ReminderSnapshot(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title,
                        completed: reminder.isCompleted,
                        due: reminder.dueDateComponents?.date.map(nativeISO8601),
                        list: reminder.calendar.title,
                        notes: reminder.notes
                    )
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    private func ensureNotificationAuthorization(_ center: UNUserNotificationCenter) async throws {
        switch await notificationAuthorizationStatus(center) {
        case .authorized, .provisional, .ephemeral:
            return
        case .notDetermined:
            guard try await center.requestAuthorization(options: [.alert, .badge, .sound]) else {
                throw NativeToolError.permissionDenied("Notification permission was not granted.")
            }
        case .denied:
            throw NativeToolError.permissionDenied("Notifications are disabled for Minis in System Settings.")
        @unknown default:
            throw NativeToolError.permissionDenied("Notification permission is unavailable.")
        }
    }

    private func notificationAuthorizationStatus(_ center: UNUserNotificationCenter) async -> UNAuthorizationStatus {
        let rawValue: Int = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus.rawValue)
            }
        }
        return UNAuthorizationStatus(rawValue: rawValue) ?? .denied
    }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let object) = value else {
            throw NativeToolError.invalidArgument("Native tool arguments must be an object.")
        }
        return object
    }

    private func nativeDate(_ object: [String: JSONValue], _ key: String) throws -> Date? {
        guard let raw = nativeString(object, key), !raw.isEmpty else { return nil }
        guard let date = nativeISO8601Date(raw) else {
            throw NativeToolError.invalidArgument("\(key) must be an ISO-8601 date.")
        }
        return date
    }

    private func nativeLimit(_ object: [String: JSONValue], default defaultValue: Int, maximum: Int) -> Int {
        min(max(object.int("limit") ?? defaultValue, 1), maximum)
    }
}

private struct ReminderSnapshot: Sendable {
    let id: String
    let title: String
    let completed: Bool
    let due: String?
    let list: String
    let notes: String?
}

private enum NativeToolError: LocalizedError {
    case invalidArgument(String)
    case permissionDenied(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message), .permissionDenied(let message), .operationFailed(let message):
            return message
        }
    }
}

private func nativeString(_ object: [String: JSONValue], _ key: String) -> String? {
    if case .string(let value)? = object[key] { value } else { nil }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func bool(_ key: String) -> Bool? {
        if case .bool(let value)? = self[key] { value } else { nil }
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case .int(let value): value
        case .double(let value): Int(value)
        default: nil
        }
    }
}

private func nativeISO8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func nativeISO8601Date(_ string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}
