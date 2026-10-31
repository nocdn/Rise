import XCTest
import UIKit
@testable import RiseiOS

final class SelectionCurrencyMenuTests: XCTestCase {
    let rates = ExchangeRates(base: "USD", rates: ["USD": 1, "EUR": 0.8, "GBP": 0.5, "PLN": 4], updated: Date())

    @MainActor func testAnAmountInAnotherCurrencyOpensToCopyReplaceAndOtherCurrencies() throws {
        let elements = SelectionCurrencyMenu.elements(for: "£66.06", in: nil, primary: "EUR", rates: rates)
        let menu = try XCTUnwrap(elements.first as? UIMenu)
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(menu.title, CurrencyAmounts.format(105.696, in: "EUR"))
        XCTAssertEqual(menu.children.map(\.title), ["Copy “\(menu.title)”", "Replace on Page", "Other Currencies"])
        XCTAssertEqual((menu.children[1] as? UIAction)?.state, .off)
        let others = try XCTUnwrap(menu.children[2] as? UIMenu)
        // The most traded first, then every other, and not the person's own.
        let sections = others.children.compactMap { ($0 as? UIMenu)?.children.compactMap { ($0 as? UIAction)?.subtitle } }
        XCTAssertEqual(sections, [["USD", "GBP"], ["PLN"]])
        XCTAssertTrue(menu.identifier.rawValue.hasPrefix(SelectionCurrencyMenu.menuIdentifier.rawValue + "."))
    }

    @MainActor func testAmountsAlreadyInThePersonsCurrencyOrNotMoneyHaveNoMenu() {
        XCTAssertTrue(SelectionCurrencyMenu.elements(for: "€5", in: nil, primary: "EUR", rates: rates).isEmpty)
        XCTAssertTrue(SelectionCurrencyMenu.elements(for: "Room 101", in: nil, primary: "EUR", rates: rates).isEmpty)
        XCTAssertTrue(SelectionCurrencyMenu.elements(for: "£5", in: nil, primary: "EUR", rates: nil).isEmpty)
    }

    @MainActor func testSeveralAmountsEachSayWhatTheyWereWrittenAs() {
        let titles = SelectionCurrencyMenu.elements(for: "£5 or 20 zł", in: nil, primary: "EUR", rates: rates).map(\.title)
        XCTAssertEqual(titles.count, 2)
        XCTAssertTrue(titles[0].hasPrefix("£5 → "), titles[0])
        XCTAssertTrue(titles[1].hasPrefix("20 zł → "), titles[1])
    }

    @MainActor func testTheSystemsConversionAndCopyLinkWithHighlightAreRemoved() {
        let look = UIAction(title: "Look Up") { _ in }
        let lookup = UIMenu(identifier: .lookup, options: .displayInline, children: [look])
        let conversion = UIMenu(options: .displayInline, children: [
            UIAction(title: "66.06 GBP", identifier: .init("com.apple.datadetectors.DDConversionAction.\(UUID())")) { _ in }])
        let highlight = UIMenu(options: .displayInline, children: [
            UIAction(title: "Copy Link with Highlight", identifier: .init(SelectionTimeNativeMenu.copyLinkWithHighlight)) { _ in }])
        let root = UIMenu(children: [lookup, conversion, highlight])

        let tidied = SelectionTimeNativeMenu.removing(in: root, conversion: true)
        XCTAssertEqual(tidied.children.count, 1)
        XCTAssertTrue(tidied.children.first === lookup, "Look Up and its section are untouched")
        XCTAssertTrue(SelectionTimeNativeMenu.removing(in: tidied, conversion: true) === tidied, "Applying twice changes nothing")

        // Without an amount of Rise's, the system's conversion (as of a measurement) stays.
        let kept = SelectionTimeNativeMenu.removing(in: root, conversion: false)
        XCTAssertEqual(kept.children.count, 2)
        XCTAssertTrue(kept.children.last === conversion)
    }

    @MainActor func testReplaceOnPageSaysWhatItDid() {
        XCTAssertEqual(SelectionCurrencyMenu.replacedToast(12, in: "EUR"), "Replaced 12 prices with EUR")
        XCTAssertEqual(SelectionCurrencyMenu.replacedToast(1, in: "EUR"), "Replaced 1 price with EUR")
        XCTAssertEqual(SelectionCurrencyMenu.replacedToast(0, in: "EUR"), "No other prices to replace")
        XCTAssertEqual(SelectionCurrencyMenu.replacedToast(nil, in: "EUR"), "Original prices restored")
    }

    @MainActor func testCopyLinkWithHighlightGoesByItsTitleToo() {
        let look = UIAction(title: "Look Up") { _ in }
        let root = UIMenu(children: [look, UIAction(title: "Copy Link with Highlight") { _ in }])
        let tidied = SelectionTimeNativeMenu.removing(in: root, conversion: false)
        XCTAssertEqual(tidied.children.count, 1)
        XCTAssertTrue(tidied.children.first === look)
    }

    @MainActor func testATimeZonesConversionIsNotACurrencys() {
        let time = UIMenu(options: .displayInline, children: [
            UIAction(title: "18:00", identifier: .init("com.apple.datadetectors.DDTimeZoneConversionAction.\(UUID())")) { _ in }])
        let root = UIMenu(children: [time])
        XCTAssertTrue(SelectionTimeNativeMenu.removing(in: root, conversion: true) === root)
    }
}
