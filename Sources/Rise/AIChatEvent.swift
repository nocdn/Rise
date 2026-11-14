import AppKit
import EventKit
import RiseCore

/// An event the chat's model made for the user's calendar: shown in the answer as a card whose
/// title, times, place and notes they can edit, and add to Google Calendar, or to the Mac's own
/// Calendar app, as they choose.
struct AIChatEventDraft: Equatable, Sendable {
    enum Calendar: String, Equatable, Sendable, CaseIterable {
        case google, apple
        var title: String { self == .google ? "Google Calendar" : "Apple Calendar" }
    }
    var title: String
    var start: Date
    /// Exclusive: for an all-day event, the start of the day after its last.
    var end: Date
    var isAllDay = false
    /// The zone its times were given in, where that isn't the user's own.
    var timeZone: TimeZone?
    var location = ""
    var notes = ""
    /// The calendar the user asked for, if they named one.
    var calendar: Calendar?

    /// As Rise's other ways of adding an event take it (`SelectionEvents`).
    var selectionEvent: SelectionEvent {
        SelectionEvent(title: title.isEmpty ? "New Event" : title, start: start, end: end, isAllDay: isAllDay, hasEnd: true,
                       timeZone: timeZone, location: location.isEmpty ? nil : location, notes: notes)
    }
    /// "Fri 21 Nov, 15:00 – 16:00", as the right-click menu says it.
    var when: String { SelectionEvents.label(selectionEvent) }
    /// The event as it now reads, edits and all, for the model to see in a follow-up.
    var modelText: String {
        var lines = ["Title: \(title)", "When: \(when)\(timeZone.map { " (\($0.identifier))" } ?? "")"]
        if !location.isEmpty { lines.append("Where: \(location)") }
        if let calendar { lines.append("Calendar: \(calendar.title)") }
        if !notes.isEmpty { lines.append("Notes: \(notes)") }
        return "<event_draft>\n\(lines.joined(separator: "\n"))\n</event_draft>"
    }

    /// From the model's `create_event` call: times as "2026-11-21T15:00" in the user's zone or
    /// `time_zone`, or with an offset, and days as "2026-11-21", which make it all day. With no
    /// end, an hour, or the one day; an all-day end is its last day.
    init(arguments: [String: Any], now: Date = Date()) throws {
        func text(_ key: String) -> String { (arguments[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let zone = TimeZone(identifier: text("time_zone"))
        guard let start = Self.date(text("start"), zone: zone) else {
            throw AIChatToolFailure(message: "Give start as \"2026-11-21T15:00\", or \"2026-11-21\" for a day.")
        }
        let allDay = (arguments["all_day"] as? Bool) ?? start.dayOnly
        var calendar = Foundation.Calendar(identifier: .gregorian); calendar.timeZone = .current
        let begins = allDay ? calendar.startOfDay(for: start.date) : start.date
        var ends: Date
        if let end = Self.date(text("end"), zone: zone) {
            ends = allDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end.date))! : end.date
        } else {
            ends = allDay ? calendar.date(byAdding: .day, value: 1, to: begins)! : begins.addingTimeInterval(3600)
        }
        if ends <= begins { ends = allDay ? calendar.date(byAdding: .day, value: 1, to: begins)! : begins.addingTimeInterval(3600) }
        self.init(title: text("title"), start: begins, end: ends, isAllDay: allDay, timeZone: allDay ? nil : zone,
                  location: text("location"), notes: text("notes"), calendar: Calendar(rawValue: text("calendar").lowercased()))
    }
    init(title: String, start: Date, end: Date, isAllDay: Bool = false, timeZone: TimeZone? = nil, location: String = "", notes: String = "", calendar: Calendar? = nil) {
        self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay; self.timeZone = timeZone
        self.location = location; self.notes = notes; self.calendar = calendar
    }

    /// An ISO 8601 time, with an offset or in `zone` (the user's own without one), or a day.
    static func date(_ text: String, zone: TimeZone?) -> (date: Date, dayOnly: Bool)? {
        guard !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return (date, false) }
        }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = zone ?? .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            format.dateFormat = pattern
            if let date = format.date(from: text) { return (date, false) }
        }
        format.dateFormat = "yyyy-MM-dd"; format.timeZone = .current
        return format.date(from: text).map { ($0, true) }
    }
}

// MARK: The tool

