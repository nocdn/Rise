import XCTest
@testable import RiseCore

final class SelectionEventsTests: XCTestCase {
    /// Tuesday 27 October 2026, 10:00 in London (GMT, the clocks having gone back on Sunday).
    let now = Date(timeIntervalSince1970: 1_793_095_200)
    let london = TimeZone(identifier: "Europe/London")!, locale = Locale(identifier: "en_GB")

    func event(_ text: String, page: String? = nil) -> SelectionEvent? {
        SelectionEvents.find(in: text, pageTitle: page, now: now, local: london)
    }

    /// "2026-11-03 13:30 – 2026-11-03 20:30", or "2026-11-03 – 2026-11-05 all day" with the last day, in London.
    func when(_ event: SelectionEvent?) -> String? {
        guard let event else { return nil }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = london
        if event.isAllDay {
            format.dateFormat = "yyyy-MM-dd"
            return "\(format.string(from: event.start)) – \(format.string(from: event.end.addingTimeInterval(-1))) all day"
        }
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(format.string(from: event.start)) – \(format.string(from: event.end))" + (event.hasEnd ? "" : " assumed")
    }

    func testTheEmailInvitationFromTheRequest() throws {
        let text = """
        Event details
        Date: Tuesday, November 3, 2026
        Time: 13:30 - 20:30
        Location: Corner Corner, Maritime St, Canada Water, London SE16 7LL, United Kingdom
        """
        let found = try XCTUnwrap(event(text, page: "OpenAI DevDay Exchange: London - me@example.com - Gmail"))
        XCTAssertEqual(when(found), "2026-11-03 13:30 – 2026-11-03 20:30")
        XCTAssertEqual(found.title, "OpenAI DevDay Exchange: London")
        XCTAssertEqual(found.location, "Corner Corner, Maritime St, Canada Water, London SE16 7LL, United Kingdom")
        XCTAssertNil(found.timeZone)
        XCTAssertFalse(found.isAllDay)
        XCTAssertEqual(found.notes, text)
        XCTAssertEqual(SelectionEvents.label(found, now: now, local: london, locale: locale), "Tue 3 Nov, 13:30 – 20:30")
    }

    func testTheWholeEmailNamesTheEventFromItsSentence() throws {
        let text = """
        Hi Bartek,

        We’re looking forward to seeing you next week at OpenAI DevDay Exchange: London. You can find the essential details you need to know below, including an overview of the program.

        Event details
        Date: Tuesday, November 3, 2026
        Time: 13:30 - 20:30
        Location: Corner Corner, Maritime St, Canada Water, London SE16 7LL, United Kingdom

        When you exit Canada Water Station, cross the red bridge. The venue will be directly in front of you.

        Check-in instructions: Please arrive with your photo ID, and our team will direct you to the event space.
        """
        let found = try XCTUnwrap(event(text, page: "Inbox (3) - me@example.com - Gmail"))
        XCTAssertEqual(found.title, "OpenAI DevDay Exchange: London")
        XCTAssertEqual(when(found), "2026-11-03 13:30 – 2026-11-03 20:30")
        XCTAssertEqual(found.location, "Corner Corner, Maritime St, Canada Water, London SE16 7LL, United Kingdom")
    }

