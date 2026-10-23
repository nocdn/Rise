import XCTest
@testable import RiseCore

final class SelectionTimesTests: XCTestCase {
    /// Friday 23 October 2026, 15:00 in London (BST), read on a 24-hour clock.
    let now = Date(timeIntervalSince1970: 1_792_764_000)
    let london = TimeZone(identifier: "Europe/London")!, locale = Locale(identifier: "en_GB")

    func labels(_ text: String) -> [String] {
        let times = SelectionTimes.find(in: text, now: now, local: london)
        return times.map { SelectionTimes.label($0, of: times.count, now: now, local: london, locale: locale) }
    }

    func testSelectedTimesReadInTheirOwnDayAndTheReadersZone() {
        let cases: [(String, [String])] = [
            ("10 a.m. PST", ["18:00 · in 3 hours"]),
            // Tonight in California is tomorrow here.
            ("11pm PST", ["Tomorrow at 07:00 · in 16 hours"]),
            // Today's 8am in Tokyo was 15 hours ago, so it's the next one.
            ("8am JST", ["Tomorrow at 00:00 · in 9 hours"]),
            // No am or pm: a 24-hour clock, not this evening's 9:30.
            ("9:30 CET", ["08:30 · 7 hours ago"]),
            // A zone the system's detector doesn't know.
            ("10am AEST", ["Tomorrow at 00:00 · in 9 hours"]),
            ("noon PDT", ["20:00 · in 5 hours"]),
            ("10–11am PST", ["18:00 – 19:00 · in 3 hours"]),
            ("11:00 AM (GMT-8)", ["20:00 · in 5 hours"]),
            // After the clocks go back: the same offset as UTC, still worth its day.
            ("Mon 26 Oct 2026 10:00 UTC", ["Monday at 10:00 · in 3 days"]),
            // One moment written twice is shown once.
            ("10am PST, 1pm EST, 6pm GMT", ["10am PST → 18:00 · in 3 hours", "6pm GMT → 19:00 · in 4 hours"]),
            ("5pm", []), ("4:30pm BST", []), ("Oct 24", []), ("call me at 5", []), ("version 10.30 released", []),
        ]
        for (text, expected) in cases { XCTAssertEqual(labels(text), expected, text) }
    }

    func testCopiedTimesKeepTheirDateOnceItIsntToday() {
        let cases = [("10am PST", "18:00"), ("11pm PST", "Sat 24 Oct at 07:00"), ("10–11am PST", "18:00 – 19:00")]
        for (text, expected) in cases {
            let time = SelectionTimes.find(in: text, now: now, local: london).first
            XCTAssertEqual(time.map { SelectionTimes.copied($0, now: now, local: london, locale: locale) }, expected, text)
        }
    }
}
