import WebKit
import XCTest
@testable import RiseCore

final class SelectionMeasurementsTests: XCTestCase {
    let gb = Locale(identifier: "en_GB")

    func found(_ text: String) -> [String] {
        SelectionMeasurements.find(in: text).map { "\($0.values.map { String(format: "%g", $0) }.joined(separator: "–")) \($0.unit.rawValue)" }
    }

    func converted(_ text: String, to units: PreferredUnits) -> [String] {
        SelectionMeasurements.conversions(in: text, to: units, locale: gb).map(\.converted)
    }

    func testFindsWeightsLengthsTemperaturesAndSpeeds() {
        let cases: [(String, [String])] = [
            ("5 km", ["5 kilometres"]),
            ("5km", ["5 kilometres"]),
            ("3.5 miles", ["3.5 miles"]),
            ("1,500 m", ["1500 metres"]),
            ("2,5 kg", ["2.5 kilograms"]),
            ("12 lbs", ["12 pounds"]),
            ("8 oz", ["8 ounces"]),
            ("500 g", ["500 grams"]),
            ("12 stone", ["12 stones"]),
            ("25°C", ["25 celsius"]),
            ("25 °C", ["25 celsius"]),
            ("-5 ºF", ["-5 fahrenheit"]),
            ("77 degrees Fahrenheit", ["77 fahrenheit"]),
            ("70 mph", ["70 milesPerHour"]),
            ("100 km/h", ["100 kilometresPerHour"]),
            ("10 m/s", ["10 metresPerSecond"]),
            ("20 knots", ["20 knots"]),
            ("12 in.", ["12 inches"]),
            ("6 ft", ["6 feet"]),
            ("5′11″", ["5.91667 feet"]),
            ("5'11\"", ["5.91667 feet"]),
            ("5 ft 11 in", ["5.91667 feet"]),
            ("5–10 km", ["5–10 kilometres"]),
            ("from 5 to 10 miles", ["5–10 miles"]),
            ("30 x 20 cm", ["30–20 centimetres"]),
            ("2 x 500 g", ["500 grams"]),
            ("5 kg and 3 miles", ["5 kilograms", "3 miles"]),
        ]
        for (text, expected) in cases { XCTAssertEqual(found(text), expected, text) }
    }

    func testLeavesWhatIsntAMeasurement() {
        for text in ["5M views", "posted 5m ago", "5G network", "1 in 10 people", "5 in stock", "$5m", "£2.5m", "Room 101",
                     "4K video", "A4 paper", "the 90's", "\"Top 10\""] {
            XCTAssertEqual(found(text), [], text)
        }
    }

    func testConvertsIntoThePersonsUnits() {
        XCTAssertEqual(converted("5 km", to: .us), ["3.11 mi"])
        XCTAssertEqual(converted("5 km", to: .uk), ["3.11 mi"])
        XCTAssertEqual(converted("5 km", to: .metric), [])
        XCTAssertEqual(converted("3 miles", to: .metric), ["4.83 km"])
        XCTAssertEqual(converted("3 miles", to: .uk), [])
        XCTAssertEqual(converted("180 cm", to: .us), ["5 ft 11 in"])
        XCTAssertEqual(converted("180 cm", to: .uk), [])
        XCTAssertEqual(converted("6 ft", to: .uk), ["1.83 m"])
        XCTAssertEqual(converted("12 in.", to: .metric), ["30.5 cm"])
        XCTAssertEqual(converted("5 kg", to: .us), ["11 lb"])
        XCTAssertEqual(converted("200 g", to: .us), ["7.05 oz"])
        XCTAssertEqual(converted("150 lbs", to: .uk), ["68 kg"])
        XCTAssertEqual(converted("8 oz", to: .metric), ["227 g"])
        XCTAssertEqual(converted("25°C", to: .us), ["77°F"])
        XCTAssertEqual(converted("98.6°F", to: .uk), ["37°C"])
        XCTAssertEqual(converted("100 km/h", to: .us), ["62 mph"])
        XCTAssertEqual(converted("70 mph", to: .metric), ["113 km/h"])
        XCTAssertEqual(converted("20 knots", to: .metric), ["37 km/h"])
        XCTAssertEqual(converted("5–10 km", to: .us), ["3.11–6.21 mi"])
        XCTAssertEqual(converted("30 x 20 cm", to: .us), ["11.8 × 7.9 in"])
    }

