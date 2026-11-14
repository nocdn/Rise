import AppKit
import EventKit
import RiseCore

/// One store for the app, as Apple advises: each opens its own connection to the calendar's database.
@MainActor enum CalendarStore {
    static let shared = EKEventStore()
}

/// An event read from the selection (`SelectionEvents`), heading the right-click menu as its time and
/// opening to Calendar, Reminders and Google Calendar, each filled in to look over and add with Return.
@MainActor extension BrowserController {
    func selectionEventItem(_ event: SelectionEvent, title: String? = nil, source: URL?, at point: NSPoint, in view: NSView,
                            open: @escaping (URL) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? SelectionEvents.label(event), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        let submenu = NSMenu(); submenu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            let entry = menuItem(title, action: action)
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            submenu.addItem(entry)
        }
        add("Add to Calendar…", "calendar.badge.plus") { [weak self, weak view] in
            guard let self, let view else { return }
            self.editSelectionEvent(event, as: .event, source: source, at: point, in: view)
        }
        add("Add to Reminders…", "checklist") { [weak self, weak view] in
            guard let self, let view else { return }
            self.editSelectionEvent(event, as: .reminder, source: source, at: point, in: view)
        }
        // In the account of the Calendar tab the person keeps, where there is one.
        let account = tabs.lazy.compactMap { CalendarAccount(url: $0.url) }.first
        add("Add to Google Calendar", "globe") {
            open(SelectionEvents.googleCalendarURL(event, base: account?.baseURL, sourceURL: source))
        }
        item.submenu = submenu
        return item
    }

    /// Calendar's or Reminders' access, asked for once, and then the editor, from where the menu opened.
    func editSelectionEvent(_ event: SelectionEvent, as kind: SelectionEventEditor.Kind, source: URL?, at point: NSPoint, in view: NSView,
                            added: ((EKCalendarItem) -> Void)? = nil) {
        let store = CalendarStore.shared
        Task { @MainActor [weak self, weak view] in
            let access = await SelectionEventEditor.access(for: kind, in: store)
            guard let self, let view, view.window != nil else { return }
            let editor = SelectionEventEditor(kind: kind, event: event, source: source, store: store, access: access,
                                              preferences: preferences, theme: theme)
            editor.onAdded = { [weak self] item in self?.didAddSelectionItem(item, store: store); added?(item) }
            editor.present(at: point, in: view, appearance: theme.appearance)
        }
    }
}

@MainActor final class SelectionEventEditor: NSViewController, NSPopoverDelegate {
    enum Kind { case event, reminder }
    enum Access: Equatable { case full, writeOnly, denied }

    let kind: Kind
    private(set) var event: SelectionEvent
    let source: URL?
    let store: EKEventStore
    let access: Access
    let preferences: UserDefaults
    let theme: RiseTheme
    /// What to tell the person once it's saved: "Added to" and the calendar's name, to open it.
    var onAdded: ((EKCalendarItem) -> Void)?

    let titleField = NSTextField()
    let locationField = NSTextField()
    let allDay = NSButton(checkboxWithTitle: "All-day", target: nil, action: nil)
    let startPicker = NSDatePicker(), endPicker = NSDatePicker()
    let calendarPopup = NSPopUpButton()
    let alertPopup = NSPopUpButton()
    let notesField = NSTextField()
    private(set) var addButton: NSButton!
    private(set) var calendars: [EKCalendar] = []
    private var popover: NSPopover?
    /// The popover shown, kept while it is.
    private static var shown: SelectionEventEditor?

    /// Alerts to choose from, as seconds before the start; nil is none.
    static let alerts: [(String, TimeInterval?)] = [("None", nil), ("At time of event", 0), ("5 minutes before", 300),
        ("15 minutes before", 900), ("30 minutes before", 1800), ("1 hour before", 3600), ("1 day before", 86400)]
    static let calendarKey = "Rise.SelectionEvents.Calendar", listKey = "Rise.SelectionEvents.ReminderList"
    static let alertKey = "Rise.SelectionEvents.Alert"

