import AppKit
import XCTest
import RiseCore
@testable import Rise

@MainActor final class AnnotationPresentationTests: XCTestCase {
    private func context() throws -> (BrowserController, BrowserTab, String, PageAnnotation, [String: Any]) {
        _ = NSApplication.shared
        let suite = "Rise.AnnotationPresentation.\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let folder = URL.temporaryDirectory.appendingPathComponent(suite)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
        browser.window?.setContentSize(NSSize(width: 1100, height: 750)); browser.showWindow(nil)
        let tab = browser.addTab(url: URL(string: "https://example.com/article")!)
        browser.root.layoutSubtreeIfNeeded()
        let key = try XCTUnwrap(PageAnnotationStore.key(for: tab.page.url))
        var doc = AnnotationDocument()
        let note = try XCTUnwrap(doc.add(AnnotationAnchor(exact: "A passage")))
        browser.annotations.store.set(doc, for: key)
        let geometry: [String: Any] = ["rect": ["x": 200.0, "y": 180.0, "width": 21.0, "height": 21.0],
                                       "viewport": ["width": Double(tab.page.view.bounds.width), "height": Double(tab.page.view.bounds.height)]]
        addTeardownBlock { @MainActor in
            browser.annotations.close(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
            browser.suggestionFavicons.cancel(); browser.window?.orderOut(nil)
            prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder)
        }
        return (browser, tab, key, note, geometry)
    }
    private func click(_ point: NSPoint, bar: FindBar, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: bar.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                          windowNumber: bar.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func testThePanelOpensFromTheSelectionUsingTheCalendarCardsExactMotion() throws {
        let (browser, tab, key, note, geometry) = try context(), annotations = browser.annotations
        annotations.open(note.id, key: key, in: tab.page, geometry: geometry)
        let bar = annotations.bar
        XCTAssertEqual(bar.askPlaceholder.stringValue, "Ask about this selection…")
        XCTAssertFalse(bar.askPlaceholder.isHidden || bar.askPlaceholder.superview!.isHidden)
        XCTAssertEqual(bar.panel.frame.minX, 200, accuracy: 0.01)
        XCTAssertEqual(bar.panel.frame.minY, 190.5, accuracy: 0.01)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let spring = try XCTUnwrap(bar.panel.layer?.animation(forKey: CardMotionAnimator.inKeys[0]) as? CASpringAnimation)
            let expected = CASpringAnimation(perceptualDuration: CardMotion.selected.response, bounce: CardMotion.selected.bounce)
            XCTAssertEqual(spring.stiffness, expected.stiffness)
            XCTAssertEqual(spring.damping, expected.damping)
            XCTAssertEqual(spring.duration, expected.settlingDuration)
            let fade = try XCTUnwrap(bar.panel.layer?.animation(forKey: CardMotionAnimator.inKeys[1]) as? CABasicAnimation)
            XCTAssertEqual(fade.keyPath, "opacity", "The whole panel layer, including its shadow, fades together")
            XCTAssertGreaterThan(bar.panel.layer!.shadowOpacity, 0)
        }
    }
    func testClicksInsideKeepThePanelOpenAndClickingOutsideCollapsesWithoutEatingTheClick() throws {
        let (browser, tab, key, note, geometry) = try context(), annotations = browser.annotations
        annotations.open(note.id, key: key, in: tab.page, geometry: geometry)
        let bar = annotations.bar
        bar.input.stringValue = "Keep this unfinished question"
        XCTAssertFalse(annotations.handleMouseDown(click(NSPoint(x: bar.panel.frame.midX, y: bar.panel.frame.midY), bar: bar)))
        XCTAssertEqual(annotations.activeID, note.id)
        XCTAssertFalse(annotations.handleMouseDown(click(NSPoint(x: 10, y: 10), bar: bar)))
        XCTAssertNil(annotations.activeID)
        XCTAssertNil(bar.superview)
        XCTAssertEqual(annotations.store.document(for: key).annotations.first?.draft, "Keep this unfinished question")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertNotNil(annotations.collapsingPanel) }
        annotations.open(note.id, key: key, in: tab.page, geometry: geometry)
        XCTAssertNil(annotations.collapsingPanel, "Reopening cancels any outgoing stand-in")
        XCTAssertEqual(bar.input.stringValue, "Keep this unfinished question")
        XCTAssertTrue(bar.askPlaceholder.superview!.isHidden)
        annotations.close()
    }
    func testMiddleClickingTheExpandedAnnotationUsesTheSameRemovalAction() throws {
        let (browser, tab, key, note, geometry) = try context(), annotations = browser.annotations
        annotations.open(note.id, key: key, in: tab.page, geometry: geometry)
        let bar = annotations.bar
        let raw = click(NSPoint(x: bar.panel.frame.midX, y: bar.panel.frame.midY), bar: bar, type: .otherMouseDown).cgEvent!
        raw.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        let event = NSEvent(cgEvent: raw)!
        XCTAssertEqual(event.buttonNumber, 2)
        XCTAssertTrue(annotations.handleMouseDown(event))
        XCTAssertTrue(annotations.store.document(for: key).annotations.isEmpty)
        XCTAssertNil(annotations.activeID)
    }
    func testNewEmptyAnnotationsRestoreThePlaceholderAfterAnEarlierTypedQuestion() {
        let bar = FindBar()
        bar.presentAnnotation(number: 1, draft: "Earlier question", turns: [])
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.input))
        bar.closeInstantly()
        bar.presentAnnotation(number: 2, draft: "", turns: [])
        XCTAssertFalse(bar.askPlaceholder.superview!.isHidden)
        XCTAssertEqual(bar.askPlaceholder.stringValue, "Ask about this selection…")
        bar.discard()
    }
    func testBadgePaintIsTakenFromTheActualPanelInBothThemes() {
        let bar = FindBar()
        for theme in RiseTheme.allCases {
            bar.applyTheme(theme)
            let style = AnnotationAppearance.badgeStyle(panel: bar.panel, theme: theme)
            XCTAssertEqual(style["borderWidth"], "\(bar.panel.layer!.borderWidth)px")
            XCTAssertTrue(style["shadow"]!.contains("\(bar.panel.layer!.shadowRadius*2)px"))
            XCTAssertEqual(style["background"], theme == .dark ? "rgba(51,51,51,1.0)" : "rgba(248,248,248,1.0)", "Use the panel's opaque background in each theme")
        }
        bar.discard()
    }
    func testTheLandedSurfaceStaysUntilTheRendererIsReadyAndFinishesExactlyOnce() throws {
        let (browser, _, _, _, _) = try context()
        let ghost = AnnotationCollapse(number: 1, theme: .neutral, snapshot: nil)
        browser.pageClip.addSubview(ghost)
        let target = NSRect(x: 200, y: 180, width: 21, height: 21)
        var arrived = false, finished = 0
        ghost.start(from: NSRect(x: 200, y: 190, width: 360, height: 120), to: target,
                    arrived: { arrived = true }, done: { finished += 1 })
        let end = Date().addingTimeInterval(1)
        while !arrived, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(arrived)
        XCTAssertTrue(ghost.superview === browser.pageClip, "Landing must not remove the surface before a page paint")
        XCTAssertEqual(ghost.frame, target)
        XCTAssertEqual(ghost.panel.layer?.shadowPath?.boundingBox, ghost.panel.bounds, "The shadow follows the shrinking surface's current outline")
        XCTAssertGreaterThan(ghost.panel.layer!.shadowOpacity, 0, "The shadow is already present when the surface lands")
        XCTAssertEqual(finished, 0)
        ghost.fadeToBadge()
        let fadeEnd = Date().addingTimeInterval(1)
        while finished == 0, Date() < fadeEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertNil(ghost.superview)
        XCTAssertEqual(finished, 1)
        ghost.finish(); XCTAssertEqual(finished, 1)
    }
    func testSwitchingTabsCancelsTheCollapseAndItsPendingHandoff() throws {
        let (browser, tab, key, note, geometry) = try context(), annotations = browser.annotations
        annotations.open(note.id, key: key, in: tab.page, geometry: geometry)
        annotations.collapse()
        _ = browser.addTab(url: URL(string: "https://example.com/other")!)
        XCTAssertNil(annotations.collapsingPanel, "A previous tab's surface cannot sit over the new page")
    }
}
