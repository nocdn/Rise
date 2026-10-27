import EventKit
import Foundation

/// A short undo window for an item Rise has just saved. Failed writes leave the current action
/// available; each successful undo or redo gives the person another ten seconds to reverse it.
@MainActor public final class SelectionItemUndo {
    public static let duration: TimeInterval = 10
    public private(set) var isUndone = false
    private var deadline: TimeInterval
    private let now: () -> TimeInterval
    private let remove: () throws -> Void
    private let restore: () throws -> Void
    public var remaining: TimeInterval { max(0, deadline-now()) }
    public var canUndo: Bool { !isUndone && remaining > 0 }
    public var canRedo: Bool { isUndone && remaining > 0 }

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                remove: @escaping () throws -> Void, restore: @escaping () throws -> Void) {
        self.now = now; self.remove = remove; self.restore = restore
        deadline = now()+Self.duration
    }
    @discardableResult public func undo() throws -> Bool {
        guard canUndo else { return false }
        try remove()
        isUndone = true; deadline = now()+Self.duration
        return true
    }
    @discardableResult public func redo() throws -> Bool {
        guard canRedo else { return false }
        try restore()
        isUndone = false; deadline = now()+Self.duration
        return true
    }
}

/// Keeps the saved identity separate from the draft: EventKit invalidates deleted objects, so
/// redo creates a fresh one and the link must then use its new identifier.
@MainActor public final class SelectionItemReceipt {
    public private(set) var item: EKCalendarItem
    public let store: EKEventStore
    private let draft: SelectionItemDraft
    public var isEvent: Bool { item is EKEvent }
    public var appName: String { isEvent ? "Calendar" : "Reminders" }
    public var allowsUndo: Bool { EKEventStore.authorizationStatus(for: isEvent ? .event : .reminder) == .fullAccess }
    public lazy var undo = SelectionItemUndo(remove: { [unowned self] in try remove() },
                                            restore: { [unowned self] in try restore() })

    public init(item: EKCalendarItem, store: EKEventStore) {
        self.item = item; self.store = store; draft = SelectionItemDraft(item)
        // Start the window at save, rather than when the first shortcut is pressed.
        _ = undo
    }
    private func remove() throws {
        // Re-fetch so a database refresh doesn't make us delete an invalidated object. Never
        // search by title or date: a different item with the same title must not be removed.
        let current = store.calendarItem(withIdentifier: item.calendarItemIdentifier) ?? item
        if let event = current as? EKEvent {
            // If Repeat was set in the system editor, the entire new series belongs to this save.
            try store.remove(event, span: event.hasRecurrenceRules ? .futureEvents : .thisEvent, commit: true)
        }
        else if let reminder = current as? EKReminder { try store.remove(reminder, commit: true) }
    }
    private func restore() throws {
        let restored = draft.makeItem(in: store)
        if let event = restored as? EKEvent { try store.save(event, span: .thisEvent, commit: true) }
        else if let reminder = restored as? EKReminder { try store.save(reminder, commit: true) }
        item = restored
    }
    public var destinationURL: URL? {
        if let event = item as? EKEvent {
            return Self.eventURL(identifier: event.calendarItemIdentifier, start: event.startDate)
        }
        return Self.reminderURL(identifier: item.calendarItemIdentifier)
    }
    public static func eventURL(identifier: String, start: Date) -> URL? {
        guard !identifier.isEmpty else { return nil }
        #if os(iOS)
        var url = URLComponents(string: "calshow://")!
        url.queryItems = [URLQueryItem(name: "eventid", value: identifier)]
        return url.url
        #else
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var url = URLComponents()
        url.scheme = "ical"; url.host = "ekevent"
        // Calendar expects the occurrence's date and the local item ID, not the server's UID.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let id = identifier.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        url.percentEncodedPath = "/\(formatter.string(from: start))/\(id)"
        url.queryItems = [URLQueryItem(name: "method", value: "show"), URLQueryItem(name: "options", value: "more")]
        return url.url
        #endif
    }
    public static func reminderURL(identifier: String) -> URL? {
        let raw = identifier.components(separatedBy: "/").last ?? identifier
        guard let id = UUID(uuidString: raw) else { return nil }
        return URL(string: "x-apple-reminderkit://REMCDReminder/\(id.uuidString)")
    }
}