extension AIChatBrowserTools {
    var createEvent: AIChatTool {
        AIChatTool(name: "create_event", description: """
            Shows the user an event as a card in the chat, to add to their calendar: they can edit it and add it to Google Calendar (the default) or the Mac's Calendar app. Use it when the user wants something in their calendar or asks you to make an event, from a page or from what they say, and again with the whole event to change one. Give times in the user's own time zone unless they were written in another, which goes in time_zone. Keep the title short and put where it is in location, never in the title. Set calendar only when the user names one. After calling it, say a sentence at most; the user sees the event.
            """,
                   parameters: ["type": "object", "additionalProperties": false, "required": ["title", "start"],
                                "properties": [
                                    "title": ["type": "string", "description": "Short, what it is: \"Lunch with Priya\", without its place or time."],
                                    "start": ["type": "string", "description": "\"2026-11-21T15:00\" for a time, or \"2026-11-21\" for a whole day."],
                                    "end": ["type": "string", "description": "The same way; for a whole-day event, its last day. Leave it out for an hour, or one day."],
                                    "all_day": ["type": "boolean"],
                                    "time_zone": ["type": "string", "description": "The IANA zone the times are written in, such as \"America/New_York\", where it isn't the user's own."],
                                    "location": ["type": "string", "description": "Where it is, whenever that's known: a venue, an address, or a call's link."],
                                    "notes": ["type": "string", "description": "Plain text: details, links, what to bring."],
                                    "calendar": ["type": "string", "enum": ["google", "apple"], "description": "Only when the user names Google Calendar or Apple's Calendar."]]],
                   step: { _ in AIChatStep(text: "Making an event", symbol: "calendar") },
                   run: { arguments, step in
            let draft = try AIChatEventDraft(arguments: arguments)
            var done = step.done("Made an event: \(draft.title.isEmpty ? draft.when : draft.title)")
            done.draft = .event(draft)
            return AIChatToolResult(output: "The event is shown to the user in the chat (\(draft.when)), where they can edit it and add it to their calendar.", step: done)
        })
    }
}

// MARK: The card

/// When it is, as the right-click menu says it, "Sat 21 Nov, 19:00 – 21:00"; clicked, a small
/// editor opens under it with its start, its end, and whether it lasts all day.
@MainActor final class AIChatEventTimes: FlippedView, AIChatCardRowContent, NSPopoverDelegate {
    let summary = label("", size: AIChatCard.fontSize)
    let startPicker = NSDatePicker(), endPicker = NSDatePicker()
    let allDay = NSButton(checkboxWithTitle: "All-day", target: nil, action: nil)
    var onChange: (() -> Void)?
    private let highlight = Surface(radius: 8)
    private var colors = AIChatColors(.neutral)
    private var hovering = false { didSet { refreshHighlight() } }
    private(set) var popover: NSPopover?
    /// The editor's content, made once and kept, so its controls stay the same ones.
    private(set) lazy var editor: NSView = makeEditor()
    static let padding: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        summary.lineBreakMode = .byTruncatingTail
        summary.setAccessibilityElement(false)
        for picker in [startPicker, endPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.font = AIChatStyle.font(13)
            picker.target = self; picker.action = #selector(changed)
        }
        startPicker.setAccessibilityLabel("Starts"); endPicker.setAccessibilityLabel("Ends")
        allDay.target = self; allDay.action = #selector(changed)
        highlight.isHidden = true
        [highlight, summary].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { onChange?() }

    func show(_ text: String) {
        summary.stringValue = text
        setAccessibilityLabel("When: \(text)")
        needsLayout = true
    }
    func rowHeight(for width: CGFloat) -> CGFloat { AIChatCard.rowHeight }
    override func layout() {
        super.layout()
        let height = ceil(summary.intrinsicContentSize.height)
        let width = min(ceil(summary.intrinsicContentSize.width)+4, bounds.width-Self.padding)
        summary.frame = NSRect(x: 0, y: round((bounds.height-height)/2), width: max(0, width), height: height)
        highlight.frame = NSRect(x: -Self.padding, y: round(bounds.height/2-14), width: summary.frame.width+2*Self.padding, height: 28)
    }
    func applyColors(_ colors: AIChatColors) {
        self.colors = colors
        summary.textColor = colors.text
        refreshHighlight()
    }
    private func refreshHighlight() {
        highlight.fill = colors.hover
        highlight.isHidden = !(hovering || popover != nil)
    }