    func testCommonEventFormats() {
        let cases: [(String, String)] = [
            // Labels alone on their line, as Luma and Eventbrite set them out.
            ("When\nTuesday 3 November\n13:30 - 20:30\nWhere\nCorner Corner", "2026-11-03 13:30 – 2026-11-03 20:30"),
            ("Date and time\nTue, 3 Nov 2026 18:00 - 21:00 GMT\nLocation\nThe Old Bar\n12 Fake Street\nLondon E1 6AN", "2026-11-03 18:00 – 2026-11-03 21:00"),
            ("Starts: 3 Nov 2026 13:30\nEnds: 3 Nov 2026 20:30", "2026-11-03 13:30 – 2026-11-03 20:30"),
            ("Starts: 3 Nov 2026 22:00\nEnds: 4 Nov 2026 02:00", "2026-11-03 22:00 – 2026-11-04 02:00"),
            ("Tuesday 3 Nov 2026 ⋅ 13:30 – 14:00 (Greenwich Mean Time - London)", "2026-11-03 13:30 – 2026-11-03 14:00"),
            ("Tuesday, November 3, 2026 1:30 PM-8:30 PM", "2026-11-03 13:30 – 2026-11-03 20:30"),
            ("Nov 3 from 2pm to 5pm", "2026-11-03 14:00 – 2026-11-03 17:00"),
            ("Tuesday 3rd November 2026 between 2pm and 4pm", "2026-11-03 14:00 – 2026-11-03 16:00"),
            ("3rd November 2026, 7pm", "2026-11-03 19:00 – 2026-11-03 20:00 assumed"),
            ("Thu 5 Nov 2026 7.30pm", "2026-11-05 19:30 – 2026-11-05 20:30 assumed"),
            ("3 November 2026, 19h00 - 23h00", "2026-11-03 19:00 – 2026-11-03 23:00"),
            ("Sat 14 Nov · 19:00–23:00", "2026-11-14 19:00 – 2026-11-14 23:00"),
            ("Saturday 14 Nov | 13.30–20.30", "2026-11-14 13:30 – 2026-11-14 20:30"),
            ("Dec 31 at 11pm", "2026-12-31 23:00 – 2027-01-01 00:00 assumed"),
            ("Nov 3 @ 7pm", "2026-11-03 19:00 – 2026-11-03 20:00 assumed"),
            ("2026-11-03T13:30:00Z", "2026-11-03 13:30 – 2026-11-03 14:30 assumed"),
            // A time on the line before its date.
            ("13:30 – 20:30\nTuesday 3 November 2026", "2026-11-03 13:30 – 2026-11-03 20:30"),
        ]
        for (text, expected) in cases { XCTAssertEqual(when(event(text)), expected, text) }
    }

    func testRangesSettleAmAndPm() {
        let cases: [(String, String)] = [
            ("Nov 3, 1:30-8:30pm", "2026-11-03 13:30 – 2026-11-03 20:30"),
            ("Nov 3, 11-1pm", "2026-11-03 11:00 – 2026-11-03 13:00"),
            ("Lunch 12-1pm Thursday", "2026-10-29 12:00 – 2026-10-29 13:00"),
            ("Nov 3, 10am-2", "2026-11-03 10:00 – 2026-11-03 14:00"),
            ("Nov 3, 9:00-5:00", "2026-11-03 09:00 – 2026-11-03 17:00"),
            ("Nov 3, 6:30 p.m. – 9 p.m.", "2026-11-03 18:30 – 2026-11-03 21:00"),
            ("Nov 3, noon to 2pm", "2026-11-03 12:00 – 2026-11-03 14:00"),
            // An evening that runs past midnight ends the next day.
            ("22:00 - 02:00 Friday 30 October", "2026-10-30 22:00 – 2026-10-31 02:00"),
            ("Friday 30 October, 10pm until 3am", "2026-10-30 22:00 – 2026-10-31 03:00"),
        ]
        for (text, expected) in cases { XCTAssertEqual(when(event(text)), expected, text) }
    }

    func testDaysWithoutTimesAreAllDay() {
        let cases: [(String, String)] = [
            ("Tuesday, November 3, 2026", "2026-11-03 – 2026-11-03 all day"),
            ("November 3–5, 2026", "2026-11-03 – 2026-11-05 all day"),
            ("Fri 6 Nov – Sun 8 Nov 2026", "2026-11-06 – 2026-11-08 all day"),
            ("Monday 2 November 2026 to Wednesday 4 November 2026", "2026-11-02 – 2026-11-04 all day"),
            ("Nov 30 – Dec 2", "2026-11-30 – 2026-12-02 all day"),
            ("Dec 31 – Jan 2", "2026-12-31 – 2027-01-02 all day"),
            ("Start date: 3 November 2026\nEnd date: 5 November 2026", "2026-11-03 – 2026-11-05 all day"),
        ]
        for (text, expected) in cases { XCTAssertEqual(when(event(text)), expected, text) }
    }

