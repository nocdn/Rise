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
        XCTAssertEqual(menus.first?.children.map(\.title), ["Copy “\(SelectionTimes.copied(time, now: now))”", "Add to Calendar"])

        // The page clearing its own selection leaves the frame's, the one selected last.
        try await select("getSelection().removeAllRanges()")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(SelectionTimeMenu.selection(in: page), "11pm PST")
        try await select("const f = document.getElementById('f'); f.focus(); f.setSelectionRange(5, 13)")
        try await selection(in: page, becomes: "9:30 CET")
        try await select("const f = document.getElementById('f'); f.setSelectionRange(0, 0); f.blur()")
        try await selection(in: page, becomes: "")
        XCTAssertTrue(SelectionTimeMenu.elements(for: "5pm", in: page).isEmpty)
    }
}
