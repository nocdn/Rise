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
        browser.siteControlsPopover.animates = false; browser.siteControlsPopover.close(); browser.infoPlaque.hide()
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        browser.linkPasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testCopyWritesFullURLAndAirDropButtonKeepsTheCopiedDestination() async throws {
        let browser = browser(); defer { clean(browser) }
        let url = browser.selectedTab!.url!
        browser.copyURL()
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), url.absoluteString)
        XCTAssertTrue(browser.navBar.copyButton.isShowingConfirmation)
        let notice = browser.infoPlaque
        XCTAssertTrue(notice.isPresented); XCTAssertEqual(notice.text, "Copied current URL")
        let share = try XCTUnwrap(notice.actionButton)
        XCTAssertEqual(share.accessibilityLabel(), "Send Link via AirDrop")
        notice.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(share.frame.minX, InfoPlaque.inset+InfoPlaque.iconSize+InfoPlaque.iconGap+InfoPlaque.width(of: "Copied current URL"),
                                    "The share button comes after the text")
        let center = notice.convert(NSPoint(x: share.bounds.midX, y: share.bounds.midY), from: share)
        XCTAssertTrue(notice.hitTest(notice.convert(center, to: notice.superview)) === share, "The share button takes clicks")
        XCTAssertNil(notice.hitTest(notice.convert(NSPoint(x: notice.panel.frame.minX+4, y: notice.panel.frame.midY), to: notice.superview)),
                     "The rest of the notice leaves clicks to the page")
        var shared: URL?
        browser.airDropHandler = { shared = $0 }
        browser.selectedTab?.requestedURL = URL(string: "https://different.example")
        share.performClick(nil)
        XCTAssertEqual(shared, url); XCTAssertFalse(notice.isPresented, "Sharing puts the notice away")
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(browser.navBar.copyButton.isShowingConfirmation, "Restore the link glyph after one second")
        // The pointer over a notice with a button holds it until it leaves.
        browser.selectedTab?.requestedURL = url; browser.copyURL()
        notice.setHovered(true)
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertTrue(notice.isPresented)
        notice.setHovered(false)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(notice.isPresented)
        // Other notices have no button and never wait for the pointer.
        browser.showInfo("Simulated full screen enabled", image: InfoPlaque.fullScreenIcon)
        XCTAssertNil(notice.actionButton)
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
        XCTAssertFalse(browser.sidebarVisible, "The notice needs no sidebar to point from")
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), browser.selectedTab!.url!.absoluteString)
        XCTAssertTrue(browser.infoPlaque.isPresented); XCTAssertEqual(browser.infoPlaque.text, "Copied current URL")
        // Each press holds the notice for another full second.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: key))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(browser.infoPlaque.isPresented, "Pressing again restarts the dismiss timer")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(browser.infoPlaque.isPresented)
        browser.addTab()
        browser.linkPasteboard.clearContents(); browser.copyURL()
        XCTAssertNil(browser.linkPasteboard.string(forType: .string), "Blank tabs have no link to copy")
        XCTAssertFalse(browser.infoPlaque.isPresented)
    }
    @MainActor func testOptionClickCopiesTheLinkWithoutAShareButtonAndShiftStillPeeks() {
        let browser = browser(); defer { clean(browser) }
        XCTAssertTrue(browser.shouldCopyLink(modifiers: .option)); XCTAssertFalse(browser.shouldPeek(modifiers: .option))
        XCTAssertFalse(browser.shouldCopyLink(modifiers: [.option, .shift])); XCTAssertTrue(browser.shouldPeek(modifiers: .shift))
        let link = URL(string: "https://example.com/linked")!
        browser.copyLink(link)
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), link.absoluteString)
        XCTAssertEqual(browser.infoPlaque.text, "Link copied"); XCTAssertNil(browser.infoPlaque.actionButton)
        XCTAssertFalse(browser.navBar.copyButton.isShowingConfirmation, "That's for the page's own address")
    }
}