    func testAWrittenWeekdaySettlesTheYear() {
        XCTAssertEqual(when(event("Tuesday, November 3")), "2026-11-03 – 2026-11-03 all day")
        // 3 November is a Wednesday next year.
        XCTAssertEqual(when(event("Wednesday, November 3")), "2027-11-03 – 2027-11-03 all day")
        // Already past this year: next year's.
        XCTAssertEqual(when(event("Fri 1 Jan")), "2027-01-01 – 2027-01-01 all day")
    }

    func testRelativeDaysAndTimesWithoutADay() {
        XCTAssertEqual(when(event("tomorrow at 3pm")), "2026-10-28 15:00 – 2026-10-28 16:00 assumed")
        XCTAssertEqual(when(event("Dinner with Sam on Friday at 7pm")), "2026-10-30 19:00 – 2026-10-30 20:00 assumed")
        XCTAssertEqual(when(event("tonight at 8")), "2026-10-27 20:00 – 2026-10-27 21:00 assumed")
        // Today's, still to come.
        XCTAssertEqual(when(event("Standup at 16:00")), "2026-10-27 16:00 – 2026-10-27 17:00 assumed")
        // Today's has been and gone: tomorrow's.
        XCTAssertEqual(when(event("Standup at 08:00")), "2026-10-28 08:00 – 2026-10-28 09:00 assumed")
        XCTAssertEqual(when(event("Time: 13:30 - 20:30")), "2026-10-27 13:30 – 2026-10-27 20:30")
    }

    func testZonesWrittenWithTheTime() throws {
        let pacific = try XCTUnwrap(event("Wed, Nov 4, 2026 9:00 AM – 10:00 AM (PST)"))
        XCTAssertEqual(when(pacific), "2026-11-04 17:00 – 2026-11-04 18:00")
        XCTAssertEqual(pacific.timeZone?.identifier, "America/Los_Angeles")

        let eastern = try XCTUnwrap(event("Date: Tuesday, November 3, 2026\nTime: 1:30 PM – 8:30 PM ET"))
        XCTAssertEqual(when(eastern), "2026-11-03 18:30 – 2026-11-04 01:30")
        XCTAssertEqual(eastern.timeZone?.identifier, "America/New_York")
        XCTAssertEqual(SelectionEvents.label(eastern, now: now, local: london, locale: locale), "Tue 3 Nov, 18:30 – 01:30")

        let berlin = try XCTUnwrap(event("3 November 2026 at 6:30 PM CET"))
        XCTAssertEqual(when(berlin), "2026-11-03 17:30 – 2026-11-03 18:30 assumed")

        let outlook = try XCTUnwrap(event("When: Wednesday, November 4, 2026 9:00 AM-10:00 AM (UTC-08:00) Pacific Time (US & Canada)\nWhere: Microsoft Teams Meeting"))
        XCTAssertEqual(when(outlook), "2026-11-04 17:00 – 2026-11-04 18:00")
        XCTAssertEqual(outlook.location, "Microsoft Teams Meeting")

        let named = try XCTUnwrap(event("Nov 5, 2026, 10:00 – 11:00 Pacific Time"))
        XCTAssertEqual(named.timeZone?.identifier, "America/Los_Angeles")
        XCTAssertEqual(when(named), "2026-11-05 18:00 – 2026-11-05 19:00")

        // The person's own zone, written out: nothing to note.
        // One moment in several zones: the person's own.
        let webinar = try XCTUnwrap(event("Date: Thursday, Nov 12, 2026\nTime: 10:00 AM PT / 1:00 PM ET / 6:00 PM GMT"))
        XCTAssertEqual(when(webinar), "2026-11-12 18:00 – 2026-11-12 19:00 assumed")
        XCTAssertNil(webinar.timeZone)
        // "from 6:30pm" names no end.
        XCTAssertEqual(when(event("Thursday, 12 November from 6:30pm")), "2026-11-12 18:30 – 2026-11-12 19:30 assumed")
        XCTAssertEqual(when(event("Doors 19:00 / Show 20:00\nSaturday 14 November 2026")), "2026-11-14 19:00 – 2026-11-14 20:00 assumed")
        XCTAssertNil(event("Tue, 3 Nov 2026 18:00 - 21:00 GMT")?.timeZone)
        XCTAssertNil(event("Tuesday 3 Nov 2026 ⋅ 13:30 – 14:00 (Greenwich Mean Time - London)")?.timeZone)
        XCTAssertNil(event("Nov 3, 2026 01:30 PM London")?.timeZone)
        let tokyo = try XCTUnwrap(event("Time zone: Asia/Tokyo\nDate: 5 Nov 2026\nTime: 09:00"))
        XCTAssertEqual(tokyo.timeZone?.identifier, "Asia/Tokyo")
        XCTAssertEqual(when(tokyo), "2026-11-05 00:00 – 2026-11-05 01:00 assumed")
    }

