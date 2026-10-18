import XCTest
import AppKit
@testable import Rise

final class CardMotionTests: XCTestCase {
    /// Option 3 at six speeds, itself among them.
    func testPresetsAreOptionThreeAtSixSpeeds() {
        let names = CardMotion.presets.map(\.name)
        XCTAssertEqual(names.count, 6); XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(CardMotion.presets.allSatisfy { $0.origin == .tab && $0.scaleIn == 0.8 && $0.bounce == 0.3 && $0.scaleOut == 0.88 })
        XCTAssertEqual(CardMotion.presets.map(\.response), [0.18, 0.21, 0.24, 0.26, 0.29, 0.33])
        let three = CardMotion.presets[3]
        XCTAssertEqual(three.name, "Spring 0.26 s (option 3)")
        XCTAssertEqual(three.fadeIn, 0.1, accuracy: 0.0001); XCTAssertEqual(three.outDuration, 0.12, accuracy: 0.0001)
        XCTAssertTrue(CardMotion.presets.allSatisfy { !$0.summary.isEmpty })
    }
    func testThePickIsRemembered() {
        let defaults = UserDefaults.standard, kept = defaults.string(forKey: CardMotion.preferenceKey)
        defer { if let kept { defaults.set(kept, forKey: CardMotion.preferenceKey) } else { defaults.removeObject(forKey: CardMotion.preferenceKey) } }
        CardMotion.select(CardMotion.presets[4])
        XCTAssertEqual(CardMotion.selected, CardMotion.presets[4])
        defaults.set("gone", forKey: CardMotion.preferenceKey)
        XCTAssertEqual(CardMotion.selected, CardMotion.presets[0], "An unknown pick falls back to the first")
    }
    /// The Calendar card springs in and stays up through its way out, then hides.
    @MainActor func testTheCalendarCardComesAndGoesWithThePick() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, kept = defaults.string(forKey: CardMotion.preferenceKey)
        defer { if let kept { defaults.set(kept, forKey: CardMotion.preferenceKey) } else { defaults.removeObject(forKey: CardMotion.preferenceKey) } }
        let agenda = CalendarAgenda(), card = CalendarTooltip()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(animated: false); agenda.tearDown(); window.orderOut(nil) }
        CardMotion.select(CardMotion.presets[3])
        card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .neutral)
        XCTAssertNotNil(card.layer?.animation(forKey: CardMotionAnimator.inKeys[0]))
        XCTAssertNotNil(card.layer?.animation(forKey: CardMotionAnimator.inKeys[1]))
        card.dismiss()
        XCTAssertFalse(card.isHidden, "It plays its way out first")
        XCTAssertNil(card.hitTest(NSPoint(x: 20, y: 30)), "but takes no clicks")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(card.isHidden)
        // Back before the way out ends: it stays.
        card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .neutral)
        card.dismiss(); card.present(key: "test", agenda: agenda, left: 10, anchorTop: 20, maxBottom: 680, theme: .neutral)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(card.isHidden)
        card.dismiss(animated: false)
        XCTAssertTrue(card.isHidden, "Without animation it goes at once")
    }

    /// ← and → flick through the motions while the tester is on, and the label says which.
    @MainActor func testArrowsFlickThroughTheMotions() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, kept = defaults.string(forKey: CardMotion.preferenceKey)
        defer { if let kept { defaults.set(kept, forKey: CardMotion.preferenceKey) } else { defaults.removeObject(forKey: CardMotion.preferenceKey) } }
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        browser.showWindow(nil)
        let tester = CardMotionTester.shared
        defer { tester.stop(); browser.saveWork?.cancel(); browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent()) }
        CardMotion.select(CardMotion.presets[0])
        browser.toggleCardMotionTester()
        XCTAssertTrue(tester.isOn)
        XCTAssertTrue(tester.label.superview === browser.root)
        XCTAssertEqual(tester.label.title.stringValue, "←  1 of 6 · Spring 0.18 s  →")
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [.function, .numericPad]) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: browser.window!.windowNumber,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(tester.handles(key(124))); XCTAssertTrue(tester.handles(key(123)))
        XCTAssertFalse(tester.handles(key(124, [.command, .function])), "⌘→ stays the page's")
        XCTAssertTrue(tester.handles(key(126))); XCTAssertTrue(tester.handles(key(125)))
        let keptDelay = defaults.object(forKey: CardMotion.delayKey)
        defer { if let keptDelay { defaults.set(keptDelay, forKey: CardMotion.delayKey) } else { defaults.removeObject(forKey: CardMotion.delayKey) } }
        defaults.removeObject(forKey: CardMotion.delayKey)
        XCTAssertEqual(CardMotion.hoverDelay, 0.2, "The wait picked in the tester to begin with")
        tester.adjustDelay(1); tester.adjustDelay(1)
        XCTAssertEqual(CardMotion.hoverDelay, 0.3, accuracy: 0.0001)
        XCTAssertEqual(tester.label.delay.stringValue, "↑↓  Opens after 0.30 s")
        tester.adjustDelay(-40)
        XCTAssertEqual(CardMotion.hoverDelay, 0, "Never below nothing")
        tester.adjustDelay(3)
        tester.step(1); tester.step(-1)
        XCTAssertEqual(CardMotion.hoverDelay, 0.15, accuracy: 0.0001, "The same for every motion")
        tester.step(1)
        XCTAssertEqual(CardMotion.selected, CardMotion.presets[1])
        XCTAssertTrue(tester.label.title.stringValue.contains("2 of 6 · Spring 0.21 s"))
        tester.step(-1); tester.step(-1)
        XCTAssertEqual(CardMotion.selected, CardMotion.presets.last, "It wraps round")
        if let shots = ProcessInfo.processInfo.environment["RISE_LINK_SHOTS"], let number = browser.window?.windowNumber {
            try await Task.sleep(for: .milliseconds(300))
            let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", "\(number)", "\(shots)/tester.png"]
            try shot.run(); shot.waitUntilExit()
        }
        browser.toggleCardMotionTester()
        XCTAssertFalse(tester.isOn); XCTAssertNil(tester.label.superview)
        XCTAssertFalse(tester.handles(key(124)), "Off, the arrows are the page's again")
    }

    /// Beside a pinned tile, the card comes out of the tile's bottom-right corner: the one point the scale leaves in place.
    @MainActor func testTheCardGrowsFromAPinnedTilesCorner() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, kept = defaults.string(forKey: CardMotion.preferenceKey)
        defer { if let kept { defaults.set(kept, forKey: CardMotion.preferenceKey) } else { defaults.removeObject(forKey: CardMotion.preferenceKey) } }
        let agenda = CalendarAgenda(), card = CalendarTooltip()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(animated: false); agenda.tearDown(); window.orderOut(nil) }
        CardMotion.select(CardMotion.presets[3])
        let corner = NSPoint(x: 80, y: 140)
        card.present(key: "test", agenda: agenda, left: 100, anchorTop: 140, maxBottom: 680, theme: .neutral, growsFrom: corner)
        let spring = try XCTUnwrap(card.layer?.animation(forKey: CardMotionAnimator.inKeys[0]) as? CASpringAnimation)
        let from = try XCTUnwrap(spring.fromValue as? NSValue).caTransform3DValue, scale = CardMotion.presets[3].scaleIn
        XCTAssertEqual(from.m11, scale, accuracy: 0.0001)
        XCTAssertEqual(from.m41/(1-scale), corner.x-card.frame.minX, accuracy: 0.01, "Left of the card, at the tile's right edge")
        XCTAssertEqual(from.m42/(1-scale), corner.y-card.frame.minY, accuracy: 0.01, "Level with the tile's bottom")
    }

    /// The pull request and Gmail cards beside tabs come and go the same way; over a link the
    /// pull request card keeps its own.
    @MainActor func testThePullRequestAndGmailCardsMoveTheSameWay() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, kept = defaults.string(forKey: CardMotion.preferenceKey)
        defer { if let kept { defaults.set(kept, forKey: CardMotion.preferenceKey) } else { defaults.removeObject(forKey: CardMotion.preferenceKey) } }
        CardMotion.select(CardMotion.presets[0])
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        let pr = PullRequestTooltip(), inbox = GmailInbox(), gmail = GmailTooltip()
        window.contentView?.addSubview(pr); window.contentView?.addSubview(gmail); window.orderFront(nil)
        defer { pr.dismiss(immediately: true); gmail.dismiss(animated: false); window.orderOut(nil) }
        let content = PullRequestTooltip.Content(title: "fix: it", reference: "#1", details: nil, summary: "Fixes it.", phase: .done)
        pr.present(key: "a", content: content, left: 10, placement: .beside(top: 20, maxBottom: 680), theme: .neutral, fromTab: true)
        XCTAssertNotNil(pr.layer?.animation(forKey: CardMotionAnimator.inKeys[0]))
        gmail.present(key: "g", inbox: inbox, left: 10, anchorTop: 20, maxBottom: 680, theme: .neutral)
        XCTAssertNotNil(gmail.layer?.animation(forKey: CardMotionAnimator.inKeys[0]))
        pr.dismiss(); gmail.dismiss()
        XCTAssertFalse(pr.isHidden); XCTAssertFalse(gmail.isHidden)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(pr.isHidden); XCTAssertTrue(gmail.isHidden)
        pr.present(key: "b", content: content, left: 10, placement: .beside(top: 20, maxBottom: 680), theme: .neutral)
        XCTAssertNil(pr.layer?.animation(forKey: CardMotionAnimator.inKeys[0]), "Not over a link")
        pr.dismiss()
        XCTAssertTrue(pr.isHidden)
    }
}
