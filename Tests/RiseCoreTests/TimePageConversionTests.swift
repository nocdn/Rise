import WebKit
import XCTest
@testable import RiseCore

final class TimePageConversionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_764_000)
    let london = TimeZone(identifier: "Europe/London")!, locale = Locale(identifier: "en_GB")
    func rewrite(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in TimePageConversion.edits(in: text, now: now, local: london, locale: locale).reversed() {
            result.replaceCharacters(in: NSRange(location: edit.start, length: edit.end-edit.start), with: edit.text)
        }
        return result as String
    }
    func testPageEditsKeepProseUnicodeZonesAndRepeatedOccurrences() {
        for (original, converted) in [
            ("🌎 Starts at 10 AM PT, then 10 AM PT.", "🌎 Starts at 18:00 BST, then 18:00 BST."),
            ("Meet at noon PDT!", "Meet at 20:00 BST!"),
            ("The call: 10–11am PST.", "The call: 18:00 BST – 19:00 BST."),
            ("Offset 10:30 UTC+14:00", "Offset 21:30 BST"),
            ("UTC+14:00 10:30", "21:30 BST"),
            ("Local 4:30pm BST, version 10.30, UTC+14:00, 5pm", "Local 4:30pm BST, version 10.30, UTC+14:00, 5pm"),
        ] { XCTAssertEqual(rewrite(original), converted, original) }
    }
    func testPostgresAndISOHaveExactInstantsAndReadableLocalDates() throws {
        let iso = ISO8601DateFormatter()
        let expected = try XCTUnwrap(iso.date(from: "2026-10-23T10:05:06Z"))
        for text in ["2026-10-23T10:05:06Z", "2026-10-23 10:05:06+00", "2026-10-23 12:05:06+02:00", "2026-10-23T04:35:06-0530"] {
            let time = try XCTUnwrap(SelectionTimes.find(in: text, now: now, local: london).first, text)
            XCTAssertEqual(time.start, expected, text)
            let converted = rewrite(text)
            for part in ["23 Oct 2026", "11:05:06", "BST"] { XCTAssertTrue(converted.contains(part), converted) }
        }
        let fractional = try XCTUnwrap(SelectionTimes.find(in: "2026-10-23T10:05:06.123456Z", now: now, local: london).first)
        XCTAssertEqual(fractional.start.timeIntervalSince(expected), 0.123456, accuracy: 0.000001)
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(SelectionTimes.find(in: "2026-10-23T10:05:06Z", now: now, local: utc).count, 1, "UTC timestamps still get a readable selection in UTC")
        for invalid in ["2026-02-30T10:00:00Z", "2026-13-01T10:00:00Z", "2026-10-23T25:00:00Z", "2026-10-23T10:60:00Z",
                        "2026-10-23T10:00:00+14:01", "2026-10-23T10:00:00+5", "2026-10-23T10:00:00"] {
            XCTAssertTrue(SelectionTimes.find(in: invalid, now: now, local: london).isEmpty, invalid)
            XCTAssertEqual(rewrite(invalid), invalid)
        }
        XCTAssertTrue(rewrite("2026-12-01T10:00:00Z").contains("10:00:00 GMT"))
        XCTAssertTrue(rewrite("2026-07-01T10:00:00Z").contains("11:00:00 BST"))
    }

    func testEmailHTTPICalendarAndNamedZoneTimestamps() throws {
        let iso = ISO8601DateFormatter(), expected = try XCTUnwrap(iso.date(from: "2026-10-23T10:05:06Z"))
        for written in ["Fri, 23 Oct 2026 10:05:06 +0000", "Fri, 23 Oct 2026 12:05:06 +0200",
                        "Fri, 23 Oct 2026 10:05:06 GMT", "20261023T100506Z", "2026-10-23 10:05:06 UTC",
                        "2026-10-23T10:05:06 Etc/UTC", "2026-10-23T12:05:06 Europe/Paris",
                        "2026-10-23 10:05:06 GMT+00:00"] {
            let time = try XCTUnwrap(SelectionTimes.find(in: written, now: now, local: london).first, written)
            XCTAssertEqual(time.start, expected, written)
            let converted = rewrite(written)
            for part in ["23 Oct 2026", "11:05:06", "BST"] { XCTAssertTrue(converted.contains(part), "\(written): \(converted)") }
        }
        let fractional = try XCTUnwrap(SelectionTimes.find(in: "2026-10-23T10:05:06,25Z", now: now, local: london).first)
        XCTAssertEqual(fractional.start.timeIntervalSince(expected), 0.25, accuracy: 0.000001)
    }

    @MainActor func testDOMReplacementPreservesInlineMarkupAndRestoresLiveOriginals() async throws {
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let loaded = expectation(description: "loaded"), delegate = TimePageLoadDelegate { loaded.fulfill() }
        page.navigationDelegate = delegate
        page.loadHTMLString("""
        <body><p id=a>🌎 Call <b>10 AM</b> <i>PT</i>, then 10 AM PT.</p>
        <p id=b>2026-10-23T10:05:06.123456Z</p><input value='10 AM PT'>
        <code>10 AM PT</code><div contenteditable=true>10 AM PT</div><p hidden>10 AM PT</p></body>
        """, baseURL: URL(string: "https://example.test/"))
        await fulfillment(of: [loaded], timeout: 10)
        func value(_ body: String) async throws -> Any? { try await page.callAsyncJavaScript(body, contentWorld: .defaultClient) }
        let original = try await value("return document.body.innerHTML") as? String
        let conversion = TimePageConversion { body, arguments in
            try await page.callAsyncJavaScript(body, arguments: arguments, contentWorld: .defaultClient)
        }
        let count = try await conversion.set(true, now: now, local: london, locale: locale)
        XCTAssertEqual(count, 3)
        let content = try await value("return document.querySelector('#a').textContent") as? String
        XCTAssertEqual(content, "🌎 Call 18:00 BST, then 18:00 BST.")
        let markup = try await value("return [!!document.querySelector('#a b'), !!document.querySelector('#a i'), document.querySelector('input').value, document.querySelector('code').textContent, document.querySelector('[contenteditable]').textContent, document.querySelector('[hidden]').textContent]") as? [Any]
        XCTAssertEqual(markup.map { Array($0.dropFirst(2)) } as? [String], Array(repeating: "10 AM PT", count: 4))
        XCTAssertEqual(markup.map { Array($0.prefix(2)) } as? [Bool], [true, true])
        _ = try await conversion.set(false)
        let restored = try await value("return document.body.innerHTML") as? String
        XCTAssertEqual(restored, original)

        _ = try await conversion.set(true, now: now, local: london, locale: locale)
        _ = try await value("document.body.insertAdjacentHTML('beforeend', '<p id=c>Now 10 AM PT</p>');document.querySelector('#b').textContent='Page edited this itself';return 0")
        try await Task.sleep(for: .milliseconds(950))
        let added = try await value("return document.querySelector('#c').textContent") as? String
        XCTAssertEqual(added, "Now 18:00 BST")
        _ = try await conversion.set(false)
        let changed = try await value("return [document.querySelector('#b').textContent, document.querySelector('#c').textContent]") as? [String]
        XCTAssertEqual(changed, ["Page edited this itself", "Now 10 AM PT"])
        XCTAssertFalse(conversion.isActive)
    }

    @MainActor func testRestoringWhileInitialPassIsPendingNeverWritesLateConversions() async throws {
        let page = WKWebView()
        let loaded = expectation(description: "loaded"), delegate = TimePageLoadDelegate { loaded.fulfill() }
        page.navigationDelegate = delegate; page.loadHTMLString("<p>10 AM PT</p>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let conversion = TimePageConversion { body, arguments in
            if body.contains(".write(") { try await Task.sleep(for: .milliseconds(100)) }
            return try await page.callAsyncJavaScript(body, arguments: arguments, contentWorld: .defaultClient)
        }
        let start = Task { try await conversion.set(true, now: now, local: london, locale: locale) }
        try await Task.sleep(for: .milliseconds(30))
        _ = try await conversion.set(false); _ = try await start.value
        let text = try await page.evaluateJavaScript("document.querySelector('p').textContent") as? String
        XCTAssertEqual(text, "10 AM PT"); XCTAssertFalse(conversion.isActive)
    }

    @MainActor func testCurrenciesAndTimesRestoreIndependentlyInEitherOrder() async throws {
        let page = WKWebView()
        let loaded = expectation(description: "loaded"), delegate = TimePageLoadDelegate { loaded.fulfill() }
        page.navigationDelegate = delegate; page.loadHTMLString("<p id=p>Tickets £10 at 10 AM PT.</p>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let conversion = TimePageConversion { body, arguments in
            try await page.callAsyncJavaScript(body, arguments: arguments, contentWorld: .defaultClient)
        }
        let rates = ExchangeRates(base: "USD", rates: ["USD": 1, "GBP": 0.5, "EUR": 0.8], updated: now)
        let currencyWorld = WKContentWorld.world(name: "OtherConverter")
        func currency(_ on: Bool) async throws {
            _ = try await page.callAsyncJavaScript(on ? CurrencyAmounts.applyBody : CurrencyAmounts.restoreBody,
                arguments: on ? ["options": CurrencyAmounts.replaceOptions(to: "EUR", rates: rates, locale: locale)] : [:],
                contentWorld: currencyWorld)
        }
        func text() async throws -> String { try await page.evaluateJavaScript("document.querySelector('#p').textContent") as! String }
        for timesFirst in [true, false] {
            if timesFirst { _ = try await conversion.set(true, now: now, local: london, locale: locale); try await currency(true) }
            else { try await currency(true); _ = try await conversion.set(true, now: now, local: london, locale: locale) }
            try await Task.sleep(for: .milliseconds(600))
            let converted = try await text()
            XCTAssertEqual(converted, "Tickets €16 at 18:00 BST.")
            _ = try await conversion.set(false)
            let localRestored = try await text()
            XCTAssertEqual(localRestored, "Tickets €16 at 10 AM PT.")
            try await currency(false)
            let bothRestored = try await text()
            XCTAssertEqual(bothRestored, "Tickets £10 at 10 AM PT.")
        }
        _ = try await conversion.set(true, now: now, local: london, locale: locale)
        try await currency(true); try await currency(false)
        let pricesRestored = try await text()
        XCTAssertEqual(pricesRestored, "Tickets £10 at 18:00 BST.")
        _ = try await page.evaluateJavaScript("document.querySelector('#p').firstChild.appendData(' Again 11 AM PT.');0")
        try await Task.sleep(for: .milliseconds(900))
        _ = try await conversion.set(false)
        let appended = try await text()
        XCTAssertEqual(appended, "Tickets £10 at 10 AM PT. Again 11 AM PT.")
    }
}

@MainActor private final class TimePageLoadDelegate: NSObject, WKNavigationDelegate {
    let loaded: () -> Void
    init(_ loaded: @escaping () -> Void) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
}
