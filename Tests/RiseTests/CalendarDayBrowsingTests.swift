import AppKit
import XCTest
@testable import Rise

@MainActor final class CalendarDayBrowsingTests: XCTestCase {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date()) }
    private let account = CalendarAccount(url: URL(string: "https://calendar.google.com/calendar/u/2/r?authuser=me@example.com"))!
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
    private func snapshot(_ date: Date, allDay: Bool = false) -> CalendarDay {
        CalendarDay(key: CalendarDay.key(calendar.dateComponents([.year, .month, .day], from: date)), height: 1440,
                    chips: [CalendarDay.Chip(id: "\(date.timeIntervalSince1970)", title: "Day \(date.timeIntervalSince1970)", label: "", allDay: allDay, top: 600, height: 58)])
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(4)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func loadedAgenda() async throws -> CalendarAgenda {
        let agenda = CalendarAgenda()
        agenda.load = { _ in [self.snapshot(self.today), self.snapshot(self.day(1))] }
        agenda.loadDay = { _, date in [self.snapshot(date)] }
        agenda.show(account)
        try await wait { agenda.hasLoaded }
        return agenda
    }

    func testBrowsingLoadsRealDaysKeepsCountdownAndCachesTheReturnTrip() async throws {
        let agenda = try await loadedAgenda(); defer { agenda.tearDown() }
        let original = agenda.events, baselineTime = agenda.loadedAt
        var loaded: [Date] = []
        agenda.loadDay = { _, date in loaded.append(date); return [self.snapshot(date)] }
        agenda.selectDay(day(1))
        XCTAssertTrue(agenda.displayedHasLoaded, "Tomorrow was already fetched for the countdown")
        XCTAssertTrue(loaded.isEmpty)
        agenda.selectDay(day(3)); XCTAssertFalse(agenda.displayedHasLoaded)
        try await wait { !agenda.isLoading }
        XCTAssertEqual(loaded, [day(3)])
        XCTAssertEqual(agenda.displayedDay, day(3))
        XCTAssertEqual(agenda.displayedEvents.map(\.id), [snapshot(day(3)).chips[0].id])
        XCTAssertEqual(agenda.events, original, "Browsing must not replace today's countdown data")
        XCTAssertEqual(agenda.loadedAt, baselineTime)
        agenda.selectDay(day(4)); try await wait { !agenda.isLoading }
        agenda.selectDay(day(3)); XCTAssertFalse(agenda.isLoading)
        XCTAssertEqual(loaded, [day(3), day(4)], "Going back uses the cached day")
        agenda.selectDay(today)
        XCTAssertNil(agenda.browsingDay, "Swiping back to today dismisses the date header")
        XCTAssertNil(agenda.browsingDay); XCTAssertEqual(agenda.displayedEvents, original)
    }

    func testQuickSwipesRejectOldResultsAndFailuresDoNotPoisonToday() async throws {
        let agenda = try await loadedAgenda(); defer { agenda.tearDown() }
        agenda.loadDay = { _, date in
            try? await Task.sleep(for: .milliseconds(date == self.day(3) ? 80 : 10))
            return [self.snapshot(date)]
        }
        agenda.selectDay(day(3)); await Task.yield(); agenda.selectDay(day(4))
        try await wait { !agenda.isLoading }
        XCTAssertEqual(agenda.displayedEvents.map(\.id), [snapshot(day(4)).chips[0].id])
        agenda.loadDay = { _, _ in throw CalendarPageReader.Failure.unavailable }
        agenda.selectDay(day(5)); try await wait { !agenda.isLoading }
        XCTAssertNotNil(agenda.error); XCTAssertFalse(agenda.displayedHasLoaded)
        agenda.selectDay(nil)
        XCTAssertNil(agenda.error); XCTAssertTrue(agenda.displayedHasLoaded)
        XCTAssertFalse(agenda.events.isEmpty)
    }

    func testNativeScrollEventsChangeDaysAndKeepAllDayEventsBelowTheDateHeader() async throws {
        let agenda = try await loadedAgenda(), card = CalendarTooltip()
        defer { card.dismiss(animated: false); agenda.tearDown() }
        agenda.loadDay = { _, date in [self.snapshot(date, allDay: true)] }
        agenda.onChange = { card.update(agenda) }
        card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .neutral)
        func scroll(_ phase: Int64, x: Int32 = 0, momentum: Int64 = 0) throws {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: x, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertTrue(event.hasPreciseScrollingDeltas)
            card.scroll.scrollWheel(with: event)
        }
        try scroll(1); try scroll(2, x: 60); try scroll(4)
        let selected = try XCTUnwrap(agenda.browsingDay)
        XCTAssertEqual(abs(calendar.dateComponents([.day], from: today, to: selected).day!), 1)
        try scroll(0, x: 200, momentum: 2)
        XCTAssertEqual(agenda.browsingDay, selected, "The inertial tail must not change another day")
        card.browseDay(by: 3)
        try await wait { !agenda.isLoading }
        XCTAssertEqual(card.allDayChips.count, 1)
        XCTAssertGreaterThan(card.convert(.zero, from: card.scroll).y, CalendarTooltip.navigationHeight, "Date navigation leaves room for the day's all-day events")
        card.todayButton.performClick(nil)
        XCTAssertNil(agenda.browsingDay)
        XCTAssertEqual(card.convert(.zero, from: card.scroll).y, 0)
        XCTAssertFalse(agenda.events.isEmpty)
    }

    func testRefreshFromTheCardsMenuReadsTheShownDayAgain() async throws {
        let agenda = try await loadedAgenda(), card = CalendarTooltip()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(animated: false); agenda.tearDown(); window.orderOut(nil) }
        agenda.onChange = { card.update(agenda) }
        card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .neutral)
        var loaded: [Date] = []
        agenda.loadDay = { _, date in loaded.append(date); return [self.snapshot(date)] }
        card.browseDay(by: 1)
        XCTAssertFalse(loaded.contains(day(1)), "Tomorrow was already read")
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(card.menu(for: click))
        XCTAssertEqual(menu.items.map(\.title), ["Refresh"])
        menu.performActionForItem(at: 0)
        try await wait { loaded.contains(self.day(1)) && !agenda.isLoading }
        XCTAssertEqual(agenda.displayedDay, day(1))
    }

    func testPinchingResizesTheCardWhileItsOpenItsTopMovingAQuarterAsFarAsItsFoot() async throws {
        let agenda = try await loadedAgenda(), card = CalendarTooltip()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(animated: false); agenda.tearDown(); window.orderOut(nil) }
        agenda.onChange = { card.update(agenda) }
        func open() { card.present(key: "test", agenda: agenda, left: 10, anchorTop: 200, maxBottom: 880, theme: .neutral) }
        open()
        let usual = card.frame
        // Midday, with room above and below, whatever the time now.
        card.scroll.contentView.scroll(to: NSPoint(x: 0, y: 400)); card.scroll.reflectScrolledClipView(card.scroll.contentView)
        let hour = card.convert(NSPoint(x: 0, y: 0), from: card.timeline).y
        card.pinch(by: 0.3)
        let grown = card.frame
        XCTAssertGreaterThan(grown.height, usual.height+60)
        XCTAssertEqual(grown.maxY-usual.maxY, 4*(usual.minY-grown.minY), accuracy: 1.5, "The foot moves four times as far as the top")
        XCTAssertEqual(card.convert(NSPoint(x: 0, y: 0), from: card.timeline).y-(usual.minY-grown.minY), hour, accuracy: 0.5, "The timeline stays put")
        card.pinch(by: -0.9)
        XCTAssertEqual(card.frame.height, CalendarTooltip.minimumPinchedHeight, accuracy: 0.5)
        card.dismiss(animated: false); open()
        XCTAssertEqual(card.frame, usual, "Opened again, it's its usual size")
        card.dismiss(animated: false)
        card.present(key: "test", agenda: agenda, left: 10, anchorTop: 40, maxBottom: 880, theme: .neutral, topLimit: 6)
        for _ in 0..<20 { card.pinch(by: 0.3) }
        XCTAssertEqual(card.frame.minY, 6, accuracy: 0.5, "As far from the top as from the sidebar")
        XCTAssertLessThanOrEqual(card.frame.height, CalendarTooltip.maximumPinchedHeight+CalendarTooltip.navigationHeight+0.5)
    }

    func testFailedInvitationAnswerIsRestoredEvenAfterSwipingToAnotherDay() async throws {
        let agenda = try await loadedAgenda(); defer { agenda.tearDown() }
        agenda.loadDay = { _, date in [self.snapshot(date)] }
        agenda.selectDay(day(3)); try await wait { !agenda.isLoading }
        let event = try XCTUnwrap(agenda.displayedEvents.first)
        var failed = false
        agenda.onAnswerFailed = { _, _ in failed = true }
        agenda.answerer = { _, _, _ in
            try await Task.sleep(for: .milliseconds(30))
            throw CalendarPageReader.AnswerFailure.unconfirmed
        }
        agenda.respond(.no, to: event)
        XCTAssertEqual(agenda.displayedEvents.first?.answer, .no)
        agenda.selectDay(day(1))
        try await wait { failed }
        agenda.selectDay(day(3))
        XCTAssertNil(agenda.displayedEvents.first?.answer)
    }

    func testDateHeaderSlidesInAndTodayTucksItAwayWithoutChangingTheVisibleHour() async throws {
        let agenda = try await loadedAgenda(), card = CalendarTooltip()
        // AppKit display links don't tick for a window completely offscreen.
        let window = NSWindow(contentRect: NSRect(x: 150, y: 100, width: 600, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(animated: false); agenda.tearDown(); window.orderOut(nil) }
        agenda.onChange = { card.update(agenda) }
        card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .neutral)
        func timelineTop() -> CGFloat { card.convert(.zero, from: card.scroll).y }
        let y = card.scroll.contentView.bounds.minY
        XCTAssertEqual(timelineTop(), 0)
        card.browseDay(by: 1)
        XCTAssertEqual(card.dayLabel.stringValue, "Tomorrow")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try await Task.sleep(for: .milliseconds(55))
            XCTAssertGreaterThan(timelineTop(), 0)
            XCTAssertLessThan(timelineTop(), CalendarTooltip.navigationHeight)
        }
        try await wait { abs(timelineTop()-CalendarTooltip.navigationHeight) < 0.01 }
        XCTAssertEqual(card.scroll.contentView.bounds.minY, y, accuracy: 0.01)
        card.browseDay(by: -1); XCTAssertEqual(card.dayLabel.stringValue, "Today")
        XCTAssertNil(agenda.browsingDay)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try await Task.sleep(for: .milliseconds(55))
            XCTAssertGreaterThan(timelineTop(), 0)
            XCTAssertLessThan(timelineTop(), CalendarTooltip.navigationHeight)
        }
        try await wait { abs(timelineTop()) < 0.01 }
        XCTAssertEqual(card.frame.height, CalendarTooltip.preferredHeight, accuracy: 0.05)
        card.browseDay(by: 1)
        try await wait { abs(timelineTop()-CalendarTooltip.navigationHeight) < 0.01 }
        card.todayButton.performClick(nil)
        try await wait { abs(timelineTop()) < 0.01 }
        XCTAssertNil(agenda.browsingDay, "The Today button and swiping home use the same view")
    }

    func testDaysSlideInBothDirectionsAndRapidReversalKeepsTheLatestDate() async throws {
        let agenda = try await loadedAgenda(), card = CalendarTooltip()
        let window = NSWindow(contentRect: NSRect(x: 150, y: 100, width: 600, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(animated: false); agenda.tearDown(); window.orderOut(nil) }
        agenda.onChange = { card.update(agenda) }
        card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .dark)
        let body = try XCTUnwrap(card.scroll.superview)
        XCTAssertLessThanOrEqual(CalendarTooltip.navigationHeight, 34)
        XCTAssertNotNil(card.todayButton.image)
        XCTAssertGreaterThan(card.todayButton.layer?.backgroundColor?.alpha ?? 0, 0)
        card.browseDay(by: 1)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(body.frame.minX, CalendarTooltip.width, accuracy: 0.01)
            let outgoing = try XCTUnwrap(body.superview?.subviews.compactMap { $0 as? NSImageView }.first)
            XCTAssertNotNil(outgoing.image)
            XCTAssertNil(outgoing.hitTest(.zero), "Outgoing events cannot take a click")
            card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .dark)
            XCTAssertEqual(body.frame.minX, CalendarTooltip.width, accuracy: 0.01, "Repositioning an open card must not stop its slide")
            try await Task.sleep(for: .milliseconds(45))
            XCTAssertGreaterThan(body.frame.minX, 0)
            XCTAssertLessThan(body.frame.minX, CalendarTooltip.width)
        }
        card.browseDay(by: -1)
        XCTAssertNil(agenda.browsingDay)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertLessThan(body.frame.minX, 0) }
        card.browseDay(by: 2)
        try await wait { !agenda.isLoading && abs(body.frame.minX) < 0.01 }
        XCTAssertEqual(agenda.displayedDay, day(2))
        XCTAssertEqual(card.chips.first?.event.id, snapshot(day(2)).chips.first?.id)
        try await wait { body.superview?.subviews.count == 1 }
        card.browseDay(by: -1)
        card.dismiss(animated: false)
        XCTAssertEqual(body.frame.minX, 0, "Dismissing mid-slide leaves no displaced day")
        card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .neutral)
        XCTAssertEqual(body.frame.minX, 0, "Reopening starts on today without an old slide")
    }

    func testOpeningPrefetchesNeighborsSeriallyAndReusesFreshTomorrow() async throws {
        let agenda = CalendarAgenda(); defer { agenda.tearDown() }
        var active = 0, maximum = 0, fetched: [Date] = []
        agenda.load = { _ in
            active += 1; maximum = max(maximum, active); defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(20))
            return [self.snapshot(self.today), self.snapshot(self.day(1))]
        }
        agenda.loadDay = { _, date in
            active += 1; maximum = max(maximum, active); defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(15))
            fetched.append(date)
            return [self.snapshot(date)]
        }
        agenda.show(account); agenda.beginBrowsing()
        try await wait { fetched.count == 2 }
        XCTAssertEqual(fetched, [day(-1), day(2)])
        XCTAssertEqual(maximum, 1, "Background reads must not navigate the companion concurrently")
        XCTAssertEqual(agenda.displayedDay, today); XCTAssertNil(agenda.error); XCTAssertFalse(agenda.isLoading)
        let original = agenda.events, loadedAt = agenda.loadedAt
        agenda.endBrowsing()
        for date in [day(-1), day(1), day(2)] {
            agenda.selectDay(date)
            XCTAssertTrue(agenda.displayedHasLoaded); XCTAssertFalse(agenda.isLoading)
        }
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(agenda.events, original); XCTAssertEqual(agenda.loadedAt, loadedAt)
        agenda.selectDay(nil); agenda.beginBrowsing(); await Task.yield()
        XCTAssertEqual(fetched.count, 2, "Reopening reuses the fresh neighborhood")
    }

    func testForegroundSwipeInterruptsPrefetchAndClosingRejectsLateResults() async throws {
        let agenda = try await loadedAgenda(); defer { agenda.tearDown() }
        var started: [Date] = [], completed: [Date] = []
        agenda.loadDay = { _, date in
            started.append(date)
            // Simulate even a loader which doesn't cooperate with cancellation.
            try? await Task.sleep(for: .milliseconds(date == self.day(-1) ? 100 : 10))
            completed.append(date)
            return [self.snapshot(date)]
        }
        agenda.beginBrowsing(); try await wait { started == [day(-1)] }
        agenda.selectDay(day(4))
        try await wait { !agenda.isLoading }
        XCTAssertEqual(agenda.displayedEvents.first?.id, snapshot(day(4)).chips.first?.id)
        XCTAssertEqual(Array(started.prefix(2)), [day(-1), day(4)])
        agenda.endBrowsing(); agenda.selectDay(nil)
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(agenda.displayedDay, today); XCTAssertNil(agenda.error)
        let count = started.count
        agenda.selectDay(day(-1))
        XCTAssertFalse(agenda.displayedHasLoaded, "A canceled prefetch cannot populate the cache later")
        try await wait { !agenda.isLoading }
        XCTAssertEqual(started.count, count+1)
        XCTAssertTrue(completed.contains(day(4)))
    }

    func testBackgroundFailureDoesNotHideTodayAndNextNeighborStillLoads() async throws {
        let agenda = try await loadedAgenda(); defer { agenda.tearDown() }
        var fetched: [Date] = []
        agenda.loadDay = { _, date in
            fetched.append(date)
            if date == self.day(-1) { throw CalendarPageReader.Failure.unavailable }
            return [self.snapshot(date)]
        }
        agenda.beginBrowsing(); try await wait { fetched.count == 2 }
        agenda.endBrowsing()
        XCTAssertNil(agenda.error); XCTAssertFalse(agenda.isLoading); XCTAssertTrue(agenda.displayedHasLoaded)
        agenda.selectDay(day(2)); XCTAssertTrue(agenda.displayedHasLoaded)
    }

    func testWindowRoutesCalendarSwipesBeforePageHistoryAndKeepsTheirMomentum() async throws {
        let agenda = try await loadedAgenda()
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        let window = try XCTUnwrap(browser.window as? BrowserWindow)
        let page = BlankPage(); page.scriptAnswer = { $0 == HistorySwipeController.scrollProbe ? true : nil }
        browser.addTab(url: URL(string: "about:blank")!, page: page); window.makeKeyAndOrderFront(nil)
        let card = browser.tabHoverCards.calendarCard
        browser.root.addSubview(card)
        agenda.onChange = { card.update(agenda) }
        card.present(key: "test", agenda: agenda, left: 320, anchorTop: 100, maxBottom: browser.root.bounds.height-8, theme: .neutral)
        defer {
            card.dismiss(animated: false); agenda.tearDown(); browser.historySwipe.cancel()
            browser.saveWork?.cancel(); browser.suggestionFavicons.cancel(); window.orderOut(nil)
        }
        var navigations = 0
        // Keep the native window's production routing, with a deterministic
        // page lookup even when XCTest's process isn't the key application.
        browser.historySwipe = HistorySwipeController(window: window, pageAt: { _ in page }, feedback: { _, _, _, _ in })
        browser.historySwipe.canNavigate = { _, _ in true }
        browser.historySwipe.navigate = { _, _ in navigations += 1 }
        let route = try XCTUnwrap(window.historyScrollEvent)
        let inside = card.convert(NSPoint(x: 130, y: 120), to: nil)
        let outside = browser.root.convert(NSPoint(x: browser.root.bounds.maxX-80, y: browser.root.bounds.maxY-80), to: nil)
        func event(_ phase: Int64, x: Int32 = 0, y: Int32 = 0, momentum: Int64 = 0, at point: NSPoint) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            // An unposted CGEvent has no window. Express the desired window
            // coordinates in its flipped screen space before calling the router.
            cg.location = .zero
            let origin = try XCTUnwrap(NSEvent(cgEvent: cg)).locationInWindow
            cg.location = CGPoint(x: point.x-origin.x, y: origin.y-point.y)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        XCTAssertFalse(route(try event(1, at: inside)), "An undecided delta is left to native dispatch, without starting page history")
        XCTAssertFalse(browser.historySwipe.isActive)
        XCTAssertTrue(route(try event(2, x: 60, at: inside)))
        var selected = agenda.displayedDay
        XCTAssertNotEqual(selected, today)
        XCTAssertTrue(route(try event(4, at: inside)))
        XCTAssertTrue(route(try event(0, x: 300, momentum: 2, at: outside)))
        XCTAssertTrue(route(try event(0, momentum: 3, at: outside)))
        XCTAssertEqual(agenda.displayedDay, selected); XCTAssertEqual(navigations, 0)
        XCTAssertFalse(browser.historySwipe.isActive)
        XCTAssertTrue(route(try event(1, x: -60, at: inside)))
        XCTAssertEqual(agenda.displayedDay, today, "The reverse swipe returns from tomorrow to today")
        XCTAssertTrue(route(try event(4, at: inside)))
        XCTAssertTrue(route(try event(1, x: -60, at: inside)))
        XCTAssertEqual(agenda.displayedDay, day(-1), "Backwards swipes continue into yesterday without page navigation")
        XCTAssertTrue(route(try event(4, at: inside)))
        selected = agenda.displayedDay
        XCTAssertEqual(navigations, 0)
        XCTAssertFalse(route(try event(1, y: -30, at: inside)), "Vertical scrolling is left to native dispatch")
        XCTAssertFalse(route(try event(2, y: -30, at: inside)))
        XCTAssertFalse(route(try event(4, at: inside)))
        XCTAssertFalse(browser.historySwipe.isActive)
        XCTAssertEqual(agenda.displayedDay, selected)
        // Start a genuine page swipe, then move onto the calendar before release.
        XCTAssertTrue(route(try event(1, x: 150, at: outside)))
        try await wait { browser.historySwipe.gesture.isArmed }
        XCTAssertTrue(route(try event(2, x: 60, at: inside)))
        XCTAssertFalse(browser.historySwipe.isActive, "The card cancels an in-flight history probe or swipe")
        XCTAssertTrue(route(try event(4, at: outside)))
        XCTAssertEqual(navigations, 0)
        // A new gesture outside still navigates normally.
        XCTAssertTrue(route(try event(1, x: 150, at: outside)))
        try await wait { browser.historySwipe.gesture.isArmed }
        XCTAssertTrue(route(try event(4, at: outside)))
        XCTAssertEqual(navigations, 1)
    }

    func testTheReaderVisitsTheRequestedDayWithoutMovingTheUsersCalendarTab() async throws {
        let reader = CalendarPageReader(), source = BlankPage(), host = NSView()
        source.load(account.url(view: "week", day: calendar.dateComponents([.year, .month, .day], from: today)))
        let original = source.url
        reader.prepare(source: source, host: host); defer { reader.tearDown() }
        let companion = try XCTUnwrap(reader.companion as? BlankPage)
        let wanted = day(5), key = CalendarDay.key(calendar.dateComponents([.year, .month, .day], from: wanted))
        companion.scriptAnswer = { body in body.contains("const columns =") ? ["ready": true, "key": key, "height": 1440, "chips": []] : nil }
        let read = try await reader.loadDay(account, wanted)
        XCTAssertEqual(read.map(\.key), [key])
        XCTAssertEqual(companion.url, account.url(view: "day", day: calendar.dateComponents([.year, .month, .day], from: wanted)))
        XCTAssertEqual(source.url, original)
    }

    func testRelativeDateLabelsAndCalendarDayArithmeticAcrossDST() {
        var uk = Calendar(identifier: .gregorian); uk.timeZone = TimeZone(identifier: "Europe/London")!
        let start = uk.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        let next = uk.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(next.timeIntervalSince(start), 25*3600)
        XCTAssertEqual(CalendarTooltip.dayTitle(start, now: start, calendar: uk), "Today")
        XCTAssertEqual(CalendarTooltip.dayTitle(next, now: start, calendar: uk), "Tomorrow")
        XCTAssertEqual(CalendarTooltip.dayTitle(start, now: next, calendar: uk), "Yesterday")
        XCTAssertFalse(CalendarTooltip.dayTitle(uk.date(byAdding: .day, value: 3, to: start)!, now: start, calendar: uk).isEmpty)
    }
}