    init(kind: Kind, event: SelectionEvent, source: URL?, store: EKEventStore, access: Access, preferences: UserDefaults, theme: RiseTheme) {
        self.kind = kind; self.event = event; self.source = source; self.store = store; self.access = access
        self.preferences = preferences; self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Asks for access the first time; Calendar can also add events it can't read.
    static func access(for kind: Kind, in store: EKEventStore) async -> Access {
        let type: EKEntityType = kind == .event ? .event : .reminder
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return .full
        case .writeOnly: return kind == .event ? .writeOnly : .denied
        case .notDetermined:
            let granted = (try? await (kind == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())) ?? false
            if granted { return .full }
            return EKEventStore.authorizationStatus(for: type) == .writeOnly && kind == .event ? .writeOnly : .denied
        default: return .denied
        }
    }

    override func loadView() {
        let width: CGFloat = 340
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view = root
        guard access != .denied else { loadDenied(in: root, width: width); return }

        titleField.stringValue = event.title
        titleField.placeholderString = kind == .event ? "New Event" : "New Reminder"
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        titleField.isBordered = false; titleField.drawsBackground = false; titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail; titleField.cell?.usesSingleLineMode = true
        titleField.setAccessibilityLabel("Title")

        locationField.stringValue = event.location ?? ""
        locationField.placeholderString = "Add Location"
        notesField.stringValue = event.notes
        notesField.placeholderString = "Add Notes"
        notesField.cell?.wraps = true; notesField.cell?.isScrollable = false; notesField.usesSingleLineMode = false
        notesField.maximumNumberOfLines = 4; notesField.lineBreakMode = .byWordWrapping
        notesField.setAccessibilityLabel("Notes")

        allDay.state = event.isAllDay ? .on : .off
        allDay.target = self; allDay.action = #selector(allDayChanged)
        for picker in [startPicker, endPicker] {
            picker.datePickerStyle = .textFieldAndStepper; picker.isBezeled = true; picker.drawsBackground = true
            picker.timeZone = .current; picker.calendar = .current; picker.locale = .current
            picker.target = self; picker.action = #selector(dateChanged(_:))
        }
        startPicker.dateValue = event.start
        endPicker.dateValue = event.isAllDay ? event.end.addingTimeInterval(-1) : event.end
        startPicker.setAccessibilityLabel(kind == .event ? "Starts" : "Due")
        endPicker.setAccessibilityLabel("Ends")
        updatePickers()

        loadCalendars()
        alertPopup.addItems(withTitles: Self.alerts.map(\.0))
        if kind == .reminder {
            alertPopup.removeAllItems()
            alertPopup.addItems(withTitles: ["None", "On date"])
            alertPopup.selectItem(at: event.isAllDay ? 0 : 1)
        } else {
            alertPopup.selectItem(at: max(0, min(preferences.integer(forKey: Self.alertKey), Self.alerts.count-1)))
        }

        var rows: [[NSView]] = []
        func row(_ name: String, _ control: NSView) { rows.append([caption(name), control]) }
        row("Location", locationField)
        if kind == .event {
            row("", allDay)
            row("Starts", startPicker)
            row("Ends", endPicker)
        } else {
            row("Due", startPicker)
        }
        if let zone = event.timeZone, !event.isAllDay {
            let name = zone.localizedName(for: .generic, locale: .current) ?? zone.identifier
            let note = NSTextField(wrappingLabelWithString: "Written in \(name); shown in your time.")
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize); note.textColor = .secondaryLabelColor
            row("", note)
        }
        row(kind == .event ? "Calendar" : "List", calendarPopup)
        row("Alert", alertPopup)
        row("Notes", notesField)
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = width - 32 - 70 - 10
        grid.rowAlignment = .firstBaseline

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        addButton = NSButton(title: kind == .event ? "Add to Calendar" : "Add to Reminders", target: self, action: #selector(add))
        addButton.keyEquivalent = "\r"
        addButton.setAccessibilityIdentifier("SelectionEventAdd")
        let buttons = NSStackView(views: [cancel, addButton]); buttons.spacing = 8

        let stack = NSStackView(views: [titleField, grid, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.setCustomSpacing(18, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: width),
            titleField.widthAnchor.constraint(equalToConstant: width-32),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            notesField.widthAnchor.constraint(equalToConstant: width-32-70-10),
            locationField.widthAnchor.constraint(equalTo: notesField.widthAnchor),
        ])
        validate()
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        field.alignment = .right
        return field
    }

