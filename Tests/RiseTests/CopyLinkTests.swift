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
        XCTAssertTrue(browser.sidebar.copyButton.isShowingConfirmation)
        let notice = browser.infoPlaque
        XCTAssertTrue(notice.isPresented); XCTAssertEqual(notice.text, "Link copied")
        let share = try XCTUnwrap(notice.actionButton)
        XCTAssertEqual(share.accessibilityLabel(), "Send Link via AirDrop")
        notice.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(share.frame.minX, InfoPlaque.inset+InfoPlaque.iconSize+InfoPlaque.iconGap+InfoPlaque.width(of: "Link copied"),
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
        XCTAssertFalse(browser.sidebar.copyButton.isShowingConfirmation, "Restore the link glyph after one second")
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
        XCTAssertTrue(browser.infoPlaque.isPresented); XCTAssertEqual(browser.infoPlaque.text, "Link copied")
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
    @MainActor func testSidebarHoverAndOpenSettingsPreserveControlVisibilityGeometryAndAnchor() async throws {
        let browser = browser(); defer { clean(browser) }
        let sidebar = browser.sidebar!, frame = sidebar.copyButton.frame
        sidebar.setSidebarHovered(false, animated: false)
        let textFrame = sidebar.addressText.frame
        let hiddenEdge = try XCTUnwrap((sidebar.addressText.layer?.mask as? CAGradientLayer)?.locations?[2]).doubleValue
        XCTAssertEqual(hiddenEdge, 1, "Hidden controls leave the whole URL pill available")
        XCTAssertEqual(sidebar.copyButton.alphaValue, 0); XCTAssertFalse(sidebar.copyButton.allowsInteraction)
        XCTAssertNil(sidebar.copyButton.hitTest(NSPoint(x: frame.midX, y: frame.midY)))
        sidebar.setSidebarHovered(true)
        XCTAssertEqual(sidebar.copyButton.alphaValue, 1); XCTAssertTrue(sidebar.settingsButton.allowsInteraction)
        XCTAssertEqual(sidebar.copyButton.frame, frame)
        XCTAssertEqual(sidebar.addressText.frame, textFrame, "Animate the fade boundary without scaling or moving the glyphs")
        let shownEdge = try XCTUnwrap((sidebar.addressText.layer?.mask as? CAGradientLayer)?.locations?[2]).doubleValue
        XCTAssertLessThan(shownEdge, hiddenEdge)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotNil(sidebar.copyButton.layer?.animation(forKey: SidebarView.controlsFadeKey))
            XCTAssertNotNil(sidebar.addressText.layer?.mask?.animation(forKey: FadingTextField.fadeMovementKey))
        }
        browser.siteMenu(); sidebar.setSidebarHovered(false)
        XCTAssertFalse(sidebar.settingsButton.isHidden)
        XCTAssertEqual(sidebar.settingsButton.alphaValue, 1)
        XCTAssertEqual(sidebar.copyButton.alphaValue, 1)
        XCTAssertEqual((sidebar.addressText.layer?.mask as? CAGradientLayer)?.locations?[2].doubleValue, shownEdge)
        XCTAssertTrue(sidebar.settingsButton.allowsInteraction); XCTAssertTrue(sidebar.copyButton.allowsInteraction)
        XCTAssertEqual(sidebar.settingsAnchorRect, sidebar.address.convert(sidebar.settingsButton.bounds, from: sidebar.settingsButton))
        browser.siteControlsPopover.animates = false
        browser.siteControlsPopover.close()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(sidebar.settingsButton.alphaValue, 0); XCTAssertEqual(sidebar.copyButton.alphaValue, 0)
        XCTAssertFalse(sidebar.settingsButton.allowsInteraction)
        browser.addTab(); sidebar.setSidebarHovered(true)
        XCTAssertTrue(sidebar.copyButton.isHidden); XCTAssertTrue(sidebar.settingsButton.isHidden)
    }
}