    // MARK: Clicking it

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return highlight.frame.contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { openEditor() }
    override func accessibilityPerformPress() -> Bool { openEditor(); return true }

    func openEditor() {
        guard popover == nil, window != nil else { return }
        let controller = NSViewController(); controller.view = editor
        let popover = NSPopover()
        popover.behavior = .transient; popover.animates = true; popover.delegate = self
        popover.contentViewController = controller
        popover.appearance = effectiveAppearance
        self.popover = popover; refreshHighlight()
        popover.show(relativeTo: highlight.frame, of: self, preferredEdge: .maxY)
        window?.makeFirstResponder(startPicker)
    }
    func popoverDidClose(_ notification: Notification) { popover = nil; refreshHighlight() }

    private func makeEditor() -> NSView {
        func title(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text); field.font = AIChatStyle.font(13); field.textColor = .secondaryLabelColor
            field.alignment = .right; return field
        }
        let grid = NSGridView(views: [[title("Starts"), startPicker], [title("Ends"), endPicker], [NSGridCell.emptyContentView, allDay]])
        grid.rowSpacing = 10; grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)])
        return view
    }
}

/// The event in the answer (`AIChatCard`): its title and its actions on top, the calendar it goes
/// to, Google's unless the user picks Apple's, which is remembered, and Add, then its title, when
/// it is, where, and its notes.
@MainActor final class AIChatEventCard: AIChatCard {
    static let calendarKey = "Rise.AIChatEventCalendar"
    private(set) var draft: AIChatEventDraft
    /// Google's, Apple's, as last picked, or as the user asked the model for.
    private(set) var destination: AIChatEventDraft.Calendar
    let preferences: UserDefaults
    var onChange: ((AIChatEventDraft) -> Void)?
    /// Add was clicked: the event, where to, and the button, to show Calendar's editor from; it's
    /// told when the event's in.
    var onAdd: ((AIChatEventDraft, AIChatEventDraft.Calendar, NSView, @escaping () -> Void) -> Void)?

    let calendarButton = AIChatCardMenuButton(title: "Google Calendar")
    let addButton = AIChatCardPillButton(title: "Add")
    let titleField = AIChatCardField(placeholder: "Title", weight: .medium)
    private let whenLabel = label("When", size: fontSize, weight: .medium), whereLabel = label("Where", size: fontSize, weight: .medium)
    let times = AIChatEventTimes()
    let locationField = AIChatCardField(placeholder: "Add a place")