    /// No access: why, and the way to Settings.
    private func loadDenied(in root: NSView, width: CGFloat) {
        let app = kind == .event ? "Calendar" : "Reminders"
        let heading = NSTextField(labelWithString: "Rise can’t add to \(app)")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: "Allow Rise to use \(app) in Privacy & Security, then try again.")
        body.textColor = .secondaryLabelColor
        let open = NSButton(title: "Open Privacy Settings", target: self, action: #selector(openSettings))
        open.keyEquivalent = "\r"
        let stack = NSStackView(views: [heading, body, open])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: width), body.widthAnchor.constraint(equalToConstant: width-32),
        ])
    }

    /// The calendars or lists that can take it, each with its colour, the last one used first chosen.
    private func loadCalendars() {
        calendarPopup.removeAllItems()
        guard access == .full else {
            // Write-only access can't list calendars; it adds to the default one.
            calendarPopup.addItem(withTitle: "Default Calendar"); calendarPopup.isEnabled = false
            return
        }
        calendars = store.calendars(for: kind == .event ? .event : .reminder).filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
        let fallback = kind == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        let remembered = preferences.string(forKey: kind == .event ? Self.calendarKey : Self.listKey)
        var lastSource: String?
        for calendar in calendars {
            if calendars.contains(where: { $0.source.title != calendar.source.title }), calendar.source.title != lastSource {
                if lastSource != nil { calendarPopup.menu?.addItem(.separator()) }
                let header = NSMenuItem.sectionHeader(title: calendar.source.title)
                calendarPopup.menu?.addItem(header)
                lastSource = calendar.source.title
            }
            let item = NSMenuItem(title: calendar.title, action: nil, keyEquivalent: "")
            item.image = Self.swatch(calendar.color)
            item.representedObject = calendar.calendarIdentifier
            calendarPopup.menu?.addItem(item)
        }
        let chosen = calendars.first { $0.calendarIdentifier == remembered } ?? fallback ?? calendars.first
        if let index = calendarPopup.menu?.items.firstIndex(where: { $0.representedObject as? String == chosen?.calendarIdentifier }) {
            calendarPopup.selectItem(at: index)
        }
        calendarPopup.isEnabled = !calendars.isEmpty
    }

    static func swatch(_ color: NSColor?) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            (color ?? .systemBlue).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    var selectedCalendar: EKCalendar? {
        guard access == .full else { return kind == .event ? store.defaultCalendarForNewEvents : nil }
        let id = calendarPopup.selectedItem?.representedObject as? String
        return calendars.first { $0.calendarIdentifier == id }
    }

    func present(at point: NSPoint, in view: NSView, appearance: NSAppearance?) {
        Self.shown?.popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient; popover.delegate = self
        popover.appearance = appearance
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = self
        self.view.layoutSubtreeIfNeeded()
        popover.contentSize = self.view.fittingSize
        self.popover = popover; Self.shown = self
        popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .maxY)
        // The title first, chosen, to type over or leave.
        if access != .denied {
            self.view.window?.makeFirstResponder(titleField)
            titleField.currentEditor()?.selectAll(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.shown === self { Self.shown = nil }
    }

    @objc private func allDayChanged() {
        updatePickers()
        // Turning a day's event into a timed one: an hour from 9:00, as Calendar does.
        if allDay.state == .off, event.isAllDay {
            var calendar = Calendar.current; calendar.timeZone = .current
            let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: startPicker.dateValue) ?? startPicker.dateValue
            startPicker.dateValue = start; endPicker.dateValue = start.addingTimeInterval(3600)
        }
        validate()
    }

    private func updatePickers() {
        let elements: NSDatePicker.ElementFlags = allDay.state == .on ? .yearMonthDay : [.yearMonthDay, .hourMinute]
        startPicker.datePickerElements = elements; endPicker.datePickerElements = elements
    }

    private var lastStart: Date?
    @objc private func dateChanged(_ sender: NSDatePicker) {
        // Moving the start keeps the length, as Calendar's editor does.
        if sender === startPicker, kind == .event {
            let previous = lastStart ?? event.start
            endPicker.dateValue = endPicker.dateValue.addingTimeInterval(startPicker.dateValue.timeIntervalSince(previous))
        }
        lastStart = startPicker.dateValue
        validate()
    }

    private func validate() {
        let ordered = kind == .reminder || endPicker.dateValue >= startPicker.dateValue
        addButton?.isEnabled = ordered && (access != .full || selectedCalendar != nil)
        endPicker.textColor = ordered ? .controlTextColor : .systemRed
    }

    @objc private func cancel() { popover?.close() }
    @objc private func openSettings() {
        let pane = kind == .event ? "Privacy_Calendars" : "Privacy_Reminders"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        popover?.close()
    }

    /// The event or reminder as the editor has it, unsaved.
    func item() -> EKCalendarItem {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = locationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        if kind == .event {
            let item = EKEvent(eventStore: store)
            item.title = title.isEmpty ? "New Event" : title
            item.location = location.isEmpty ? nil : location
            item.isAllDay = allDay.state == .on
            if item.isAllDay {
                item.startDate = calendar.startOfDay(for: startPicker.dateValue)
                item.endDate = calendar.startOfDay(for: endPicker.dateValue)
            } else {
                item.startDate = startPicker.dateValue; item.endDate = endPicker.dateValue
                // Kept in the zone it was written in, so it stays put if that place's clocks change.
                item.timeZone = event.timeZone ?? .current
            }
            if let calendar = selectedCalendar { item.calendar = calendar }
            if let offset = Self.alerts[max(0, alertPopup.indexOfSelectedItem)].1 {
                item.addAlarm(EKAlarm(relativeOffset: item.isAllDay ? 9*3600 - offset : -offset))
            }
            item.url = source ?? event.meetingURL
            item.notes = notes.isEmpty ? nil : notes
            return item
        }
        let item = EKReminder(eventStore: store)
        item.title = title.isEmpty ? "New Reminder" : title
        let timed = allDay.state == .off
        var due = calendar.dateComponents(timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: startPicker.dateValue)
        due.calendar = calendar; if timed { due.timeZone = .current }
        item.dueDateComponents = due
        if alertPopup.indexOfSelectedItem == 1 {
            let at = timed ? startPicker.dateValue : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: startPicker.dateValue) ?? startPicker.dateValue
            item.addAlarm(EKAlarm(absoluteDate: at))
        }
        if let calendar = selectedCalendar { item.calendar = calendar }
        item.url = source
        let place = location.isEmpty ? nil : location
        item.notes = [place, notes.isEmpty ? nil : notes].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty
        return item
    }

    @objc private func add() {
        guard addButton.isEnabled else { return }
        let item = item()
        do {
            if let event = item as? EKEvent { try store.save(event, span: .thisEvent, commit: true) }
            else if let reminder = item as? EKReminder { try store.save(reminder, commit: true) }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = kind == .event ? "Couldn’t add the event" : "Couldn’t add the reminder"
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        if let calendar = item.calendar {
            preferences.set(calendar.calendarIdentifier, forKey: kind == .event ? Self.calendarKey : Self.listKey)
        }
        if kind == .event { preferences.set(alertPopup.indexOfSelectedItem, forKey: Self.alertKey) }
        popover?.close()
        onAdded?(item)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
