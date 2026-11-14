import XCTest
import AppKit
@testable import Rise
import RiseCore

@MainActor final class AIChatEventTests: XCTestCase {
    private var preferences: UserDefaults!
    override func setUp() {
        super.setUp()
        preferences = UserDefaults(suiteName: "AIChatEventTests")!
        preferences.removePersistentDomain(forName: "AIChatEventTests")
    }
    override func tearDown() { preferences.removePersistentDomain(forName: "AIChatEventTests"); super.tearDown() }

    private func local(_ text: String, zone: TimeZone = .current) -> Date {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = zone
        format.dateFormat = text.count == 10 ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
        return format.date(from: text)!
    }
    private let dinner = AIChatEventDraft(title: "Dinner with Sam", start: Date(timeIntervalSince1970: 1_795_000_000),
                                          end: Date(timeIntervalSince1970: 1_795_007_200), location: "Dishoom")

    func testTimesAreReadInTheUsersZoneOrTheOneGivenAndDaysMakeItAllDay() throws {
        var event = try AIChatEventDraft(arguments: ["title": "Call", "start": "2026-11-21T15:00"])
        XCTAssertEqual(event.start, local("2026-11-21T15:00"))
        XCTAssertEqual(event.end, local("2026-11-21T16:00"), "No end: an hour")
        XCTAssertFalse(event.isAllDay); XCTAssertNil(event.timeZone); XCTAssertNil(event.calendar)

        let york = TimeZone(identifier: "America/New_York")!
        event = try AIChatEventDraft(arguments: ["title": "Launch", "start": "2026-11-21T09:30", "end": "2026-11-21T11:00", "time_zone": "America/New_York"])
        XCTAssertEqual(event.start, local("2026-11-21T09:30", zone: york)); XCTAssertEqual(event.end, local("2026-11-21T11:00", zone: york))
        XCTAssertEqual(event.timeZone, york)

        event = try AIChatEventDraft(arguments: ["title": "Flight", "start": "2026-11-21T09:30:00+01:00"])
        XCTAssertEqual(event.start, Date(timeIntervalSince1970: 1_795_249_800))

        event = try AIChatEventDraft(arguments: ["title": "Conference", "start": "2026-11-21", "end": "2026-11-23", "calendar": "Apple"])
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.start, local("2026-11-21")); XCTAssertEqual(event.end, local("2026-11-24"), "The end day is the last day")
        XCTAssertEqual(event.calendar, .apple)

        event = try AIChatEventDraft(arguments: ["title": "Holiday", "start": "2026-12-24"])
        XCTAssertEqual(event.end, local("2026-12-25"), "One day")
        event = try AIChatEventDraft(arguments: ["title": "Backwards", "start": "2026-11-21T15:00", "end": "2026-11-21T14:00"])
        XCTAssertEqual(event.end, local("2026-11-21T16:00"), "An end before the start: an hour")