    func testSeveralSayWhatTheyWereWrittenAsAndListOtherUnits() throws {
        let conversions = SelectionMeasurements.conversions(in: "5 kg and 3 miles", to: .metric, locale: gb)
        XCTAssertEqual(conversions.map(\.label), ["4.83 km"], "5 kg is already metric")
        let both = SelectionMeasurements.conversions(in: "5 kg and 3 miles", to: .us, locale: gb)
        XCTAssertEqual(both.map(\.label), ["11 lb"])
        let two = SelectionMeasurements.conversions(in: "5 kg and 10 km", to: .us, locale: gb)
        XCTAssertEqual(two.map(\.label), ["5 kg → 11 lb", "10 km → 6.21 mi"])
        let others = try XCTUnwrap(SelectionMeasurements.conversions(in: "5 km", to: .us, locale: gb).first).others
        // Neither what it was written in nor what it's converted to; nothing absurdly large or small.
        XCTAssertEqual(others.map(\.name), ["Metres", "Feet", "Yards"])
        XCTAssertEqual(others.map(\.value), ["5,000 m", "16,404 ft", "5,468 yd"])
    }

    func testThePreferenceIsTheRegionsUntilChosen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SelectionMeasurementsTests"))
        defaults.removePersistentDomain(forName: "SelectionMeasurementsTests")
        XCTAssertEqual(PreferredUnits.current(in: defaults, locale: Locale(identifier: "en_US")), .us)
        XCTAssertEqual(PreferredUnits.current(in: defaults, locale: Locale(identifier: "en_GB")), .uk)
        XCTAssertEqual(PreferredUnits.current(in: defaults, locale: Locale(identifier: "pl_PL")), .metric)
        PreferredUnits.set(.metric, in: defaults)
        XCTAssertEqual(PreferredUnits.current(in: defaults, locale: Locale(identifier: "en_US")), .metric)
    }

    func testReplaceOnPageEditsOnlyWhatsInOtherUnits() {
        let text = "Run 5 km, then 3 miles, at 25°C."
        var written = text as NSString
        for edit in SelectionMeasurements.edits(in: text, to: .us, locale: gb).reversed() {
            written = written.replacingCharacters(in: NSRange(location: edit.start, length: edit.end-edit.start), with: edit.text) as NSString
        }
        XCTAssertEqual(written as String, "Run 3.11 mi, then 3 miles, at 77°F.")
        XCTAssertEqual(SelectionMeasurements.message(2, in: .us), "Replaced 2 measurements with US units")
        XCTAssertEqual(SelectionMeasurements.message(1, in: .metric), "Replaced 1 measurement with metric units")
        XCTAssertEqual(SelectionMeasurements.message(0, in: .uk), "No other measurements to replace")
    }

    @MainActor func testReplaceOnPageRewritesThePageAndPutsItBackBesideTimes() async throws {
        let page = WKWebView()
        let loaded = expectation(description: "loaded"), delegate = MeasurementPageLoadDelegate { loaded.fulfill() }
        page.navigationDelegate = delegate
        page.loadHTMLString("<p id=p>A <b>5 km</b> walk at 10 AM PT, 25°C.</p><input value='5 km'>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        func run(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
            try await page.callAsyncJavaScript(body, arguments: arguments, contentWorld: .defaultClient)
        }
        func text() async throws -> [String] {
            try await page.evaluateJavaScript("[document.querySelector('#p').textContent, document.querySelector('input').value]") as! [String]
        }
        let original = try await text()
        let measurements = PageTextConversion(global: "riseMeasurements", evaluate: run)
        let times = TimePageConversion(evaluate: run)
        let count = try await measurements.set(true) { SelectionMeasurements.edits(in: $0, to: .us, locale: self.gb) }
        XCTAssertEqual(count, 2)
        let replaced = try await text()
        XCTAssertEqual(replaced, ["A 3.11 mi walk at 10 AM PT, 77°F.", "5 km"])
        let bold = try await page.evaluateJavaScript("document.querySelector('#p b').textContent") as? String
        XCTAssertEqual(bold, "3.11 mi", "Inline markup is kept")
        let london = TimeZone(identifier: "Europe/London")!
        _ = try await times.set(true, now: Date(timeIntervalSince1970: 1_792_000_000), local: london, locale: gb)
        _ = try await measurements.set(false)
        let timesOnly = try await text().first ?? ""
        XCTAssertTrue(timesOnly.hasPrefix("A 5 km walk at ") && timesOnly.hasSuffix(", 25°C.") && !timesOnly.contains("PT"), timesOnly)
        _ = try await times.set(false)
        let restored = try await text()
        XCTAssertEqual(restored, original)
    }
}

@MainActor private final class MeasurementPageLoadDelegate: NSObject, WKNavigationDelegate {
    let loaded: () -> Void
    init(_ loaded: @escaping () -> Void) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
}