final class CalendarDaySwipeTests: XCTestCase {
    func testOneDayPerSwipeAndMomentumNeverSkipsExtraDays() {
        var swipe = CalendarDaySwipe()
        XCTAssertNil(swipe.handle(dx: -20, dy: 0, phase: .began, timestamp: 0).day)
        XCTAssertEqual(swipe.handle(dx: -35, dy: 0, phase: .changed, timestamp: 0.1).day, 1)
        XCTAssertNil(swipe.handle(dx: -100, dy: 0, phase: .changed, timestamp: 0.8).day, "Pausing with fingers down is still the same gesture")
        XCTAssertTrue(swipe.handle(dx: 0, dy: 0, phase: .ended, timestamp: 0.9).consumed)
        XCTAssertNil(swipe.handle(dx: -300, dy: 0, phase: [], momentum: .changed, timestamp: 1).day)
        XCTAssertEqual(swipe.handle(dx: 60, dy: 0, phase: .began, timestamp: 2).day, -1)
    }
    func testVerticalAndMouseScrollingStayNativeAndCancelledSwipesReset() {
        var swipe = CalendarDaySwipe()
        XCTAssertFalse(swipe.handle(dx: 2, dy: 18, phase: .began, timestamp: 0).consumed)
        XCTAssertFalse(swipe.handle(dx: 70, dy: 30, phase: .changed, timestamp: 0.1).consumed)
        XCTAssertFalse(swipe.handle(dx: 0, dy: 100, phase: [], momentum: .changed, timestamp: 0.2).consumed)
        XCTAssertFalse(swipe.handle(dx: 100, dy: 0, phase: .began, precise: false, timestamp: 1).consumed)
        XCTAssertNil(swipe.handle(dx: -20, dy: 0, phase: .began, timestamp: 2).day)
        XCTAssertTrue(swipe.handle(dx: 0, dy: 0, phase: .cancelled, timestamp: 2.1).consumed)
        XCTAssertNil(swipe.handle(dx: -35, dy: 0, phase: .began, timestamp: 3).day)
    }
}
