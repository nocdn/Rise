import XCTest
import AppKit
@testable import Rise

final class LinkPeekMenuTests: XCTestCase {
    private func webKitMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, id) in [("Open Link", "WKMenuItemIdentifierOpenLink"), ("Open Link in New Window", "WKMenuItemIdentifierOpenLinkInNewWindow"),
                            ("Download Linked File", "WKMenuItemIdentifierDownloadLinkedFile"), ("Copy Link", "WKMenuItemIdentifierCopyLink")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.identifier = .init(id); menu.addItem(item)
        }
        return menu
    }
    @MainActor func testLinkMenuOpensTheLinkInAPeekButNotFromInsideOne() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.window?.setFrameAutosaveName(""); browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000)); browser.showWindow(nil)
        defer {
            browser.closePeek(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        let tab = browser.addTab(); browser.update(); browser.root.layoutSubtreeIfNeeded()
        let web = try XCTUnwrap(tab.webView as? LinkCursorWebView)
        let link = URL(string: "https://example.com/story")!
        browser.showHoveredLink(link, in: web)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: browser.window!.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = webKitMenu()
        web.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.map(\.title), ["Open Link", "Open Link in New Window", "Open Link in Peek", "Download Linked File", "Copy Link"])
        let item = menu.items[2]
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        XCTAssertNotNil(browser.peekTab); XCTAssertEqual(browser.peekTab?.requestedURL ?? browser.peekTab?.url, link)
        let peek = try XCTUnwrap(browser.peekTab?.webView as? LinkCursorWebView)
        browser.showHoveredLink(URL(string: "https://example.com/inner")!, in: peek)
        let inner = webKitMenu(); peek.willOpenMenu(inner, with: event)
        XCTAssertFalse(inner.items.contains { $0.title == "Open Link in Peek" }, "A Peek can't open another Peek")
        let plain = NSMenu(); plain.addItem(withTitle: "Reload", action: nil, keyEquivalent: "")
        web.willOpenMenu(plain, with: event)
        XCTAssertEqual(plain.items.count, 1, "Menus without a link are left alone")
    }
}
