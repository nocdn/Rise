import WebKit
import XCTest
@testable import RiseCore

final class CurrencyAmountsTests: XCTestCase {
    /// Round rates, a US dollar being worth each.
    let rates = ExchangeRates(base: "USD", rates: ["USD": 1, "EUR": 0.8, "GBP": 0.5, "PLN": 4, "JPY": 150, "CAD": 1.25,
                                                  "SEK": 10, "CHF": 0.9, "ALL": 100, "MYR": 4.5], updated: Date())
    let gb = Locale(identifier: "en_GB")

    func found(_ text: String, host: String? = nil) -> [String] {
        CurrencyAmounts.find(in: text, host: host, rates: rates).map { "\($0.currency) \($0.values.map { String(format: "%g", $0) }.joined(separator: "–"))" }
    }

    func testFindsAmountsWrittenWithSignsCodesAndWords() {
        let cases: [(String, [String])] = [
            ("66.06 GBP", ["GBP 66.06"]),
            ("£66.06", ["GBP 66.06"]),
            ("Cena: 1 234,50 zł", ["PLN 1234.5"]),
            ("1.234,50 €", ["EUR 1234.5"]),
            ("1,234.56 USD", ["USD 1234.56"]),
            ("USD 12", ["USD 12"]),
            ("12,- €", ["EUR 12"]),
            ("5 euros", ["EUR 5"]),
            ("100 dollars", ["USD 100"]),
            ("$10–20", ["USD 10–20"]),
            ("10 - 20 zł", ["PLN 10–20"]),
            ("£2.5bn", ["GBP 2.5e+09"]),
            ("$3k", ["USD 3000"]),
            ("€5 and £7.50", ["EUR 5", "GBP 7.5"]),
            ("(-$5)", ["USD 5"]),
            ("RM 12.90", ["MYR 12.9"]),
            ("CA$20", ["CAD 20"]),
        ]
        for (text, expected) in cases { XCTAssertEqual(found(text), expected, text) }
    }

    func testAmbiguousSignsTakeThePagesCountryOrTheirCode() {
        XCTAssertEqual(found("$5", host: "shop.ca"), ["CAD 5"])
        XCTAssertEqual(found("$5"), ["USD 5"])
        XCTAssertEqual(found("$100 CAD"), ["CAD 100"])
        // No country to go by: Swedish, Norwegian, Danish or Icelandic, so none.
        XCTAssertEqual(found("100 kr"), [])
        XCTAssertEqual(found("100 kr", host: "www.ikea.se"), ["SEK 100"])
    }

    func testOrdinaryNumbersAreNotMoney() {
        for text in ["Room 101", "12.10.2026", "5 pounds of flour", "ALL 5 ITEMS", "ABC 12", "version 2.5", "10:30", "50%", "3 m"] {
            XCTAssertEqual(found(text), [], text)
        }
    }

    func rewrite(_ text: String, to target: String, host: String? = nil, locale: Locale? = nil) -> String {
        CurrencyAmounts.rewrite(text, to: target, rates: rates, host: host, locale: locale ?? gb)
    }

    func testRewritesAmountsAsTheirNewCurrencyIsWritten() {
        let cases: [(String, String, String)] = [
            ("£66.06", "EUR", "€105.70"),
            // A code stays a code, where it was.
            ("Price: 66.06 GBP each", "EUR", "Price: 105.70 EUR each"),
            // Not "43,63 £": the pound's sign goes before, with a point.
            ("349,00 zł", "GBP", "£43.63"),
            ("Cena: 1 234,50 zł", "EUR", "Cena: €246.90"),
            // Whole amounts stay whole.
            ("£12", "EUR", "€19"),
            ("$3.5m", "EUR", "€2.8m"),
            ("$10–20", "EUR", "€8–16"),
            ("10 - 20 zł", "GBP", "£1 - 3"),
            ("¥1,500", "USD", "US$10"),
            // A currency without cents loses them.
            ("$6.00", "JPY", "JP¥900"),
            ("$1,234", "JPY", "JP¥185,100"),
            ("€5", "PLN", "PLN\u{a0}25"),
            ("5 €", "CHF", "CHF\u{a0}6"),
            ("$100 CAD", "USD", "US$80 USD"),
            ("1,234.56 USD", "EUR", "987.65 EUR"),
            ("$0.50", "EUR", "€0.40"),
            ("€5 and £7.50", "USD", "US$6 and US$15.00"),
            // Already in it, or not money: left alone.
            ("€5", "EUR", "€5"),
            ("Room 101", "EUR", "Room 101"),
        ]
        for (text, target, expected) in cases { XCTAssertEqual(rewrite(text, to: target), expected, text) }
    }

