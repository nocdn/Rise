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
        browser.copiedLinkPopover.animates = false; browser.siteControlsPopover.animates = false
        browser.copiedLinkPopover.close(); browser.siteControlsPopover.close()
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        browser.linkPasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testCopyWritesFullURLAndAirDropButtonKeepsTheCopiedDestination() async throws {
        let browser = browser(); defer { clean(browser) }
        let url = browser.selectedTab!.url!
        browser.copyURL()
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), url.absoluteString)
        let content = try XCTUnwrap(browser.copiedLinkPopover.contentViewController as? CopiedLinkController)
        XCTAssertEqual(content.message.stringValue, "Link copied")
        XCTAssertEqual(content.url, url)
        XCTAssertEqual(browser.copiedLinkPopover.behavior, .transient)
        var shared: URL?
        browser.airDropHandler = { shared = $0 }
        browser.selectedTab?.requestedURL = URL(string: "https://different.example")
        // XCTest has no NSApplication.run animation loop. The native-window
        // harness separately verifies animated opening and dismissal.
        browser.copiedLinkPopover.animates = false
        content.shareButton.performClick(nil)
        XCTAssertEqual(shared, url)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(browser.copiedLinkPopover.isShown)
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
        XCTAssertTrue(browser.sidebarVisible)
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), browser.selectedTab!.url!.absoluteString)
        browser.copiedLinkPopover.animates = false
        browser.addTab(); try await Task.sleep(for: .milliseconds(350)); XCTAssertFalse(browser.copiedLinkPopover.isShown)
        browser.linkPasteboard.clearContents(); browser.copyURL()
        XCTAssertNil(browser.linkPasteboard.string(forType: .string), "Blank tabs have no link to copy")
    }
    @MainActor func testSidebarHoverFadesIconsWithoutChangingTheirGeometryOrPopoverAnchor() throws {
        let browser = browser(); defer { clean(browser) }
        let sidebar = browser.sidebar!, frame = sidebar.copyButton.frame
        sidebar.setSidebarHovered(false, animated: false)
        XCTAssertEqual(sidebar.copyButton.alphaValue, 0); XCTAssertFalse(sidebar.copyButton.allowsInteraction)
        XCTAssertNil(sidebar.copyButton.hitTest(NSPoint(x: frame.midX, y: frame.midY)))
        sidebar.setSidebarHovered(true)
        XCTAssertEqual(sidebar.copyButton.alphaValue, 1); XCTAssertTrue(sidebar.settingsButton.allowsInteraction)
        XCTAssertEqual(sidebar.copyButton.frame, frame)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotNil(sidebar.copyButton.layer?.animation(forKey: SidebarView.controlsFadeKey))
        }
        browser.siteMenu(); sidebar.setSidebarHovered(false)
        XCTAssertFalse(sidebar.settingsButton.isHidden)
        XCTAssertEqual(sidebar.settingsButton.alphaValue, 0)
        XCTAssertFalse(sidebar.settingsButton.allowsInteraction)
        XCTAssertEqual(sidebar.settingsAnchorRect, sidebar.address.convert(sidebar.settingsButton.bounds, from: sidebar.settingsButton))
        browser.addTab(); sidebar.setSidebarHovered(true)
        XCTAssertTrue(sidebar.copyButton.isHidden); XCTAssertTrue(sidebar.settingsButton.isHidden)
    }
}
