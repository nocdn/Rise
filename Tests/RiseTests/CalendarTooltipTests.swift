import XCTest
import AppKit
@testable import Rise

final class CalendarTooltipTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    private func chip(_ id: String, top: Double, height: Double, label: String = "", allDay: Bool = false) -> CalendarDay.Chip {
        CalendarDay.Chip(id: id, title: id, label: label, allDay: allDay, top: top, height: height)
    }
    private func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: end, allDay: allDay)
    }

    func testAccountsKeepTheirNumberAndViews() {
        XCTAssertNil(CalendarAccount(url: URL(string: "https://calendar.google.com.evil.test/calendar/u/0/r")))
        XCTAssertNil(CalendarAccount(url: URL(string: "https://calendar.google.com/other")))
        XCTAssertNil(CalendarAccount(url: URL(string: "http://calendar.google.com/calendar/r")))
        let account = CalendarAccount(url: URL(string: "https://calendar.google.com/calendar/u/2/r/week/2026/10/18?pli=1"))!
        XCTAssertEqual(account.baseURL.absoluteString, "https://calendar.google.com/calendar/u/2/")
        XCTAssertEqual(account.url(view: "day", day: DateComponents(year: 2026, month: 10, day: 19)).absoluteString,
                       "https://calendar.google.com/calendar/u/2/r/day/2026/10/19")
        XCTAssertEqual(CalendarAccount(url: URL(string: "https://calendar.google.com/calendar/r"))?.baseURL.absoluteString,
                       "https://calendar.google.com/calendar/")
        let auth = CalendarAccount(url: URL(string: "https://calendar.google.com/calendar/r?authuser=person@example.com&tab=mc"))!
        XCTAssertEqual(URLComponents(url: auth.baseURL, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["authuser"])
        XCTAssertEqual(CalendarAccount.view(of: URL(string: "https://calendar.google.com/calendar/u/0/r/month/2026/10/1")), "month")
        XCTAssertNil(CalendarAccount.view(of: URL(string: "https://calendar.google.com/calendar/u/0/r")))
        XCTAssertNil(CalendarAccount.view(of: URL(string: "https://calendar.google.com/calendar/u/0/r/eventedit/abc")))
    }

    func testDateKeysAreCalendarsOwn() {
        // Read from Calendar's day view of 18 October 2026.
        XCTAssertEqual(CalendarDay.key(DateComponents(year: 2026, month: 10, day: 18)), 29010)
        XCTAssertEqual(CalendarDay(key: 29011, height: 1440, chips: []).date, DateComponents(year: 2026, month: 10, day: 19))
    }

    /// Chips as Calendar drew them: a column of 1,441 points, each chip 2 points short of its end,
    /// and none shorter than a quarter hour.
    func testChipsBecomeEventsAcrossMidnight() {
        let today = CalendarDay(key: 29010, height: 1441, chips: [
            chip("allday", top: 0, height: 0, label: "All day, Rise all-day test", allDay: true),
            chip("yesterday", top: 0, height: 13, label: "17 October 2026 at 10:15pm to 18 October 2026 at 12:15am, another event"),
            chip("testing", top: 630, height: 58, label: "10:30am to 11:30am, testing event in rise"),
            chip("quick", top: 645, height: 13, label: "10:45am to 11am, Quick sync"),
            chip("tiny", top: 900, height: 13, label: "3pm to 3:05pm, Tiny, Bartek Bak, No location, 18 October 2026"),
            chip("late", top: 1380, height: 58, label: "18 October 2026 at 11pm to 19 October 2026 at 1am, Late night"),
        ])
        let tomorrow = CalendarDay(key: 29011, height: 1441, chips: [
            chip("late", top: 0, height: 58, label: "18 October 2026 at 11pm to 19 October 2026 at 1am, Late night"),
            chip("standup", top: 540, height: 28, label: "9am to 9:30am, Tomorrow standup"),
        ])
        let events = Dictionary(uniqueKeysWithValues: CalendarSchedule.events([today, tomorrow], calendar: calendar).map { ($0.id, $0) })
        XCTAssertEqual(events.count, 7)
        XCTAssertEqual(events["allday"], event("allday", time(18, 0), time(19, 0), allDay: true))
        XCTAssertEqual(events["yesterday"].map { [$0.start, $0.end] }, [time(18, 0), time(18, 0, 15)])
        XCTAssertEqual(events["testing"].map { [$0.start, $0.end] }, [time(18, 10, 30), time(18, 11, 30)])
        XCTAssertEqual(events["quick"].map { [$0.start, $0.end] }, [time(18, 10, 45), time(18, 11)])
        XCTAssertEqual(events["tiny"].map { [$0.start, $0.end] }, [time(18, 15), time(18, 15, 5)], "The label gives a short chip's end")
        XCTAssertEqual(events["late"].map { [$0.start, $0.end] }, [time(18, 23), time(19, 1)], "Both days' chips are one event")
        XCTAssertEqual(events["standup"].map { [$0.start, $0.end] }, [time(19, 9), time(19, 9, 30)])
    }

    /// Colours as Calendar painted them on 18 October 2026.
    func testEventsKeepTheirOwnColour() {
        XCTAssertEqual(CalendarSchedule.color(fill: "rgb(158, 105, 175)", border: "rgb(158, 105, 175)"), 0x9E69AF)
        XCTAssertEqual(CalendarSchedule.color(fill: "rgb(242, 179, 179)", border: "rgb(234, 128, 128)"), 0xD50101,
                       "An ended Tomato event, washed out, is Tomato again")
        XCTAssertEqual(CalendarSchedule.color(fill: "rgb(255, 255, 255)", border: "rgb(213, 0, 0)"), 0xD50000, "Not yet answered")
        XCTAssertEqual(CalendarSchedule.color(fill: "rgba(0, 0, 0, 0)", border: "rgb(158, 105, 175)"), 0x9E69AF)
        XCTAssertEqual(CalendarSchedule.color(fill: "rgb(3, 155, 229)", border: "rgb(255, 255, 255)"), 0x039BE5)
        XCTAssertNil(CalendarSchedule.color(fill: nil, border: nil))
        let day = CalendarDay(key: 29010, height: 1441, chips: [
            CalendarDay.Chip(id: "a", title: "a", label: "", allDay: false, top: 60, height: 58, fill: "rgb(213, 0, 0)", border: "rgb(213, 0, 0)")])
        XCTAssertEqual(CalendarSchedule.events([day], calendar: calendar).first?.color, 0xD50000)
    }

    @MainActor func testEventTooltipShowsItsTimesAndTheStartOfItsDescription() {
        let text = (1...8).map { "Line \($0)" }.joined(separator: "\n\n")
        let day = CalendarDay(key: 29010, height: 1441, chips: [
            CalendarDay.Chip(id: "a", title: "Stand-up", label: "", allDay: false, top: 60, height: 58,
                             description: CalendarPageReader.firstLines(text, CalendarPageReader.descriptionLines))])
        let event = try! XCTUnwrap(CalendarSchedule.events([day], calendar: calendar).first)
        XCTAssertEqual(CalendarEventChip(event, time: "16:05 – 16:30").toolTip,
                       "16:05 – 16:30\nLine 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6…", "No title, and six lines of the description")
        XCTAssertEqual(CalendarEventChip(CalendarEvent(id: "b", title: "OOO", start: Date(), end: Date(), allDay: true), time: nil).toolTip, "All day")
    }

    func testLabelledEndsInOtherFormats() {
        XCTAssertEqual(CalendarSchedule.labelledEnd("15:00 bis 15:05, Kurz", after: 900, before: 915), 905)
        XCTAssertEqual(CalendarSchedule.labelledEnd("15.00–15.10, Lyhyt", after: 900, before: 915), 910)
        XCTAssertEqual(CalendarSchedule.labelledEnd("15 h 00 à 15 h 05, Court", after: 900, before: 915), 905)
        XCTAssertNil(CalendarSchedule.labelledEnd("Event on 18, 2026", after: 900, before: 915), "Bare numbers could be dates")
    }

    func testBadgeCountsDownWithinTheHour() {
        let now = time(18, 10, 13)
        XCTAssertEqual(CalendarSchedule.badge([event("a", time(18, 10, 30), time(18, 11))], now: now), "in 17m")
        XCTAssertEqual(CalendarSchedule.badge([event("a", time(18, 11, 13), time(18, 12))], now: now), "in 1h")
        XCTAssertNil(CalendarSchedule.badge([event("a", time(18, 11, 30), time(18, 12))], now: now))
        XCTAssertEqual(CalendarSchedule.badge([event("a", time(18, 10, 10), time(18, 11)), event("b", time(18, 10, 20), time(18, 11))], now: now),
                       "now", "An event that just began wins")
        XCTAssertEqual(CalendarSchedule.badge([event("a", time(18, 9), time(18, 11)), event("b", time(18, 10, 20), time(18, 11))], now: now),
                       "in 7m", "One well under way doesn't")
        XCTAssertNil(CalendarSchedule.badge([event("a", time(18, 0), time(19, 0), allDay: true)], now: now))
    }

    func testAnswersComeFromTheChipAndADeclinedOrHiddenEventDoesNotCountDown() {
        func answer(invited: Bool? = true, fill: String = "rgb(3, 155, 229)", declined: Bool = false, striped: Bool = false) -> CalendarAnswer? {
            var chip = chip("a", top: 0, height: 60); chip.fill = fill; chip.declined = declined; chip.striped = striped; chip.invited = invited
            return CalendarSchedule.answer(chip)
        }
        XCTAssertEqual(answer(), .yes)
        XCTAssertNil(answer(fill: "rgb(255, 255, 255)"), "White inside its border: not answered yet")
        XCTAssertEqual(answer(fill: "rgb(255, 255, 255)", declined: true), .no)
        XCTAssertEqual(answer(striped: true), .maybe)
        XCTAssertNil(answer(invited: false), "Your own event has no invitation to answer")
        XCTAssertEqual(answer(invited: nil, striped: true), .maybe, "Stripes are an answer before its details are read")
        XCTAssertNil(answer(invited: nil), "Filled could be your own event")

        // A meeting of a repeating series, and one that doesn't repeat, as Calendar's chips name them.
        let id = { (event: String) in Data("\(event) me@example.com".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") }
        let now = time(29, 16)
        let beer = CalendarEvent(id: id("3t6j83_20261030T001500Z"), title: "Beer", start: time(29, 16, 15), end: time(29, 17), allDay: false)
        let nextBeer = CalendarEvent(id: id("3t6j83_20261106T001500Z"), title: "Beer", start: time(29, 16, 30), end: time(29, 17), allDay: false)
        let demo = CalendarEvent(id: id("pdp1gn"), title: "Demo", start: time(29, 16, 40), end: time(29, 17), allDay: false)
        XCTAssertEqual(beer.series, "3t6j83 me@example.com"); XCTAssertNil(demo.series)
        var declined = beer; declined.answer = .no
        XCTAssertEqual(CalendarSchedule.badge([declined, demo], now: now), "in 40m", "A declined event has nothing to count down to")

        var hiding = CalendarCountdownHiding()
        let counted = { [beer, nextBeer, demo].filter { hiding.scope(of: $0) == nil }.map(\.start) }
        hiding.set(.event, for: beer, now: now)
        XCTAssertEqual(counted(), [nextBeer.start, demo.start], "This event: only that meeting")
        hiding.set(.series, for: beer, now: now)
        XCTAssertEqual(hiding.scope(of: nextBeer), .series); XCTAssertEqual(counted(), [demo.start], "All events: every meeting of the series")
        hiding.set(.series, for: demo, now: now)
        XCTAssertEqual(hiding.scope(of: demo), .event, "One that doesn't repeat is hidden on its own")
        hiding.set(nil, for: nextBeer, now: now)
        XCTAssertEqual(counted(), [beer.start, nextBeer.start], "Showing it again clears the series")
        hiding.set(.event, for: beer, now: now)
        hiding.set(nil, for: demo, now: time(29, 16).addingTimeInterval(8*24*3600))
        XCTAssertTrue(hiding.entries.isEmpty, "A hidden meeting is forgotten a week after it ends")
    }

    @MainActor func testTheMenuAnswersAndHides() {
        var answered: CalendarAnswer?, hidden: [CalendarCountdownHiding.Scope?] = []
        func menu(answer: CalendarAnswer? = nil, canAnswer: Bool = true, hiding: CalendarCountdownHiding.Scope? = nil, repeats: Bool = true) -> NSMenu {
            CalendarEventMenu.make(answer: answer, canAnswer: canAnswer, hiding: hiding, repeats: repeats, countsDown: true,
                                   onAnswer: { answered = $0 }, onHide: { hidden.append($0) })
        }
        func choose(_ item: NSMenuItem?) { _ = (item?.target as? NSObject)?.perform(item?.action) }
        let shown = menu(answer: .maybe)
        XCTAssertEqual(shown.items.map(\.title), ["Respond", "Hide from tab tooltip"])
        let respond = shown.items[0].submenu!
        XCTAssertEqual(respond.items.map(\.title), ["Yes", "No", "Maybe"]); XCTAssertEqual(respond.items[2].state, .on)
        choose(respond.items[0]); XCTAssertEqual(answered, .yes)
        XCTAssertFalse(menu(canAnswer: false).items[0].isEnabled, "Nothing to answer without an invitation")
        choose(shown.items[1]); XCTAssertEqual(hidden.last, .event)

        let hiding = menu(hiding: .series)
        XCTAssertEqual(hiding.items.map(\.title), ["Respond", "Hide from tab tooltip", "Hiding from tooltip"])
        XCTAssertEqual(hiding.items[1].state, .on)
        let scopes = hiding.items[2].submenu!
        XCTAssertEqual(scopes.items.map(\.title), ["This event", "All events"]); XCTAssertEqual(scopes.items[1].state, .on)
        choose(scopes.items[0]); XCTAssertEqual(hidden.last, .event)
        choose(hiding.items[1]); XCTAssertEqual(hidden.last, .some(nil), "Unchecking shows it again")
        XCTAssertFalse(menu(hiding: .event, repeats: false).items[2].submenu!.items[1].isEnabled, "Only a repeating event has others")
    }

    @MainActor func testAnAnswerShowsAtOnceAndOneCalendarDoesNotTakeIsUndone() async throws {
        let agenda = CalendarAgenda()
        defer { agenda.tearDown() }
        var loads = 0, failNext = true, failed: CalendarEvent?
        agenda.load = { _ in
            loads += 1
            var chip = CalendarDay.Chip(id: "a", title: "Beer", label: "", allDay: false, top: 600, height: 58)
            chip.invited = true; chip.fill = "rgb(255, 255, 255)"
            return [CalendarDay(key: CalendarDay.key(Calendar.current.dateComponents([.year, .month, .day], from: Date())), height: 1440, chips: [chip])]
        }
        agenda.answerer = { _, _, _ in
            try await Task.sleep(for: .milliseconds(50))
            if failNext { failNext = false; throw CalendarPageReader.AnswerFailure.unconfirmed }
        }
        agenda.onAnswerFailed = { event, _ in failed = event }
        agenda.show(CalendarAccount(url: URL(string: "https://calendar.google.com/calendar/u/0/r"))!)
        func wait(_ done: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }
        try await wait { agenda.hasLoaded }
        XCTAssertNil(agenda.events[0].answer)
        agenda.respond(.no, to: agenda.events[0])
        XCTAssertEqual(agenda.events[0].answer, .no, "Shown at once")
        try await wait { failed != nil }
        XCTAssertNil(agenda.events[0].answer, "Calendar didn't take it: the earlier answer is back")
        try await wait { !agenda.isLoading }
        agenda.respond(.yes, to: agenda.events[0])
        let before = loads
        try await wait { loads > before }
        XCTAssertGreaterThan(loads, before, "Once taken, the events are read again from Calendar")
    }

    @MainActor func testTheLoadingShimmerSitsOverItsCentredText() {
        let message = NSTextField(labelWithString: "Loading events"), shimmer = InputShimmer()
        message.font = .systemFont(ofSize: 12); message.alignment = .center
        message.frame = NSRect(x: 0, y: 0, width: 216, height: 16)
        shimmer.configureForSmartRename(field: message); shimmer.frame = message.bounds
        let width = message.attributedStringValue.size().width
        let origin = shimmer.baseline(of: message, font: message.font!, width: width)
        XCTAssertEqual(origin.x+width/2, message.bounds.midX, accuracy: 1, "Centred over the text, not drawn from the left")
    }

    func testOverlappingEventsShareTheWidth() {
        let placed = CalendarSchedule.columns([
            event("a", time(18, 12), time(18, 13)), event("b", time(18, 12, 30), time(18, 13, 45)),
            event("c", time(18, 13, 30), time(18, 16)), event("d", time(18, 17), time(18, 18)),
        ])
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.event.id, ($0.column, $0.columns)) })
        XCTAssertEqual(byID["a"]?.0, 0); XCTAssertEqual(byID["b"]?.0, 1); XCTAssertEqual(byID["c"]?.0, 0)
        XCTAssertEqual(byID["a"]?.1, 2); XCTAssertEqual(byID["c"]?.1, 2)
        XCTAssertEqual(byID["d"]?.0, 0); XCTAssertEqual(byID["d"]?.1, 1)
    }

    @MainActor func testCardShowsEventsAndOpensThem() async throws {
        _ = NSApplication.shared
        let agenda = CalendarAgenda(), card = CalendarTooltip()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(); agenda.tearDown(); window.orderOut(nil) }
        let now = Date(), hour = Calendar.current.dateInterval(of: .hour, for: now)!.start
        agenda.load = { _ in
            let key = CalendarDay.key(Calendar.current.dateComponents([.year, .month, .day], from: now))
            let minute = hour.timeIntervalSince(Calendar.current.startOfDay(for: now))/60
            return [CalendarDay(key: key, height: 1440, chips: [
                CalendarDay.Chip(id: "a", title: "Design review", label: "", allDay: false, top: minute+30, height: 58),
                CalendarDay.Chip(id: "b", title: "Holiday", label: "", allDay: true, top: 0, height: 0)])]
        }
        agenda.onChange = { card.update(agenda) }
        agenda.show(CalendarAccount(url: URL(string: "https://calendar.google.com/calendar/u/0/r"))!)
        card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .neutral)
        XCTAssertEqual(card.message.stringValue, "Loading events")
        let deadline = Date().addingTimeInterval(5)
        while !agenda.hasLoaded, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(card.message.isHidden)
        XCTAssertEqual(card.chips.map(\.event.title), ["Design review"])
        XCTAssertEqual(card.allDayChips.map(\.event.title), ["Holiday"])
        let visible = card.scroll.contentView.bounds
        XCTAssertTrue(visible.intersects(card.chips[0].frame), "The card opens at the hour now")
        var opened: CalendarEvent?
        card.onOpen = { opened = $0 }
        card.chips[0].performClick(nil)
        XCTAssertEqual(opened?.id, "a")
    }
}
