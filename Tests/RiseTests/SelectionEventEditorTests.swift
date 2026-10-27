import XCTest
import AppKit
import EventKit
@testable import Rise
import RiseCore

final class SelectionEventEditorTests: XCTestCase {
    /// Tuesday 27 October 2026, 10:00 in London.
    let now = Date(timeIntervalSince1970: 1_793_095_200)
    let source = URL(string: "https://mail.google.com/mail/u/0/#inbox/1")!

    @MainActor private func editor(_ text: String, kind: SelectionEventEditor.Kind = .event, page: String? = nil) throws -> SelectionEventEditor {
        let event = try XCTUnwrap(SelectionEvents.find(in: text, pageTitle: page, now: now))
        let defaults = UserDefaults(suiteName: "SelectionEventEditorTests-\(UUID())")!
        let editor = SelectionEventEditor(kind: kind, event: event, source: source, store: EKEventStore(), access: .writeOnly,
                                          preferences: defaults, theme: .neutral)
        _ = editor.view
        return editor
    }

    @MainActor func testTheEditorIsFilledInWithTheEvent() throws {
        let text = "Event details\nDate: Tuesday, November 3, 2026\nTime: 13:30 - 20:30\nLocation: Corner Corner, Maritime St, London SE16 7LL"
        let editor = try editor(text, page: "OpenAI DevDay Exchange: London - me@example.com - Gmail")
        XCTAssertEqual(editor.titleField.stringValue, "OpenAI DevDay Exchange: London")
        XCTAssertEqual(editor.locationField.stringValue, "Corner Corner, Maritime St, London SE16 7LL")
        XCTAssertEqual(editor.allDay.state, .off)
        XCTAssertTrue(editor.addButton.isEnabled, "Return adds it as it is")
        XCTAssertEqual(editor.addButton.keyEquivalent, "\r")
        let event = try XCTUnwrap(editor.item() as? EKEvent)
        XCTAssertEqual(event.title, "OpenAI DevDay Exchange: London")
        XCTAssertEqual(event.location, "Corner Corner, Maritime St, London SE16 7LL")
        XCTAssertEqual(event.startDate, editor.event.start)
        XCTAssertEqual(event.endDate.timeIntervalSince(event.startDate), 7*3600)
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.url, source)
        XCTAssertEqual(event.notes, text)
        XCTAssertTrue(event.alarms?.isEmpty ?? true)
    }

    @MainActor func testEditsMakeTheEvent() throws {
        let editor = try editor("Dinner with Sam on Friday at 7pm")
        editor.titleField.stringValue = "  Dinner with Sam and Alex "
        editor.locationField.stringValue = "Dishoom"
        editor.alertPopup.selectItem(at: 3)
        let event = try XCTUnwrap(editor.item() as? EKEvent)
        XCTAssertEqual(event.title, "Dinner with Sam and Alex")
        XCTAssertEqual(event.location, "Dishoom")
        XCTAssertEqual(event.alarms?.first?.relativeOffset, -900)
        XCTAssertEqual(event.endDate.timeIntervalSince(event.startDate), 3600, "An hour where no end was written")
    }

    @MainActor func testADayIsAllDayAndAnEndBeforeTheStartCantBeAdded() throws {
        let editor = try editor("Team offsite\nNovember 3–5, 2026")
        XCTAssertEqual(editor.allDay.state, .on)
        XCTAssertEqual(editor.startPicker.datePickerElements, .yearMonthDay)
        let event = try XCTUnwrap(editor.item() as? EKEvent)
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.title, "Team offsite")
        XCTAssertEqual(Calendar.current.dateComponents([.month, .day], from: event.startDate), DateComponents(month: 11, day: 3))
        XCTAssertEqual(Calendar.current.dateComponents([.month, .day], from: event.endDate), DateComponents(month: 11, day: 5))

        editor.endPicker.dateValue = editor.startPicker.dateValue.addingTimeInterval(-86400)
        editor.endPicker.sendAction(editor.endPicker.action, to: editor.endPicker.target)
        XCTAssertFalse(editor.addButton.isEnabled)
    }

    @MainActor func testAWrittenZoneIsKeptAndNoted() throws {
        let editor = try editor("Wed, Nov 4, 2026 9:00 AM – 10:00 AM (PST)")
        let event = try XCTUnwrap(editor.item() as? EKEvent)
        XCTAssertEqual(event.timeZone?.identifier, "America/Los_Angeles")
        XCTAssertTrue(editor.view.subviews.first?.descendants.contains { ($0 as? NSTextField)?.stringValue.hasPrefix("Written in") == true } == true)
    }

    @MainActor func testTheReminderIsDueAtTheTime() throws {
        let editor = try editor("tomorrow at 3pm\nLocation: The Old Bar", kind: .reminder)
        XCTAssertEqual(editor.addButton.title, "Add to Reminders")
        let reminder = try XCTUnwrap(editor.item() as? EKReminder)
        XCTAssertEqual(reminder.dueDateComponents?.hour, 15)
        XCTAssertEqual(reminder.dueDateComponents?.day, 28)
        XCTAssertEqual(reminder.alarms?.first?.absoluteDate, editor.event.start)
        XCTAssertEqual(reminder.notes?.hasPrefix("The Old Bar"), true)
        XCTAssertEqual(reminder.url, source)
    }

    @MainActor func testWithoutAccessTheEditorSaysHowToAllowIt() throws {
        let event = try XCTUnwrap(SelectionEvents.find(in: "Nov 3, 2026 at 7pm", now: now))
        let editor = SelectionEventEditor(kind: .event, event: event, source: nil, store: EKEventStore(), access: .denied,
                                          preferences: .standard, theme: .neutral)
        let words = editor.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(words.contains("Rise can’t add to Calendar"))
        XCTAssertTrue(editor.view.descendants.contains { ($0 as? NSButton)?.title == "Open Privacy Settings" })
    }

    @MainActor func testTheMenuItemOpensToCalendarRemindersAndGoogleCalendar() throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent()) }
        let event = try XCTUnwrap(SelectionEvents.find(in: "Date: Tuesday, November 3, 2026\nTime: 13:30 - 20:30", pageTitle: "DevDay - Gmail", now: now))
        var opened: URL?
        let item = browser.selectionEventItem(event, source: source, at: .zero, in: NSView()) { opened = $0 }
        XCTAssertEqual(item.title, SelectionEvents.label(event))
        XCTAssertEqual(item.submenu?.items.map(\.title), ["Add to Calendar…", "Add to Reminders…", "Add to Google Calendar"])
        let google = try XCTUnwrap(item.submenu?.items.last)
        _ = (google.target as? NSObject)?.perform(google.action)
        let url = try XCTUnwrap(opened)
        XCTAssertEqual(url.host, "calendar.google.com")
        XCTAssertTrue(url.path.hasSuffix("/r/eventedit"))
        XCTAssertTrue(url.query?.contains("text=DevDay") == true)
    }
}

private extension NSView {
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}
