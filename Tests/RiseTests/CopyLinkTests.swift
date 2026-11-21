import XCTest
import AppKit
@testable import Rise

final class CopyLinkTests: XCTestCase {
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        browser.linkPasteboard = .withUniqueName()
        browser.showWindow(nil)
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/a?b=1#section")
        browser.update(); browser.root.layoutSubtreeIfNeeded()
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.siteControlsPopover.animates = false; browser.siteControlsPopover.close()
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        browser.linkPasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testCopyWritesFullURLAndSaysSoInTheAddressesPlace() async throws {
        let browser = browser(); defer { clean(browser) }
        let url = browser.selectedTab!.url!, bar = browser.navBar
        browser.copyURL()
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), url.absoluteString)
        XCTAssertTrue(bar.copyButton.isShowingConfirmation)
        let notice = try XCTUnwrap(bar.notice)
        XCTAssertTrue(bar.isShowingCopied); XCTAssertEqual(notice.text, "Copied Current URL")
        XCTAssertEqual(notice.alphaValue, 1); XCTAssertEqual(bar.text.alphaValue, 0, "The words take the address's place")
        bar.layoutSubtreeIfNeeded()
        let link = bar.convert(NSPoint(x: BarNotice.inkStart, y: 0), from: notice).x
        XCTAssertEqual(link, PlainNavBar.Metrics.textX-1, accuracy: 0.01, "The link's ink a point before the address's")
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertNil(bar.notice); XCTAssertEqual(bar.text.alphaValue, 1)
        XCTAssertNil(notice.superview, "Words that have gone are done with")
        XCTAssertFalse(bar.copyButton.isShowingConfirmation, "Restore the link glyph after one second")
        // Another page puts them away at once.
        browser.copyURL(); XCTAssertTrue(bar.isShowingCopied)
        bar.show(url: URL(string: "https://different.example"), title: "")
        XCTAssertFalse(bar.isShowingCopied)
    }
    @MainActor func testShortcutAndHiddenSidebarCopy() async throws {
        let browser = browser(); defer { clean(browser) }
        let oldMenu = NSApp.mainMenu; defer { NSApp.mainMenu = oldMenu }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        let entry = try XCTUnwrap(NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.first { $0.action == #selector(BrowserController.copyURL) })
        XCTAssertEqual(entry.keyEquivalent, "C"); XCTAssertEqual(entry.keyEquivalentModifierMask, [.command, .shift])
        browser.toggleSidebar(); XCTAssertFalse(browser.sidebarVisible)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command,.shift], timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, characters: "C", charactersIgnoringModifiers: "C", isARepeat: false, keyCode: 8)!
        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: key))
        XCTAssertFalse(browser.sidebarVisible, "Copying needs no sidebar")
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), browser.selectedTab!.url!.absoluteString)
        XCTAssertTrue(browser.navBar.isShowingCopied)
        // Each press holds the words for longer.
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: key))
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(browser.navBar.isShowingCopied, "Pressing again restarts the timer")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(browser.navBar.isShowingCopied)
        browser.addTab()
        browser.linkPasteboard.clearContents(); browser.copyURL()
        XCTAssertNil(browser.linkPasteboard.string(forType: .string), "Blank tabs have no link to copy")
        XCTAssertFalse(browser.navBar.isShowingCopied)
    }
    @MainActor func testOptionClickCopiesTheLinkWithoutAShareButtonAndShiftStillPeeks() {
        let browser = browser(); defer { clean(browser) }
        XCTAssertTrue(browser.shouldCopyLink(modifiers: .option)); XCTAssertFalse(browser.shouldPeek(modifiers: .option))
        XCTAssertFalse(browser.shouldCopyLink(modifiers: [.option, .shift])); XCTAssertTrue(browser.shouldPeek(modifiers: .shift))
        let link = URL(string: "https://example.com/linked")!
        browser.copyLink(link)
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), link.absoluteString)
        XCTAssertEqual(browser.navBar.notice?.text, "Copied Link")
        XCTAssertFalse(browser.navBar.copyButton.isShowingConfirmation, "That's for the page's own address")
    }
    @MainActor func testRightClickingTheAddressOffersCopyingPastingAndEditing() throws {
        let browser = browser(); defer { clean(browser) }
        let oldMenu = NSApp.mainMenu; defer { NSApp.mainMenu = oldMenu }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        let bar = browser.navBar, tab = try XCTUnwrap(browser.selectedTab)
        tab.title = "A [page]"
        bar.layoutSubtreeIfNeeded()
        func click(_ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: .rightMouseDown, location: bar.convert(NSPoint(x: x, y: PlainNavBar.Metrics.midY), to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        XCTAssertNil(bar.menu(for: click(bar.fieldRect.maxX+40)), "Only on the address")
        browser.linkPasteboard.clearContents()
        let menu = try XCTUnwrap(bar.menu(for: click(bar.fieldRect.midX)))
        // Share and AirDrop in a section of their own, as a link's menu on the page has them; AirDrop
        // only where it's on.
        let airDrop = AirDropMenuItem.canSend([try XCTUnwrap(tab.url)]) ? ["AirDrop"] : []
        XCTAssertEqual(menu.items.map(\.title), ["Copy URL", "Copy as Markdown Link", "", "Paste and Go", "Edit Address", "", "Share…"]+airDrop)
        XCTAssertNotNil(menu.items[6].image, "Share keeps its icon here")
        XCTAssertEqual(menu.items[0].keyEquivalent, "C"); XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(menu.items[4].keyEquivalent, "l")
        XCTAssertFalse(menu.items[3].isEnabled, "Nothing to paste")
        menu.performActionForItem(at: 0)
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), tab.url?.absoluteString)
        XCTAssertTrue(bar.isShowingCopied, "Said in the bar, as ⇧⌘C does")
        menu.performActionForItem(at: 1)
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), "[A \\[page\\]](https://example.com/a?b=1#section)")
        XCTAssertEqual(bar.notice?.text, "Copied Markdown Link")
        browser.linkPasteboard.clearContents(); browser.linkPasteboard.setString("  example.org/next \n", forType: .string)
        let again = try XCTUnwrap(bar.menu(for: click(bar.fieldRect.midX)))
        XCTAssertTrue(again.items[3].isEnabled)
        again.performActionForItem(at: 3)
        XCTAssertEqual(tab.requestedURL?.host, "example.org")
    }
}
