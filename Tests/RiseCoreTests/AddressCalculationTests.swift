import Foundation
import XCTest
@testable import RiseCore

final class AddressCalculationTests: XCTestCase {
    private let midnight = Date(timeIntervalSince1970: 1795737600) // Fri 27 Nov 2026, 00:00 UTC
    private var morning: Date { midnight.addingTimeInterval(10*3600+37*60) } // 10:37 in London
    private let london = TimeZone(identifier: "Europe/London")!
    private let rates = ExchangeRates(base: "USD", rates: ["USD": 1, "GBP": 0.79, "EUR": 0.92, "JPY": 150, "PLN": 4], updated: Date(timeIntervalSince1970: 1795737600))

    /// Read as someone in Britain would: a 24-hour clock, pounds, and fixed exchange rates.
    private func evaluate(_ query: String, in zone: TimeZone? = nil, at now: Date? = nil) -> AddressCalculation? {
        AddressCalculation.evaluate(query, now: now ?? midnight, timeZone: zone ?? london, locale: Locale(identifier: "en_GB"),
                                    rates: { self.rates }, primaryCurrency: "GBP")
    }

    private func check(_ cases: [(String, String?)], at now: Date? = nil, file: StaticString = #filePath, line: UInt = #line) {
        for (query, expected) in cases {
            XCTAssertEqual(evaluate(query, at: now)?.text, expected, query, file: file, line: line)
        }
    }

    func testAllEightCalculatorTypes() {
        check([
            ("9 am UTC in Tokyo", "6:00 pm JST"),
            ("days between 2026-11-01 and 2026-11-27", "26 days"),
            ("3:45 pm to 7:10 pm", "3 hr 25 min"),
            ("1767225600 to date", "Thu, 1 Jan 2026, 00:00 UTC"),
            ("1920x1080 aspect ratio", "16:9"),
            ("hex ff6600 to rgb", "rgb(255, 102, 0)"),
            ("pace for 5k in 24 minutes", "4:48 per km"),
            ("15% tip on 84 split 3 ways", "32.20 each, including tip")
        ])
        XCTAssertEqual(evaluate("hex ff6600 to rgb")?.color, .init(red: 255, green: 102, blue: 0))
    }

    func testChainingAndCalendarBoundaries() {
        check([
            ("1767225600 to date plus 4 days", "Mon, 5 Jan 2026, 00:00 UTC"),
            ("today plus 3 days to Unix", "1795996800 Unix seconds"),
            ("today +1d to Unix", "1795824000 Unix seconds"),
            ("today to unix + 4 days", "1796083200 Unix seconds"),
            ("today to Unix plus 4 days to date", "Tue, 1 Dec 2026"),
            ("today to Unix plus 4 days to date to Unix epoch", "1796083200 Unix seconds"),
            ("2024-02-28 plus 2 days", "Fri, 1 Mar 2024"),
            ("today plus 1 business day", "Mon, 30 Nov 2026"),
            ("days between today plus 2 days and tomorrow minus 1 day", "2 days"),
            ("unix -1 to date", "Wed, 31 Dec 1969, 23:59:59 UTC"),
            ("1767225600000 to date", "Thu, 1 Jan 2026, 00:00 UTC"),
            ("2026-01-01T00:00:00Z to unix", "1767225600 Unix seconds"),
            ("15:00 UTC to Tokyo to unix", "1795791600 Unix seconds"),
            ("9 am UTC in Tokyo plus 4 days to Unix", "1796115600 Unix seconds"),
            ("11:30 pm to 12:15 am", "45 min · next day"),
            ("11:30 to 1 pm in minutes", "90 minutes"),
            ("45 days from today", "Mon, 11 Jan 2027"),
            ("2026-11-27 day of week", "Friday, 27 Nov 2026"),
            ("2026-11-27 week number", "Week 48"),
            ("2026-07-01 9 am New York to UTC", "1:00 pm UTC"),
            ("2026-01-01 9 am New York to UTC", "2:00 pm UTC"),
            ("11 pm UTC in Tokyo", "8:00 am JST · next day")
        ])
        XCTAssertNil(evaluate("2026-02-29 plus 1 day"))
        XCTAssertNil(evaluate("2026-03-08 2:30 am new york to utc"), "Skipped wall-clock time")
        XCTAssertNil(evaluate("2026-11-01 1:30 am new york to utc"), "Repeated wall-clock time")
        XCTAssertEqual(evaluate("today to unix", in: TimeZone(identifier: "America/New_York"))?.text, "1795669200 Unix seconds")
    }

