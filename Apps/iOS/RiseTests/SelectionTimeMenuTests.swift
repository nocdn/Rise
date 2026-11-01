import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class SelectionTimeMenuTests: XCTestCase {
    @MainActor private func selection(in page: WKWebView, becomes expected: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while SelectionTimeMenu.selection(in: page) != expected, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(SelectionTimeMenu.selection(in: page), expected)
    }

    @MainActor func testTheSelectedTimeInAnyFrameOrFieldLeadsTheMenuWithItsActions() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), page = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        page.frame = window.bounds; window.rootViewController?.view.addSubview(page)
        page.loadHTMLString("<p id=p>Starts at 10am PST.</p><input id=f value='Call 9:30 CET'><iframe srcdoc='<b id=t>11pm PST</b>'></iframe>", baseURL: nil)
        for _ in 0..<250 where (try? await page.evaluateJavaScript("document.querySelector('iframe').contentDocument?.readyState")) as? String != "complete" {
            try await Task.sleep(for: .milliseconds(20))
        }
        func select(_ script: String) async throws { _ = try await page.callAsyncJavaScript(script, contentWorld: .page) }

        try await select("getSelection().selectAllChildren(document.getElementById('p'))")
        try await selection(in: page, becomes: "Starts at 10am PST.")
        try await select("const d = document.querySelector('iframe').contentDocument; d.getSelection().selectAllChildren(d.getElementById('t'))")
        try await selection(in: page, becomes: "11pm PST")
        let now = Date(), menus = SelectionTimeMenu.elements(for: SelectionTimeMenu.selection(in: page), in: page, now: now).compactMap { $0 as? UIMenu }
        let time = try XCTUnwrap(SelectionTimes.find(in: "11pm PST", now: now).first)
        XCTAssertEqual(menus.map(\.title), [SelectionTimes.label(time, now: now)])
        XCTAssertEqual(menus.first?.children.map(\.title), ["Copy “\(SelectionTimes.copied(time, now: now))”", "Replace on Page", "Add to Calendar", "Add to Reminders", "Show in Calendar"])

        // The page clearing its own selection leaves the frame's, the one selected last.
        try await select("getSelection().removeAllRanges()")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(SelectionTimeMenu.selection(in: page), "11pm PST")
        try await select("const f = document.getElementById('f'); f.focus(); f.setSelectionRange(5, 13)")
        try await selection(in: page, becomes: "9:30 CET")
        try await select("const f = document.getElementById('f'); f.setSelectionRange(0, 0); f.blur()")
        try await selection(in: page, becomes: "")
        let local = SelectionTimeMenu.elements(for: "5pm", in: page).compactMap { $0 as? UIMenu }
        // An unzoned clock can offer calendar actions, but cannot offer a timezone conversion.
        XCTAssertTrue(local.allSatisfy { $0.identifier == SelectionTimeMenu.eventIdentifier
            && !$0.children.contains { ($0 as? UIAction)?.identifier.rawValue == "dev.bartosz.Rise.replaceTimes" } })
    }

    @MainActor func testReplaceActionConvertsTheRealPageAndItsCheckedActionRestoresIt() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), page = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        page.frame = window.bounds; window.rootViewController?.view.addSubview(page)
        page.loadHTMLString("<p id=p>10 AM PT</p><p id=q>2026-12-01T10:00:00Z</p>", baseURL: nil)
        func text() async throws -> String? {
            try await page.evaluateJavaScript("document.querySelector('#p')?.textContent ?? ''") as? String
        }
        for _ in 0..<250 {
            if try await text() == "10 AM PT" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let menu = try XCTUnwrap(SelectionTimeMenu.elements(for: "10 AM PT", in: page).first as? UIMenu)
        let replace = try XCTUnwrap(menu.children.compactMap { $0 as? UIAction }.first { $0.title == "Replace on Page" })
        XCTAssertEqual(replace.state, .off)
        func press(_ action: UIAction) { let button = UIButton(); button.addAction(action, for: .touchUpInside); button.sendActions(for: .touchUpInside) }
        press(replace)
        var converted: String?
        for _ in 0..<250 {
            converted = try await text()
            if let converted, converted != "10 AM PT" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(converted, "10 AM PT")
        XCTAssertTrue(SelectionTimeMenu.isTimeReplaced(in: page))
        let updated = try XCTUnwrap(SelectionTimeMenu.elements(for: try XCTUnwrap(converted), in: page).first as? UIMenu)
        let restore = try XCTUnwrap(updated.children.compactMap { $0 as? UIAction }.first { $0.title == "Replace on Page" })
        XCTAssertEqual(restore.state, .on)
        press(restore)
        for _ in 0..<250 {
            if try await text() == "10 AM PT" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = try await text()
        XCTAssertEqual(restored, "10 AM PT")
        XCTAssertFalse(SelectionTimeMenu.isTimeReplaced(in: page))
    }

    @MainActor func testCalendarLinkUsesTheAbsoluteInstantRatherThanLocalClockComponents() throws {
        let date = Date(timeIntervalSinceReferenceDate: 123456789)
        let url = SelectionTimeMenu.calendarURL(for: date)
        XCTAssertEqual(url.scheme, "calshow")
        XCTAssertEqual(Double(url.absoluteString.dropFirst("calshow:".count)), date.timeIntervalSinceReferenceDate)
    }

    @MainActor func testAZoneOnlySelectionOffersACopyOfTheCurrentTimeWithoutAppointmentActions() throws {
        let now = Date(timeIntervalSince1970: 1_792_764_000)
        let menus = SelectionTimeMenu.elements(for: "UTC+14:00", in: nil, now: now).compactMap { $0 as? UIMenu }
        let menu = try XCTUnwrap(menus.first)
        XCTAssertEqual(menus.count, 1)
        XCTAssertTrue(menu.title.contains("there"))
        XCTAssertEqual(menu.children.count, 1)
        let action = try XCTUnwrap(menu.children.first as? UIAction)
        XCTAssertTrue(action.title.hasPrefix("Copy “"))
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        let button = UIButton(); button.addAction(action, for: .touchUpInside); button.sendActions(for: .touchUpInside)
        let copied = try XCTUnwrap(UIPasteboard.general.string)
        XCTAssertTrue(copied.contains("2026"))
        XCTAssertTrue(copied.hasSuffix("UTC+14:00"))
    }
}
