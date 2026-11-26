import XCTest
@testable import Rise

@MainActor final class PersonCalendarTests: XCTestCase {
    func testTheirDayReadsAsTheCardShowsIt() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let items: [[String: Any]] = [
            ["id": "office", "summary": "Office", "eventType": "workingLocation", "start": ["date": "2026-11-26"], "end": ["date": "2026-11-27"]],
            ["id": "gone", "summary": "Moved", "status": "cancelled", "start": ["dateTime": "2026-11-26T08:00:00Z"], "end": ["dateTime": "2026-11-26T09:00:00Z"]],
            ["id": "shared_20261126T090000Z", "start": ["dateTime": "2026-11-26T09:00:00Z"], "end": ["dateTime": "2026-11-26T09:45:00Z"]],
            ["id": "hidden", "start": ["dateTime": "2026-11-26T10:00:00.000+00:00"], "end": ["dateTime": "2026-11-26T13:00:00Z"]],
            ["id": "review", "summary": " Design review ", "colorId": "3", "answer": "declined",
             "description": "Agenda:<br>Specs &amp; <b>timeline</b>", "start": ["dateTime": "2026-11-26T14:00:00Z"], "end": ["dateTime": "2026-11-26T15:00:00Z"]],
            ["id": "invite", "summary": "Interview", "answer": "needsAction", "start": ["dateTime": "2026-11-26T16:00:00Z"], "end": ["dateTime": "2026-11-26T16:30:00Z"]],
            ["id": "holiday", "summary": "Holiday", "start": ["date": "2026-11-26"], "end": ["date": "2026-11-27"]],
        ]
        let events = PersonCalendarEvents.events(items, own: ["shared_20261126T090000Z": "Team meeting"], email: "dkezi@example.com", calendar: calendar)
        XCTAssertEqual(events.map(\.title), ["Holiday", "Team meeting", "Busy", "Design review", "Interview"],
                       "All day first; your own title for a meeting you share; working location and cancelled events left out")
        XCTAssertEqual(events[0].start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 26)))
        XCTAssertTrue(events[0].allDay)
        XCTAssertEqual(events[2].end.timeIntervalSince(events[2].start), 3*3600)
        XCTAssertEqual(events.map(\.color), [0xF09300, 0xF09300, 0xF09300, 0x8E24AA, 0xF09300])
        XCTAssertEqual(events[3].answer, .no)
        XCTAssertEqual(events[3].description, "Agenda:\nSpecs & timeline")
        XCTAssertEqual(events[4].invited, true); XCTAssertNil(events[4].answer)
        XCTAssertEqual(CalendarEvent.decoded(events[1].id)?.event, "shared_20261126T090000Z")
        XCTAssertEqual(CalendarEvent.decoded(events[1].id)?.calendar, "dkezi@example.com")
    }

    func testThePagesGoogleAccountIsTheirs() {
        XCTAssertEqual(CalendarPerson.authUser(of: URL(string: "https://chat.google.com/u/1/app/home")), 1)
        XCTAssertEqual(CalendarPerson.authUser(of: URL(string: "https://mail.google.com/mail/u/0/?authuser=2#inbox")), 2)
        XCTAssertEqual(CalendarPerson.authUser(of: URL(string: "https://chat.google.com/app/home")), 0)
        XCTAssertNotEqual(CalendarPerson(email: "a@example.com", authUser: 0).account, CalendarPerson(email: "a@example.com", authUser: 1).account)
    }
}