    func testTemporalStagesComposeFromDifferentStartingValues() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-06T19:37:12Z"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func result(_ query: String) -> String? { evaluate(query, in: newYork, at: instant)?.text }
        for query in ["now to Unix plus 4 days", "now plus 4 days to Unix", "4 days from now to Unix",
                      "now to Unix then to date plus 4 days then to Unix"] {
            XCTAssertEqual(result(query), "1773167832 Unix seconds", query)
        }
        XCTAssertEqual(result("now to Unix plus 96 hours"), "1773171432 Unix seconds")
        // A clock written with am/pm is answered the same way.
        XCTAssertEqual(result("9 am New York to UTC plus 4 days"), "Tue, 10 Mar 2026, 2:00 pm UTC")
        XCTAssertEqual(result("9 am New York plus 4 days to UTC"), "Tue, 10 Mar 2026, 1:00 pm UTC")
        XCTAssertEqual(result("9 am UTC to Tokyo then + 1 day to Unix"), "1772874000 Unix seconds")
        XCTAssertEqual(result("9 am UTC as unix to date"), "Fri, 6 Mar 2026, 9:00 am UTC")
        XCTAssertEqual(result("today at 9 am London to Tokyo to Unix"), "1772787600 Unix seconds")
        XCTAssertEqual(result("hours between 9 am New York and 9 am in New York plus 4 days"), "95 hours")
        XCTAssertNil(result("now to unix plus 4 weeks and a palindrome"))
    }

    func testTimeZones() {
        check([
            ("time in tokyo", "19:37 JST"),
            ("tokyo time", "19:37 JST"),
            ("what time is it in sydney", "21:37 AEDT"),
            ("time in poland", "11:37 CET"),
            ("date in tokyo", "Friday, 27 Nov 2026"),
            ("time difference between london and tokyo", "Tokyo is 9 hr ahead of London"),
            ("9am london to tokyo and new york", "6:00 pm JST · 4:00 am EST"),
            ("3pm tokyo time", "6:00 am GMT"),
            ("15:00 cet to est", "09:00 EST"),
            ("5pm est to my time zone", "10:00 pm GMT"),
            ("9am pst = gmt", "5:00 pm GMT"),
            ("9am pst + 3 hours in tokyo", "5:00 am JST · next day"),
            ("christmas 9am pst to tokyo", "2:00 am JST · next day"),
            ("in 2 hours in new york", "07:37 EST"),
            ("1800000000 to date in tokyo", "Fri, 15 Jan 2027, 17:00 JST")
        ], at: morning)
        XCTAssertNil(evaluate("9 am utc to mars"))
    }

    func testCountdownsAndDays() {
        check([
            ("days until christmas", "28 days"),
            ("how long until 5pm", "6 hr 23 min"),
            ("how long until the weekend", "1 day"),
            ("business days until christmas", "20 business days"),
            ("weeks until christmas", "4 weeks"),
            ("days between 1 jan and christmas", "358 days"),
            ("days between christmas and new year", "7 days"),
            ("from friday to monday", "3 days"),
            ("christmas - today", "28 days"),
            ("christmas - today in hours", "672 hours"),
            ("what day is christmas", "Friday, 25 Dec 2026"),
            ("when is easter", "Sun, 28 Mar 2027"),
            ("next friday", "Fri, 4 Dec 2026"),
            ("in 20 hours", "06:37 · tomorrow"),
            ("9pm + 5 hours", "2:00 am · tomorrow"),
            ("now + an hour and a half", "12:07"),
            ("in an hour and a half", "12:07"),
            ("now + (2 x 45 min)", "12:07"),
            ("now to iso", "2026-11-27T10:37:00Z"),
            ("christmas week number", "Week 52"),
            ("christmas day of year", "Day 359 of 365"),
            ("how many days in february", "28 days · 29 in 2028"),
            ("days in february 2028", "29 days"),
            ("last day of february", "Sun, 28 Feb 2027"),
            ("first monday of december", "Mon, 7 Dec 2026"),
            ("last working day of the month", "Mon, 30 Nov 2026"),
            ("what day is the last day of february", "Sunday, 28 Feb 2027"),
            ("how old is someone born 14 may 1990", "36 years old"),
            ("is 2028 a leap year", "2028 is a leap year")
        ], at: morning)
        // A day alone is a search, not a sum.
        for query in ["christmas", "friday", "tomorrow", "dec 25", "weekend", "9am", "12:30", "2024", "today plus 3",
                      "1767225600 to date and hello"] {
            XCTAssertNil(evaluate(query, at: morning), query)
        }
    }

    func testLengthsOfTime() {
        check([
            ("2h 30m + 45m", "3 hr 15 min"),
            ("45 min x 3", "2 hr 15 min"),
            ("135 minutes in hours and minutes", "2 hr 15 min"),
            ("8000 seconds to h:mm:ss", "2:13:20"),
            ("90 minutes in hours", "1.5 hours"),
            ("(9am to 5pm) x 5", "40 hr"),
            ("9am to 5:30pm minus 30 min", "8 hr"),
            ("(9am to 5:30pm - 30 min) x 5", "40 hr"),
            ("how many seconds in a day", "86,400 seconds"),
            ("minutes in 3 hours", "180 minutes")
        ], at: morning)
        for query in ["2 hours", "a week", "1 day"] { XCTAssertNil(evaluate(query, at: morning), query) }
    }

    func testMoneyChainsAndConversions() {
        check([
            ("56 usd to gbp", "£44.24"),
            ("56 usd to gbp + 15 gbp", "£59.24"),
            ("2x(15 usd to gbp)", "£23.70"),
            ("100 usd to gbp and eur", "£79.00 · €92.00"),
            ("(£84 + 15%) / 3", "£32.20"),
            ("50 eur", "£42.93"),
            ("50 quid in euros", "€58.23"),
            ("1k jpy to gbp", "£5.27"),
            ("$5.99 x 12 to gbp", "£56.79"),
            ("half of £84", "£42.00"),
            ("a third of (£90 + £30)", "£40.00"),
            ("15% of £84", "£12.60"),
            ("15% of 84 usd in gbp", "£9.95")
        ])
        // Currency codes that are also words, and plain arithmetic, are left to the search engine.
        for query in ["5 cup", "10 try", "50 cent", "18% of 240", "2+2", "£", "20%"] { XCTAssertNil(evaluate(query), query) }
    }

    func testPayRates() {
        check([
            ("£15/hr x 37.5 hours", "£562.50"),
            ("40 hours at £15 an hour", "£600.00"),
            ("(9am to 5pm) x 5 at £15/hour", "£600.00"),
            ("9am to 5:30pm at £12.50/hr", "£106.25"),
            ("£15/hr for 37.5 hours a week", "£562.50 a week"),
            ("£50k a year to monthly", "£4,166.67 a month"),
            ("£50k salary to hourly", "£25.64 an hour · 37.5-hour week"),
            ("£50k a year to hourly at 40 hours a week", "£24.04 an hour · 40-hour week"),
            ("£25/hr to annual salary", "£48,750.00 a year · 37.5-hour week"),
            ("$80k a year to gbp monthly", "£5,266.67 a month"),
            ("$20 an hour", "£15.80 an hour"),
            ("£600 / 40 hours", "£15.00 an hour"),
            ("£2,000 / 4 weeks", "£500.00 a week"),
            ("£600 / £15 an hour", "40 hr"),
            ("£5 a month x 12", "£60.00"),
            ("£50k a year + 10%", "£55,000.00 a year"),
            ("3 at £4.50", "£13.50"),
            ("£9.99 a month for a year", "£119.88"),
            ("£50k a year for 6 months", "£25,000.00")
        ], at: morning)
        // Months and years have no one length of their own.
        for query in ["2 years in days", "2 months + 3 days"] { XCTAssertNil(evaluate(query, at: morning), query) }
    }

    func testEverydayMoney() {
        check([
            ("15% tip on $84", "$12.60 tip · $96.60 total"),
            ("15% tip on $84 split 3 ways in gbp", "£25.44 each, including tip"),
            ("split £120 3 ways", "£40.00 each"),
            ("£84 / 3 people", "£28.00 each"),
            ("30% off £84", "£58.80 · save £25.20"),
            ("£100 after 20% discount", "£80.00 · save £20.00"),
            ("£84 plus 20% vat", "£100.80 · £16.80 VAT"),
            ("remove 20% vat from £100.80", "£84.00 · £16.80 VAT"),
            ("23% vat on 100 pln in gbp", "£24.29 · £4.54 VAT"),
            ("increase £50 by 10%", "£55.00 · +£5.00"),
            ("percent change from 80 to 100", "25% increase"),
            ("£80 to £100 percent change", "25% increase"),
            ("£84 is what percent of £200", "42%"),
            ("what percent of £200 is $50", "19.75%")
        ])
    }

    func testColorConversionsDoNotRequireDigits() {
        check([
            ("black to rgb", "rgb(0, 0, 0)"),
            ("#FDFDFD to rgb", "rgb(253, 253, 253)"),
            ("#fdfdfd", "rgb(253, 253, 253)"),
            ("fdfdfd color to rgb", "rgb(253, 253, 253)"),
            ("#fff to hsl", "hsl(0, 0%, 100%)"),
            ("convert navy blue to hex", "#000080"),
            ("RGB code for Rebecca Purple", "rgb(102, 51, 153)"),
            ("convert CSS dark slate gray to hex", "#2F4F4F"),
            ("black to hsl then to rgb", "rgb(0, 0, 0)"),
            ("aqua in hex", "#00FFFF"),
            ("hex to rgb #3366cc", "rgb(51, 102, 204)"),
            ("rgb to hex 255 0 0", "#FF0000"),
            ("blue to hex and rgb", "#0000FF · rgb(0, 0, 255)"),
            ("#3366cc to cmyk", "cmyk(75%, 50%, 0%, 20%)"),
            ("#3366cc to oklch", "oklch(53.2% 0.168 262.3)"),
            ("rgb(255 0 0 / 50%) to hex", "#FF000080"),
            ("what color is #ff8800", "≈ darkorange"),
            ("#6495ed to name", "cornflowerblue"),
            ("123 to hex", nil),
            ("#ggg to rgb", nil),
            ("black to rgb color scheme", nil),
            ("red", nil)
        ])
        XCTAssertEqual(evaluate("black to rgb")?.color, .init(red: 0, green: 0, blue: 0))
        XCTAssertEqual(evaluate("#FDFDFD to rgb")?.color, .init(red: 253, green: 253, blue: 253))
        XCTAssertEqual(evaluate("#3366cc at 50% opacity")?.color, .init(red: 51, green: 102, blue: 204, alpha: 0.5))
    }

    func testWorkingOnColors() {
        check([
            ("mix red and blue", "#800080"),
            ("lighten #3366cc by 20%", "#85A3E0"),
            ("darken navy by 10%", "#00004D"),
            ("complement of #3366cc", "#CC9933"),
            ("invert #3366cc", "#CC9933"),
            // A grey as bright as the colour, so it has the same contrast against anything.
            ("grayscale #3366cc", "#6B6B6B"),
            ("#3366cc at 50% opacity", "#3366CC80"),
            ("contrast #777 on white", "4.47:1 · AA large text"),
            ("contrast black on white", "21:1 · AAA"),
            ("#fff on #3366cc contrast", "5.36:1 · AA")
        ])
    }

    /// Copied, a conversion is its number alone, as it's written, unless units are kept.
    func testConversionsCopyTheirNumberAlone() {
        for (text, number) in [("£10.68", "10.68"), ("CHF 1,234.56", "1,234.56"), ("1.234,56 €", "1.234,56"), ("1\u{202F}234,56 €", "1\u{202F}234,56"),
                               ("11.02 lb", "11.02"), ("−3 °C", "-3"), ("33.0693393 pounds", "33.0693393"), ("43.2", "43.2")] {
            XCTAssertEqual(AddressCalculation.bareNumber(in: text), number, text)
        }
        for text in ["2 hr 15 min", "€10 – €20", "5′ 11″", "15% increase", "3 PM", "#FF6600", "rgb(255, 102, 0)", "16:9", "No change",
                     "£2.10 tip · £16.10 total"] {
            XCTAssertNil(AddressCalculation.bareNumber(in: text), text)
        }
        // Money, lengths of time and sizes carry it; colours, dates, times and weeks don't.
        for (query, amount) in [("15 usd to gbp", "11.85"), ("2.5 hours in minutes", "150"), ("11:30 to 1 pm in minutes", "90"),
                                ("days between 2026-11-01 and 2026-11-27", "26"), ("15% tip on 84 split 3 ways", "32.20"),
                                ("today plus 3 days to Unix", "1795996800")] {
            XCTAssertEqual(evaluate(query)?.amount, amount, query)
        }
        for query in ["hex ff6600 to rgb", "2026-11-27 week number", "9 am UTC in Tokyo", "2026-11-27 day of week", "1920x1080 aspect ratio",
                      "3:45 pm to 7:10 pm"] {
            XCTAssertNotNil(evaluate(query), query)
            XCTAssertNil(evaluate(query)?.amount, query)
        }
    }

    func testSwatchRingsStandOutFromThePalette() {
        typealias Color = AddressCalculation.Color
        let white = Color(red: 255, green: 255, blue: 255), dark = Color(red: 0x23, green: 0x23, blue: 0x27)
        // A colour that shows: its ring is itself, faint.
        XCTAssertEqual(Color(red: 36, green: 99, blue: 235).swatchRing(on: white), Color(red: 216, green: 227, blue: 251))
        XCTAssertEqual(Color(red: 0, green: 0, blue: 0).swatchRing(on: dark), Color(red: 29, green: 29, blue: 32))
        // Near the background: a shade further from it, darker on white and lighter in the dark.
        for pale in [Color(red: 253, green: 253, blue: 253), white, Color(red: 0, green: 0, blue: 0, alpha: 0)] {
            let ring = pale.swatchRing(on: white)
            XCTAssertEqual(ring.red, ring.blue); XCTAssertLessThan(ring.red, 215)
        }
        XCTAssertGreaterThan(Color(red: 18, green: 18, blue: 18).swatchRing(on: dark).red, 0x40)
        XCTAssertGreaterThan(dark.swatchRing(on: dark).red, 0x40)
        // A pale yellow keeps its hue, darker.
        let yellow = Color(red: 255, green: 255, blue: 153).swatchRing(on: white)
        XCTAssertLessThan(yellow.blue, yellow.red); XCTAssertLessThan(yellow.red, 240)
    }

    func testOtherChainedConversionsAndInvalidInputs() {
        check([
            ("1920x1080 aspect ratio at 1280 wide", "1280 × 720 px"),
            ("2560x1080 ratio", "64:27 · ≈ 21:9"),
            ("16:9 at 720 high", "1280 × 720 px"),
            ("1920x1080 to 4:3", "1440 × 1080 px"),
            ("4000x3000 in megapixels", "12 MP"),
            ("rgb 255 102 0 to hsl then hex", "#FF6600"),
            ("hex #f60 in rgb", "rgb(255, 102, 0)"),
            ("hsl(24, 100%, 50%) to rgb", "rgb(255, 102, 0)"),
            ("pace for 5km in 24:00 to miles", "7:43 per mi"),
            ("pace for 1 mile in 8 minutes", "8:00 per mi"),
            ("marathon in 3:30", "4:59 per km"),
            ("marathon at 5:00/km", "3 hr 30 min 59 sec"),
            ("12 km/h to pace", "5:00 per km"),
            ("100m in 10 seconds", "36 km/h"),
            ("15% tip on £83.50 split between 4 people", "£24.01 each, including tip")
        ])
        for query in ["18% of 240", "123 to hex", "225lbs to kg", "16x9", "0x3 aspect ratio", "rgb 256 0 0 to hex",
                      "hex 12345 to rgb", "pace for 0km in 24 minutes", "pace for 5km in 0 minutes",
                      "15% tip on 84 split 0 ways", "today plus 3", "1767225600 to date and hello",
                      "half life 3", "double click", "split screen", "london", "iphone 16"] {
            XCTAssertNil(evaluate(query), query)
        }
    }
}