    func testTitles() {
        let cases: [(String, String?, String)] = [
            ("Dinner with Sam on Friday at 7pm", nil, "Dinner with Sam"),
            ("Team offsite\nNovember 3–5, 2026", nil, "Team offsite"),
            ("Event: Launch Party\nDate: 5 Nov 2026\nTime: 6pm–9pm", nil, "Launch Party"),
            ("What: Book club\nWhen: Thursday at 7pm", nil, "Book club"),
            ("You’re invited to the Winter Showcase on Friday 6 November at 6pm.", nil, "Winter Showcase"),
            ("Your tickets for Hamilton\nSat 14 Nov 2026, 19:30", nil, "Hamilton"),
            ("Event details\nDate: Nov 3, 2026", "Invitation: Product sync @ Tue 3 Nov 2026 13:30 - 14:00 (GMT) (me@example.com) - me@example.com - Gmail", "Product sync"),
            ("Date: Nov 3, 2026", "Fwd: Re: Quarterly review | Proton Mail", "Quarterly review"),
            ("Date: Nov 3, 2026", "(2) Big Night Out · Luma", "Big Night Out"),
            ("Event details\nDate: Tuesday, November 3, 2026", "See you next week at OpenAI DevDay Exchange: London! - me@example.com - Gmail", "OpenAI DevDay Exchange: London"),
            ("Hi Sam,\nDate: Nov 3, 2026", "me@example.com - Gmail", "New Event"),
            ("Nov 3, 2026\nLocation: The Old Bar, London", nil, "The Old Bar"),
            ("Join us for our Autumn Mixer on Thursday, 12 November from 6:30pm", nil, "Autumn Mixer"),
            ("Your reservation at Dishoom Shoreditch is confirmed for Saturday 31 October at 19:45 for 4 people.", nil, "Dishoom Shoreditch"),
            ("Webinar: Scaling Postgres\nDate: Thursday, Nov 12, 2026\nTime: 10:00 AM PT / 1:00 PM ET / 6:00 PM GMT", nil, "Scaling Postgres"),
            ("Updated Oct 25, 2026, 10:41 AM", "Release notes - Docs", "Release notes"),
        ]
        for (text, page, expected) in cases { XCTAssertEqual(event(text, page: page)?.title, expected, text) }
    }