    func testTheNewCurrencyIsWrittenAsThePersonsRegionWritesIt() {
        let poland = Locale(identifier: "pl_PL"), canada = Locale(identifier: "en_CA")
        XCTAssertEqual(rewrite("£10.50", to: "PLN", locale: poland), "84,00\u{a0}zł")
        XCTAssertEqual(rewrite("£10", to: "PLN", locale: poland), "80\u{a0}zł")
        XCTAssertEqual(rewrite("€8.00", to: "CAD", locale: canada), "$12.50")
        XCTAssertEqual(rewrite("€8.00", to: "CAD"), "CA$12.50")
    }

    func testTheMenuReadsAmountsInThePersonsCurrency() {
        let amounts = CurrencyAmounts.find(in: "£66.06", rates: rates)
        XCTAssertEqual(CurrencyAmounts.label(amounts[0], to: "EUR", rates: rates, locale: gb), "€105.70")
        let range = CurrencyAmounts.find(in: "$10–20", rates: rates)
        XCTAssertEqual(CurrencyAmounts.label(range[0], to: "GBP", rates: rates, locale: gb), "£5.00 – £10.00")
        let two = CurrencyAmounts.find(in: "€5 or £7.50", rates: rates)
        XCTAssertEqual(two.map { CurrencyAmounts.label($0, of: two.count, to: "USD", rates: rates, locale: gb) },
                       ["€5 → US$6.25", "£7.50 → US$15.00"])
        XCTAssertEqual(CurrencyAmounts.name(of: "EUR", locale: gb), "Euro")
        let currencies = CurrencyAmounts.currencies(in: rates, locale: gb)
        // The most traded first, in that order, then the rest by name.
        XCTAssertEqual(currencies.popular.map(\.code), ["USD", "EUR", "JPY", "GBP", "CAD", "CHF"])
        XCTAssertEqual(currencies.others.map(\.name), ["Albanian Lek", "Malaysian Ringgit", "Polish Zloty", "Swedish Krona"])
    }