    init(_ draft: AIChatEventDraft, preferences: UserDefaults = .standard) {
        self.draft = draft; self.preferences = preferences
        destination = draft.calendar ?? AIChatEventDraft.Calendar(rawValue: preferences.string(forKey: Self.calendarKey) ?? "") ?? .google
        super.init(kind: "Event")
        calendarButton.makeMenu = { [weak self] in self?.makeCalendarMenu() }
        addButton.actionBlock = { [weak self] in self?.add() }
        [calendarButton, addButton].forEach(addSubview)
        titleField.onCommit = { [weak self] value in self?.update { $0.title = value } }
        locationField.onCommit = { [weak self] value in self?.update { $0.location = value } }
        times.onChange = { [weak self] in self?.timesChanged() }
        body.setAccessibilityLabel("Notes")
        body.onChange = { [weak self] text in
            guard let self else { return }
            self.draft.notes = text; self.edited()
            self.contentChanged(resized: true)
        }
        addRowViews([titleField, whenLabel, times, whereLabel, locationField])
        show(draft)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "Event" over its own title; folded, its title, as that's all that shows.
    override var headingText: String { isSuperseded && !draft.title.isEmpty ? draft.title : "Event" }
    override var headerButtons: [NSView] { [calendarButton, addButton] }
    override var rows: [Row] { [Row(content: titleField), Row(label: whenLabel, content: times), Row(label: whereLabel, content: locationField)] }
    override var bodyPlaceholder: String? { "Notes" }

    /// Takes an event that changed from outside, as the model rewrote it.
    func show(_ draft: AIChatEventDraft) {
        self.draft = draft
        if let calendar = draft.calendar { destination = calendar }
        calendarButton.setTitle(destination.title)
        titleField.stringValue = draft.title; locationField.stringValue = draft.location
        showTimes()
        setBody(draft.notes)
        addButton.setTitle("Add")
        contentChanged(resized: true)
    }
    private func showTimes() {
        let elements: NSDatePicker.ElementFlags = draft.isAllDay ? [.yearMonthDay] : [.yearMonthDay, .hourMinute]
        for picker in [times.startPicker, times.endPicker] {
            picker.datePickerElements = elements
            picker.timeZone = draft.timeZone ?? .current
        }
        times.startPicker.dateValue = draft.start
        // A whole-day event shows its last day, not the day after it.
        times.endPicker.dateValue = draft.isAllDay ? draft.end.addingTimeInterval(-86400) : draft.end
        times.allDay.state = draft.isAllDay ? .on : .off
        times.show(timesText)
    }
    /// "Sat 21 Nov, 19:00 – 21:00", in the zone it was given in, named, where that isn't the user's.
    private var timesText: String {
        let zone = draft.timeZone.flatMap { $0 == .current ? nil : $0 }
        let text = SelectionEvents.label(draft.selectionEvent, local: zone ?? .current)
        guard let zone, !draft.isAllDay else { return text }
        return "\(text) \(zone.abbreviation(for: draft.start) ?? zone.identifier)"
    }
    private func update(_ change: (inout AIChatEventDraft) -> Void) {
        var next = draft; change(&next)
        guard next != draft else { return }
        draft = next; edited(); contentChanged()
    }
    /// A new start keeps how long it lasts; an end before its start moves with it.
    private func timesChanged() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = draft.timeZone ?? .current
        let allDay = times.allDay.state == .on
        var next = draft
        if allDay != draft.isAllDay {
            next.isAllDay = allDay
            next.start = allDay ? calendar.startOfDay(for: draft.start) : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: draft.start) ?? draft.start
            next.end = allDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: draft.end.addingTimeInterval(-1)))! : next.start.addingTimeInterval(3600)
        } else {
            let start = allDay ? calendar.startOfDay(for: times.startPicker.dateValue) : times.startPicker.dateValue
            var end = allDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: times.endPicker.dateValue))! : times.endPicker.dateValue
            if start != draft.start { end = start.addingTimeInterval(draft.end.timeIntervalSince(draft.start)) }
            if end <= start { end = allDay ? calendar.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600) }
            next.start = start; next.end = end
        }
        guard next != draft else { return }
        draft = next; showTimes(); edited(); contentChanged(resized: true)
    }
    private func edited() {
        addButton.setTitle("Add"); needsLayout = true
        onChange?(draft)
    }

    private func makeCalendarMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for calendar in AIChatEventDraft.Calendar.allCases {
            let item = NSMenuItem(title: calendar.title, action: #selector(MenuAction.invoke), keyEquivalent: "")
            let handler = MenuAction { [weak self] in self?.choose(calendar) }
            item.target = handler; item.representedObject = handler; item.state = calendar == destination ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    /// Where Add puts it, remembered for the next event.
    func choose(_ calendar: AIChatEventDraft.Calendar) {
        destination = calendar
        preferences.set(calendar.rawValue, forKey: Self.calendarKey)
        calendarButton.setTitle(calendar.title); addButton.setTitle("Add")
        needsLayout = true
    }
    private func add() {
        window?.makeFirstResponder(self)
        onAdd?(draft, destination, addButton) { [weak self] in
            self?.addButton.setTitle("Added", symbol: "checkmark"); self?.needsLayout = true
        }
    }

    override func applyColors(_ colors: AIChatColors) {
        super.applyColors(colors)
        calendarButton.applyColors(colors); addButton.applyColors(colors)
    }
}

// MARK: Adding it

@MainActor extension BrowserController {
    /// Google Calendar's editor, filled in, in a tab, in the account of a Calendar tab the user
    /// keeps; or Calendar's own editor, filled in, from the Add button, where Return adds it.
    func addAIChatEvent(_ draft: AIChatEventDraft, to calendar: AIChatEventDraft.Calendar, from button: NSView, added: @escaping () -> Void) {
        switch calendar {
        case .google:
            let account = tabs.lazy.compactMap { CalendarAccount(url: $0.url) }.first
            addTab(url: SelectionEvents.googleCalendarURL(draft.selectionEvent, base: account?.baseURL))
            added()
        case .apple:
            editSelectionEvent(draft.selectionEvent, as: .event, source: nil, at: NSPoint(x: button.bounds.midX, y: button.bounds.maxY), in: button) { _ in added() }
        }
    }
}