        XCTAssertThrowsError(try AIChatEventDraft(arguments: ["title": "When?", "start": "next Friday"])) { XCTAssertTrue($0 is AIChatToolFailure) }
    }

    func testTheToolShowsTheEventAndTheModelSeesItAsEditedLater() async throws {
        let tools = AIChatBrowserTools(browser: BrowserController())
        let tool = tools.createEvent
        XCTAssertTrue(tools.tools.contains { $0.name == "create_event" })
        let result = try await tool.run(["title": "Dinner with Sam", "start": "2026-11-21T19:00", "location": "Dishoom"], tool.step([:]))
        guard case .event(let event)? = result.step?.draft else { return XCTFail("No event") }
        XCTAssertEqual(event.title, "Dinner with Sam"); XCTAssertEqual(event.location, "Dishoom")
        XCTAssertEqual(result.step?.state, .done)

        var turn = AIChatTurn(question: "Put dinner with Sam in my calendar", pages: [])
        var edited = event; edited.notes = "Booked for two."
        turn.drafts = [("call_1", .event(edited))]
        let reply = try XCTUnwrap(AIChatPrompt.messages(history: [turn], current: AIChatTurn(question: "Make it 8", pages: []), instructions: "")[2]["content"] as? String)
        XCTAssertTrue(reply.hasPrefix("<event_draft>\nTitle: Dinner with Sam\nWhen: "), reply)
        XCTAssertTrue(reply.contains("Where: Dishoom\nNotes: Booked for two.\n</event_draft>"), reply)
    }

    func testGoogleCalendarIsTheDefaultAndThePickIsRemembered() throws {
        var card = AIChatEventCard(dinner, preferences: preferences)
        XCTAssertEqual(card.destination, .google); XCTAssertEqual(card.calendarButton.accessibilityLabel(), "Google Calendar")
        let menu = try XCTUnwrap(card.calendarButton.makeMenu?())
        XCTAssertEqual(menu.items.map(\.title), ["Google Calendar", "Apple Calendar"])
        XCTAssertEqual(menu.items.map(\.state), [.on, .off])
        let apple = menu.items[1]
        (apple.target as? MenuAction)?.invoke()
        XCTAssertEqual(card.destination, .apple); XCTAssertEqual(card.calendarButton.accessibilityLabel(), "Apple Calendar")

        card = AIChatEventCard(dinner, preferences: preferences)
        XCTAssertEqual(card.destination, .apple, "The next event goes where the last did")
        var asked = dinner; asked.calendar = .google
        card = AIChatEventCard(asked, preferences: preferences)
        XCTAssertEqual(card.destination, .google, "Unless the user named one")
    }

    func testAddSendsTheEventAsEditedAndSaysWhenItsIn() throws {
        let card = AIChatEventCard(dinner, preferences: preferences)
        card.frame = NSRect(x: 0, y: 0, width: 440, height: card.height(for: 440)); card.layoutSubtreeIfNeeded()
        var edits: [AIChatEventDraft] = []
        card.onChange = { edits.append($0) }
        card.titleField.stringValue = "Dinner with Sam and Alex"
        card.titleField.onCommit?(card.titleField.stringValue)
        XCTAssertEqual(edits.last?.title, "Dinner with Sam and Alex")
        XCTAssertEqual(card.heading.stringValue, "Event")
        card.isSuperseded = true
        XCTAssertEqual(card.heading.stringValue, "Earlier draft · Dinner with Sam and Alex", "Folded, its title shows")
        card.isSuperseded = false

        var added: (AIChatEventDraft, AIChatEventDraft.Calendar, NSView, () -> Void)?
        card.onAdd = { added = ($0, $1, $2, $3) }
        card.addButton.actionBlock?()
        let (event, calendar, button, done) = try XCTUnwrap(added)
        XCTAssertEqual(event.title, "Dinner with Sam and Alex"); XCTAssertEqual(calendar, .google)
        XCTAssertTrue(button === card.addButton)
        XCTAssertEqual(card.addButton.accessibilityLabel(), "Add")
        done()
        XCTAssertEqual(card.addButton.accessibilityLabel(), "Added")
        card.locationField.stringValue = "Hoppers"; card.locationField.onCommit?("Hoppers")
        XCTAssertEqual(card.addButton.accessibilityLabel(), "Add", "Changed since: it can be added again")
    }

    func testANewStartKeepsHowLongItLastsAndAllDayShowsItsLastDay() {
        let card = AIChatEventCard(dinner, preferences: preferences)
        var edits: [AIChatEventDraft] = []
        card.onChange = { edits.append($0) }
        card.times.startPicker.dateValue = dinner.start.addingTimeInterval(3600)
        card.times.startPicker.sendAction(card.times.startPicker.action, to: card.times.startPicker.target)
        XCTAssertEqual(edits.last?.start, dinner.start.addingTimeInterval(3600))
        XCTAssertEqual(edits.last?.end, dinner.end.addingTimeInterval(3600), "Still two hours")
        XCTAssertEqual(card.times.endPicker.dateValue, dinner.end.addingTimeInterval(3600))

        card.times.allDay.state = .on
        card.times.allDay.sendAction(card.times.allDay.action, to: card.times.allDay.target)
        let day = Calendar.current.startOfDay(for: dinner.start.addingTimeInterval(3600))
        XCTAssertEqual(edits.last?.isAllDay, true); XCTAssertEqual(edits.last?.start, day)
        XCTAssertEqual(card.times.startPicker.datePickerElements, [.yearMonthDay])
        XCTAssertEqual(card.times.endPicker.dateValue, edits.last.map { $0.end.addingTimeInterval(-86400) }, "Its last day, not the day after")
        XCTAssertEqual(card.times.summary.stringValue, SelectionEvents.label(edits.last!.selectionEvent))
    }

    func testTheRowsLineUpAndTheTimesReadAsTheMenuSaysThem() throws {
        let card = AIChatEventCard(dinner, preferences: preferences)
        card.applyColors(AIChatColors(.neutral))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView?.addSubview(card)
        card.frame = NSRect(x: 20, y: 20, width: 440, height: card.height(for: 440)); card.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(card.titleField.frame.width, 300, "The title has the row")
        XCTAssertLessThan(card.titleField.frame.minX, card.times.frame.minX)
        XCTAssertEqual(card.times.summary.stringValue, SelectionEvents.label(dinner.selectionEvent))
        XCTAssertEqual(card.times.frame.minX, card.locationField.frame.minX, accuracy: 30, "When and Where's contents start near each other")
        for view in [card.calendarButton, card.addButton] as [NSView] {
            XCTAssertLessThanOrEqual(view.frame.maxX, card.bounds.maxX-12)
            XCTAssertLessThan(view.frame.maxY, AIChatCard.headerHeight)
        }
        XCTAssertLessThanOrEqual(card.calendarButton.frame.maxX+6, card.addButton.frame.minX)
        XCTAssertLessThan(card.heading.frame.maxX, card.calendarButton.frame.minX+1)

        // Clicked, its editor opens with the times in it.
        let click = card.times.convert(NSPoint(x: 10, y: card.times.bounds.midY), to: card.times.superview)
        XCTAssertTrue(card.times.hitTest(click) === card.times)
        card.times.openEditor()
        XCTAssertNotNil(card.times.popover)
        XCTAssertTrue(card.times.startPicker.isDescendant(of: card.times.editor))
        card.times.popover?.close()
        let york = TimeZone(identifier: "America/New_York")!
        var elsewhere = dinner; elsewhere.timeZone = york
        card.show(elsewhere)
        XCTAssertTrue(card.times.summary.stringValue.hasSuffix(" "+york.abbreviation(for: dinner.start)!), card.times.summary.stringValue)
        XCTAssertEqual(card.times.startPicker.timeZone, york)
        window.close()
    }

    func testAnAnswersEventsAllStayOpenAndAnEmailBesideThemToo() {
        let answer = AIChatAnswerView(thinking: false)
        answer.preferences = preferences
        answer.frame = NSRect(x: 0, y: 0, width: 440, height: 10)
        for id in ["call_1", "call_2"] {
            var step = AIChatStep(text: "Made an event", symbol: "calendar", state: .done); step.draft = .event(dinner)
            answer.setStep(id, step)
        }
        var step = AIChatStep(text: "Wrote an email", symbol: "envelope", state: .done); step.draft = .email(AIChatEmailDraft(subject: "Dinner", body: "Hi"))
        answer.setStep("call_3", step)
        XCTAssertEqual(answer.cards.map { $0.card.kind }, ["Event", "Event", "Email"])
        var added: [AIChatEventDraft.Calendar] = []
        answer.onAddEvent = { _, calendar, _, done in added.append(calendar); done() }
        (answer.cards[1].card as? AIChatEventCard)?.addButton.actionBlock?()
        XCTAssertEqual(added, [.google])
    }

    func testGoogleCalendarOpensFilledInInATab() throws {
        let browser = BrowserController()
        let count = browser.tabs.count
        var added = 0
        browser.addAIChatEvent(dinner, to: .google, from: NSView(), added: { added += 1 })
        XCTAssertEqual(browser.tabs.count, count+1)
        let url = try XCTUnwrap(browser.tabs.compactMap(\.url).first { $0.host == "calendar.google.com" })
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "text" }?.value, "Dinner with Sam")
        XCTAssertEqual(query.first { $0.name == "location" }?.value, "Dishoom")
        XCTAssertEqual(added, 1)
    }
}