    func testRatesReadTheOpenAPIsDay() throws {
        let data = Data(#"{"result":"success","base_code":"USD","time_last_update_unix":1793318551,"rates":{"USD":1,"EUR":0.8}}"#.utf8)
        let rates = try XCTUnwrap(ExchangeRates(response: data))
        XCTAssertEqual(rates.rates["EUR"], 0.8)
        XCTAssertEqual(try XCTUnwrap(rates.convert(10, from: "EUR", to: "USD")), 12.5, accuracy: 0.0001)
        XCTAssertNil(ExchangeRates(response: Data(#"{"result":"error"}"#.utf8)))
    }

    func testPrimaryCurrencyIsTheRegionsUntilChosen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CurrencyAmountsTests"))
        defaults.removePersistentDomain(forName: "CurrencyAmountsTests")
        XCTAssertEqual(PrimaryCurrency.code(in: defaults, locale: Locale(identifier: "pl_PL")), "PLN")
        PrimaryCurrency.set("EUR", in: defaults)
        XCTAssertEqual(PrimaryCurrency.code(in: defaults, locale: Locale(identifier: "pl_PL")), "EUR")
        defaults.removePersistentDomain(forName: "CurrencyAmountsTests")
    }

    // MARK: Replace on Page, in a real page

    @MainActor func testReplacesAPagesAmountsAndPutsThemBack() async throws {
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let html = """
        <html lang="en"><body>
        <p id="a">Tickets from £66.06, or 1,250.00 GBP for a box.</p>
        <p id="b"><span>£</span><span>12</span><sup>.</sup><sup>99</sup></p>
        <p id="c">Only €5 today</p>
        <p id="d">Call 0800 123 456 before 10:30</p>
        <textarea id="e">£10</textarea>
        <code id="f">£10</code>
        </body></html>
        """
        let loaded = expectation(description: "loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        page.navigationDelegate = delegate
        page.loadHTMLString(html, baseURL: URL(string: "https://example.co.uk/"))
        await fulfillment(of: [loaded], timeout: 10)
        let before = try await page.evaluateJavaScript("document.body.innerHTML") as? String
        let options: [String: Any] = ["options": ["rates": rates.rates, "target": "EUR"]]
        let count = try await page.callAsyncJavaScript(CurrencyAmounts.applyBody, arguments: options, contentWorld: .defaultClient) as? Int
        XCTAssertEqual(count, 3)
        func text(_ id: String) async throws -> String {
            try await page.callAsyncJavaScript("return document.getElementById(id).textContent", arguments: ["id": id], contentWorld: .page) as? String ?? ""
        }
        let first = try await text("a"), second = try await text("b"), third = try await text("c")
        XCTAssertEqual(first, "Tickets from €105.70, or 2,000.00 EUR for a box.")
        // Split across elements, each part keeps its place.
        XCTAssertEqual(second, "€20.78")
        let parts = try await page.callAsyncJavaScript("return [...document.querySelectorAll('#b > *')].map(e => e.textContent)", arguments: [:], contentWorld: .page) as? [String]
        XCTAssertEqual(parts, ["€", "20", ".", "78"])
        XCTAssertEqual(third, "Only €5 today")
        let untouched = [try await text("d"), try await text("e"), try await text("f")]
        XCTAssertEqual(untouched, ["Call 0800 123 456 before 10:30", "£10", "£10"])

        // What the page adds later is converted too.
        _ = try await page.callAsyncJavaScript("document.body.insertAdjacentHTML('beforeend', '<p id=\"g\">Now £20</p>')", arguments: [:], contentWorld: .page)
        try await Task.sleep(for: .milliseconds(600))
        let added = try await text("g")
        XCTAssertEqual(added, "Now €32")
        let active = try await page.callAsyncJavaScript(CurrencyAmounts.isReplacedBody, arguments: [:], contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(active, true)

        let restored = try await page.callAsyncJavaScript(CurrencyAmounts.restoreBody, arguments: [:], contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(restored, true)
        let after = try await page.evaluateJavaScript("document.body.innerHTML") as? String
        XCTAssertEqual(after, before.map { $0 + "<p id=\"g\">Now £20</p>" })
        let inactive = try await page.callAsyncJavaScript(CurrencyAmounts.isReplacedBody, arguments: [:], contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(inactive, false)
    }

    /// A long page, mostly words and numbers that aren't money, is rewritten and put back quickly.
    @MainActor func testALongPageIsQuickToReplace() async throws {
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let loaded = expectation(description: "loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        page.navigationDelegate = delegate
        page.loadHTMLString("<body></body>", baseURL: URL(string: "https://example.com/"))
        await fulfillment(of: [loaded], timeout: 10)
        _ = try await page.callAsyncJavaScript("""
            const rows = [];
            for (let i = 0; i < 20000; i++) rows.push(i % 10 ? `<li>Item ${i}, updated 12.10.2026, <b>in stock</b></li>`
                : `<li>Item ${i} <span>£</span><span>${i}</span><sup>.</sup><sup>99</sup> or ${i}.50 GBP</li>`);
            document.body.innerHTML = '<ul>' + rows.join('') + '</ul>';
            """, arguments: [:], contentWorld: .page)
        let start = Date()
        let count = try await page.callAsyncJavaScript(CurrencyAmounts.applyBody, arguments: ["options": ["rates": rates.rates, "target": "EUR"]], contentWorld: .defaultClient) as? Int
        let applied = Date().timeIntervalSince(start)
        XCTAssertEqual(count, 4000)
        _ = try await page.callAsyncJavaScript(CurrencyAmounts.restoreBody, arguments: [:], contentWorld: .defaultClient)
        let restored = Date().timeIntervalSince(start)-applied
        print("Replace on Page: 20,000 rows applied in \(Int(applied*1000)) ms, restored in \(Int(restored*1000)) ms")
        XCTAssertLessThan(applied, 1.5)
        XCTAssertLessThan(restored, 0.5)
    }
}

private final class LoadDelegate: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
