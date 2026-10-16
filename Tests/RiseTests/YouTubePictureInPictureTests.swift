import XCTest
import AppKit
import RiseCore
@testable import Rise

final class YouTubePictureInPictureTests: XCTestCase {
    private var preferenceSuites: [String] = []
    override func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        super.tearDown()
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.PiPTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let preferences = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName("")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        browser.showWindow(nil); browser.pictureInPicture.reduceMotion = { true }
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.pictureInPicture.tearDown(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }

    func testCornerButtonsScaleOnlySlightlyWithTheWindow() {
        XCTAssertEqual(FloatingVideoOverlay.controlScale(width: 360), 1, accuracy: 0.001)
        // Twice the width: about a fifth larger, far less than the window grew.
        XCTAssertEqual(FloatingVideoOverlay.controlScale(width: 720), pow(2, 0.25), accuracy: 0.001)
        XCTAssertEqual(FloatingVideoOverlay.controlScale(width: 2000), 1.2)
        XCTAssertEqual(FloatingVideoOverlay.controlScale(width: 100), 0.85)
    }

    func testYouTubeXAndGmailTitlesLoseOnlyTheirNotificationCount() {
        let youtube = URL(string: "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(TitleNotificationCount.removing(from: "(7) It's Finally Happened - YouTube", url: youtube), "It's Finally Happened - YouTube")
        XCTAssertEqual(TitleNotificationCount.removing(from: "(9+) YouTube", url: URL(string: "https://youtube.com/")), "YouTube")
        XCTAssertEqual(TitleNotificationCount.removing(from: "(2024) Film - YouTube", url: youtube), "(2024) Film - YouTube")
        XCTAssertEqual(TitleNotificationCount.removing(from: "(7) ", url: youtube), "(7) ")
        XCTAssertEqual(TitleNotificationCount.removing(from: "(7) Inbox", url: URL(string: "https://mail.example.com/")), "(7) Inbox")
        let x = URL(string: "https://x.com/SebCornelius/status/1")
        XCTAssertEqual(TitleNotificationCount.removing(from: "(7) Seb Cornelius on X: \"Building\"", url: x), "Seb Cornelius on X: \"Building\"")
        XCTAssertEqual(TitleNotificationCount.removing(from: "(20+) Home / X", url: URL(string: "https://twitter.com/home")), "Home / X")
        let gmail = URL(string: "https://mail.google.com/mail/u/0/#inbox")
        XCTAssertEqual(TitleNotificationCount.removing(from: "Inbox (49) - name@gmail.com - Gmail", url: gmail), "Inbox - name@gmail.com - Gmail")
        XCTAssertEqual(TitleNotificationCount.removing(from: "Updates (1,234) - name@gmail.com - Gmail", url: gmail), "Updates - name@gmail.com - Gmail")
        XCTAssertEqual(TitleNotificationCount.removing(from: "(1,582) - name@gmail.com - Gmail", url: gmail), "name@gmail.com - Gmail")
        XCTAssertEqual(TitleNotificationCount.removing(from: "Re: Budget (2024) - name@gmail.com - Gmail", url: gmail), "Re: Budget (2024) - name@gmail.com - Gmail",
                       "A number in an email's subject is the subject's")
        XCTAssertEqual(TitleNotificationCount.removing(from: "Inbox - name@gmail.com - Gmail", url: gmail), "Inbox - name@gmail.com - Gmail")
    }

    @MainActor func testTheRepositorySubtitleSettingIsOnByDefaultAndCanBeTurnedOff() throws {
        let browser = browser(); defer { clean(browser) }
        let title = "Show Repository Under Merge Request Tabs"
        XCTAssertTrue(browser.showsRepositorySubtitle)
        let tab = browser.addTab()
        tab.requestedURL = URL(string: "https://gitlab.com/group/project/-/merge_requests/7")
        browser.update()
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        XCTAssertTrue(row.showsSubtitle)
        browser.setShowsRepositorySubtitle(false)
        XCTAssertFalse(row.showsSubtitle)
        XCTAssertEqual(browser.makeMoreSiteMenu().items.first { $0.title == title }?.state, .off)
        XCTAssertFalse(browser.addTab().showsRepositorySubtitle, "New tabs follow the setting")
        browser.setShowsRepositorySubtitle(true)
        XCTAssertTrue(row.showsSubtitle)
        XCTAssertEqual(browser.makeMoreSiteMenu().items.first { $0.title == title }?.state, .on)
    }

    @MainActor func testUnclippedButtonsOnlyHoverOverThemselves() {
        // Popover buttons draw their shadow outside, so their visibleRect spans the whole popover.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        let button = PopoverActionButton(symbol: "ellipsis", title: "More", theme: .neutral) {}
        button.frame = NSRect(x: 180, y: 160, width: 50, height: 32); content.addSubview(button)
        XCTAssertGreaterThan(button.visibleRect.width, 4*button.bounds.width, "visibleRect alone spans the window")
        XCTAssertEqual(button.hoverRect, button.bounds)
    }

    @MainActor func testControlsShowOnHoverAndGlassControlsClickWithoutTogglingPlayback() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = FloatingVideoWindow(aspectRatio: 16.0/9, screen: screen); defer { panel.closeImmediately() }
        var closes = 0, returns = 0, toggles = 0, minimizes = 0
        panel.onClose = { closes += 1 }; panel.onReturn = { returns += 1 }; panel.onTogglePlayback = { toggles += 1 }
        panel.onMinimize = { minimizes += 1 }
        panel.orderFrontRegardless(); panel.alphaValue = 1; panel.contentView?.layoutSubtreeIfNeeded()
        let overlay = panel.overlay
        XCTAssertFalse(overlay.controlsVisible, "Controls stay hidden until the pointer is over the video")
        overlay.mouseEntered(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        XCTAssertTrue(overlay.controlsVisible)
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                panel.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }
        let video = panel.videoFrame.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        click(NSPoint(x: video.minX+26, y: video.maxY-26))
        XCTAssertEqual(closes, 1); XCTAssertEqual(toggles, 0, "A glass control click must not reach the video")
        click(NSPoint(x: video.maxX-26, y: video.maxY-26))
        XCTAssertEqual(returns, 1); XCTAssertEqual(toggles, 0)
        click(NSPoint(x: video.minX+61, y: video.maxY-26))
        XCTAssertEqual(minimizes, 1); XCTAssertEqual(toggles, 0)
        XCTAssertFalse(panel.overlay.playButton.paused)
        click(NSPoint(x: video.midX, y: video.midY))
        XCTAssertEqual(toggles, 1); XCTAssertTrue(panel.overlay.playButton.paused, "The button swaps at once")
        click(NSPoint(x: video.midX+video.width/4, y: video.midY))
        XCTAssertEqual(toggles, 2, "The rest of the picture still toggles"); XCTAssertFalse(panel.overlay.playButton.paused)
        overlay.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        XCTAssertFalse(overlay.controlsVisible)
    }
}
