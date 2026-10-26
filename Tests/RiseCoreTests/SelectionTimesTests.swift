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

    func testZoneOnlySelectionsShowCurrentTimeThereAndTheDifferenceFromHere() throws {
        let cases: [(String, Int, String)] = [
            ("UTC+14:00", 14*3600, "Tomorrow at 04:00 there · 13 hours ahead"),
            ("UTC−12:00", -12*3600, "02:00 there · 13 hours behind"),
            ("utc + 5:45", 5*3600+45*60, "19:45 there · 4 hr 45 min ahead"),
            ("GMT–0330", -(3*3600+30*60), "10:30 there · 4 hr 30 min behind"),
            ("(GMT+1)", 3600, "15:00 there · same time as here"),
            ("UTC+00:30", 1800, "14:30 there · 30 min behind"),
            ("GMT-0", 0, "14:00 there · 1 hour behind"),
            ("UTC\u{00a0}+\u{202f}0545.", 5*3600+45*60, "19:45 there · 4 hr 45 min ahead"),
        ]
        for (text, offset, expected) in cases {
            let times = SelectionTimes.find(in: text, now: now, local: london)
            XCTAssertEqual(times.count, 1, text)
            let time = try XCTUnwrap(times.first)
            XCTAssertTrue(time.isZoneOnly, text)
            XCTAssertEqual(time.start, now, text)
            XCTAssertNil(time.end, text)
            XCTAssertEqual(time.zone.secondsFromGMT(for: now), offset, text)
            XCTAssertEqual(labels(text), [expected], text)
        }
    }

    func testOffsetsWithinTheScreenshotSubtitleKeepTheirOrderAndDistinctZones() {
        let text = "Live UTC clock showing the current Coordinated Universal Time, today's UTC date, and the current time in every UTC offset from UTC−12:00 to UTC+14:00."
        XCTAssertEqual(labels(text), ["UTC−12:00 → 02:00 there · 13 hours behind", "UTC+14:00 → Tomorrow at 04:00 there · 13 hours ahead"])
        XCTAssertEqual(SelectionTimes.find(in: "UTC+14:00 GMT+1400 UTC+14", now: now, local: london).count, 1)
        XCTAssertEqual(SelectionTimes.find(in: "🌎 UTC+14 UTC−12 GMT+5:45 UTC+1", now: now, local: london).map(\.written), ["UTC+14", "UTC−12", "GMT+5:45"])
    }

    func testAnOffsetAttachedToAClockIsUsedOnceAsItsZone() throws {
        for text in ["10:30 UTC+14:00", "UTC+14:00 10:30", "10:30 (utc + 14:00)", "UTC+1400 10:30"] {
            let times = SelectionTimes.find(in: text, now: now, local: london)
            XCTAssertEqual(times.count, 1, text)
            XCTAssertEqual(times.first?.isZoneOnly, false, text)
            XCTAssertEqual(times.first?.zone.secondsFromGMT(for: now), 14*3600, text)
            XCTAssertEqual(labels(text), ["21:30 · in 7 hours"], text)
        }
        let mixed = SelectionTimes.find(in: "10am PST, UTC+14:00", now: now, local: london)
        XCTAssertEqual(mixed.map(\.isZoneOnly), [false, true])
        let range = SelectionTimes.find(in: "10–11am UTC+14:00", now: now, local: london)
        XCTAssertEqual(range.count, 1)
        let start = try XCTUnwrap(range.first)
        XCTAssertEqual(start.end?.timeIntervalSince(start.start), 3600)
    }

    func testMalformedOffsetsDoNotBecomeTimesOrFallBackToUTC() {
        for offset in ["UTC+14:01", "GMT−14:30", "UTC+15", "UTC+05:60", "UTC+5:5", "UTC+14000", "UTC+14:00:30", "UTC+00:300", "UTC+14:00junk", "UTC+14.5", "UTC+14:", "UTC+"] {
            XCTAssertTrue(SelectionTimes.find(in: offset, now: now, local: london).isEmpty, offset)
            XCTAssertTrue(SelectionTimes.find(in: "10:30 "+offset, now: now, local: london).isEmpty, offset)
        }
        for text in ["UTC+14.5", "UTC+14:00junk", "buildUTC+14:00", "GMT", "PST", "14:00", String(repeating: "x", count: 400)+"UTC+14:00"] {
            XCTAssertTrue(SelectionTimes.find(in: text, now: now, local: london).isEmpty, text)
        }
    }

    func testZoneOnlyLabelsUseTheLocalOffsetAtTheInstantIncludingDST() throws {
        let iso = ISO8601DateFormatter()
        for (stamp, difference) in [("2026-10-25T00:30:00Z", "13 hours ahead"), ("2026-10-25T01:30:00Z", "14 hours ahead")] {
            let instant = try XCTUnwrap(iso.date(from: stamp))
            let time = try XCTUnwrap(SelectionTimes.find(in: "UTC+14:00", now: instant, local: london).first)
            XCTAssertTrue(SelectionTimes.label(time, now: instant, local: london, locale: locale).hasSuffix(difference))
        }
        let local = try XCTUnwrap(TimeZone(secondsFromGMT: 14*3600))
        let time = try XCTUnwrap(SelectionTimes.find(in: "UTC−12:00", now: now, local: local).first)
        XCTAssertEqual(SelectionTimes.label(time, now: now, local: local, locale: locale), "Yesterday at 02:00 there · 26 hours behind")
    }

    func testCopyingAZoneOnlyTimeKeepsItsSnapshotDateAndZone() throws {
        let time = try XCTUnwrap(SelectionTimes.find(in: "UTC+14:00", now: now, local: london).first)
        let copied = SelectionTimes.copied(time, now: now, local: london, locale: locale)
        for part in ["24 Oct", "2026", "04:00", "UTC+14:00"] { XCTAssertTrue(copied.contains(part), copied) }
        XCTAssertEqual(SelectionTimes.copied(time, now: now.addingTimeInterval(86400), local: london, locale: locale), copied)
    }
}