    func testPlaces() throws {
        XCTAssertEqual(event("Date and time\nTue, 3 Nov 2026 18:00 - 21:00 GMT\nLocation\nThe Old Bar\n12 Fake Street\nLondon E1 6AN\nShow map")?.location,
                       "The Old Bar, 12 Fake Street, London E1 6AN")
        XCTAssertEqual(event("Venue: Brixton Academy (map)\nDate: Sat 14 Nov 2026, 7pm")?.location, "Brixton Academy")
        XCTAssertNil(event("Location: TBA\nDate: Sat 14 Nov 2026, 7pm")?.location)
        XCTAssertEqual(event("Join us on Thursday, 12 November from 6:30pm at The Ivy, 1-5 West St, London WC2H 9NQ")?.location,
                       "The Ivy, 1-5 West St, London WC2H 9NQ")
        XCTAssertEqual(event("Appointment confirmed\nMonday 2 November 2026 at 09:15\nCity Dental, 22 High St, Bristol BS1 2AW")?.location,
                       "City Dental, 22 High St, Bristol BS1 2AW")
        XCTAssertEqual(event("Drinks on Friday 30 October at 6pm\n1 Infinite Loop, Cupertino, CA 95014")?.location, "1 Infinite Loop, Cupertino, CA 95014")

        let call = try XCTUnwrap(event("Product sync\nTuesday 3 Nov 2026 ⋅ 13:30 – 14:00\nJoin with Google Meet\nhttps://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(call.meetingURL?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(call.location, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(call.title, "Product sync")
        // A video call beside a place: the place is where it is.
        let both = try XCTUnwrap(event("Where: Room 4.02, 1 Granary Square\nhttps://zoom.us/j/123456789\nWhen: 5 Nov 2026, 10:00–11:00"))
        XCTAssertEqual(both.location, "Room 4.02, 1 Granary Square")
        XCTAssertEqual(both.meetingURL?.host, "zoom.us")
        XCTAssertEqual(when(both), "2026-11-05 10:00 – 2026-11-05 11:00")
    }

    func testTextWithoutAnEvent() {
        for text in ["Version 2.10 released", "Call me on 07700 900123", "John 3:16", "Room 1430", "It costs £12.50",
                     "Chapter 3-5", "Mon-Fri 9-5", "UTC+14:00", "Hello world", "", "   ", "The 1990s were great",
                     "Order #12345", "Scored 3:2 in extra time"] {
            XCTAssertNil(event(text), text)
        }
        XCTAssertNil(event(String(repeating: "Nov 3 at 7pm. ", count: 300)))
    }

    func testLabels() throws {
        func label(_ text: String) -> String? {
            event(text).map { SelectionEvents.label($0, now: now, local: london, locale: locale) }
        }
        XCTAssertEqual(label("tomorrow at 3pm"), "Tomorrow, 15:00")
        XCTAssertEqual(label("Standup at 16:00"), "Today, 16:00")
        XCTAssertEqual(label("Tuesday, November 3, 2026"), "Tue 3 Nov")
        XCTAssertEqual(label("November 3–5, 2026"), "Tue 3 Nov – Thu 5 Nov")
        XCTAssertEqual(label("Dec 31 – Jan 2"), "Thu, 31 Dec 2026 – Sat, 2 Jan 2027")
        XCTAssertEqual(label("Wednesday, November 3"), "Wed, 3 Nov 2027")
        XCTAssertEqual(label("Starts: 3 Nov 2026 09:00\nEnds: 5 Nov 2026 17:00"), "Tue 3 Nov, 09:00 – Thu 5 Nov, 17:00")
    }

    func testGoogleCalendarLink() throws {
        let found = try XCTUnwrap(event("Date: Tuesday, November 3, 2026\nTime: 13:30 - 20:30\nLocation: Corner Corner, London", page: "DevDay + friends - Gmail"))
        let url = SelectionEvents.googleCalendarURL(found, base: URL(string: "https://calendar.google.com/calendar/u/1/?authuser=1"), sourceURL: URL(string: "https://mail.google.com/mail/u/0/#inbox/1"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/calendar/u/1/r/eventedit")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["authuser"], "1")
        XCTAssertEqual(items["text"], "DevDay + friends")
        XCTAssertEqual(items["dates"], "20261103T133000Z/20261103T203000Z")
        XCTAssertEqual(items["location"], "Corner Corner, London")
        XCTAssertTrue(items["details"]?.hasSuffix("https://mail.google.com/mail/u/0/#inbox/1") == true)
        XCTAssertTrue(url.absoluteString.contains("DevDay%20%2B%20friends"))
    }
}