/// Values captured before removal, including edits made in Calendar's iOS editor.
@MainActor struct SelectionItemDraft {
    private let make: (EKEventStore) -> EKCalendarItem
    init(_ item: EKCalendarItem) {
        let title = item.title, location = item.location, notes = item.notes, url = item.url
        let calendar = item.calendar, calendarID = item.calendar?.calendarIdentifier
        let zone = item.timeZone
        let alarms = item.alarms?.map(SelectionAlarmDraft.init)
        let rules = item.recurrenceRules?.map(SelectionRecurrenceDraft.init)
        let specific: (EKEventStore) -> EKCalendarItem
        if let event = item as? EKEvent {
            let start = event.startDate, end = event.endDate, allDay = event.isAllDay
            let availability = event.availability
            specific = { store in
                let event = EKEvent(eventStore: store)
                event.startDate = start; event.endDate = end; event.isAllDay = allDay; event.availability = availability
                return event
            }
        } else {
            let reminder = item as! EKReminder
            let due = reminder.dueDateComponents, start = reminder.startDateComponents, priority = reminder.priority
            specific = { store in
                let reminder = EKReminder(eventStore: store)
                reminder.dueDateComponents = due; reminder.startDateComponents = start; reminder.priority = priority
                return reminder
            }
        }
        make = { store in
            let fresh = specific(store)
            fresh.title = title; fresh.location = location; fresh.notes = notes; fresh.url = url; fresh.timeZone = zone
            fresh.calendar = calendarID.flatMap { store.calendar(withIdentifier: $0) } ?? calendar
            fresh.alarms = alarms?.map { $0.make() }
            fresh.recurrenceRules = rules?.map { $0.make() }
            return fresh
        }
    }
    func makeItem(in store: EKEventStore) -> EKCalendarItem { make(store) }
}

/// EKObject.copy keeps its database relationships. After Undo deletes the original alarm, a
/// copied alarm still points at that deleted row. Capture values and build new objects instead.
private struct SelectionAlarmDraft {
    let make: () -> EKAlarm
    init(_ alarm: EKAlarm) {
        let date = alarm.absoluteDate, offset = alarm.relativeOffset, proximity = alarm.proximity
        let title = alarm.structuredLocation?.title, geo = alarm.structuredLocation?.geoLocation
        let radius = alarm.structuredLocation?.radius
        #if os(macOS)
        let email = alarm.emailAddress, sound = alarm.soundName
        #endif
        make = {
            let fresh = date.map(EKAlarm.init(absoluteDate:)) ?? EKAlarm(relativeOffset: offset)
            fresh.proximity = proximity
            if let title {
                let place = EKStructuredLocation(title: title)
                place.geoLocation = geo; place.radius = radius ?? 0
                fresh.structuredLocation = place
            }
            #if os(macOS)
            if let email { fresh.emailAddress = email }
            else if let sound { fresh.soundName = sound }
            #endif
            return fresh
        }
    }
}

private struct SelectionRecurrenceDraft {
    let make: () -> EKRecurrenceRule
    init(_ rule: EKRecurrenceRule) {
        let frequency = rule.frequency, interval = rule.interval
        let days = rule.daysOfTheWeek?.map { EKRecurrenceDayOfWeek($0.dayOfTheWeek, weekNumber: $0.weekNumber) }
        let monthDays = rule.daysOfTheMonth, months = rule.monthsOfTheYear, weeks = rule.weeksOfTheYear
        let yearDays = rule.daysOfTheYear, positions = rule.setPositions
        let endDate = rule.recurrenceEnd?.endDate, count = rule.recurrenceEnd?.occurrenceCount
        make = {
            let end = endDate.map(EKRecurrenceEnd.init(end:)) ?? count.map(EKRecurrenceEnd.init(occurrenceCount:))
            return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, daysOfTheWeek: days,
                daysOfTheMonth: monthDays, monthsOfTheYear: months, weeksOfTheYear: weeks,
                daysOfTheYear: yearDays, setPositions: positions, end: end)
        }
    }
}
