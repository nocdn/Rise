import XCTest
import AppKit
@testable import Rise

final class PanelVeilTests: XCTestCase {
    @MainActor private func makeBrowser() -> BrowserController {
        _ = NSApplication.shared
        return BrowserController(sessionURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.cancelTabSwitch(); browser.hidePalette(); browser.veil.hide(animated: false)
        browser.suggestionFavicons.cancel(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
        browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    private func curve(_ animation: CAAnimation?) -> [Float] {
        guard let function = animation?.timingFunction else { return [] }
        return (0..<4).flatMap { index -> [Float] in
            var point: [Float] = [0, 0]
            function.getControlPoint(at: index, values: &point)
            return point
        }
    }

    @MainActor func testBothPanelsUseOneVeilWithIdenticalColorsAndEntryAndExitAnimations() async throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let appearance = NSApp.appearance; defer { NSApp.appearance = appearance }
        browser.addTab(); browser.addTab(); browser.showWindow(nil)
        for theme in [RiseTheme.neutral, .dark] {
            browser.theme = theme; browser.update()
            browser.newTab()
            let veil = browser.veil
            let color = try XCTUnwrap(veil.layer?.backgroundColor)
            XCTAssertEqual(try XCTUnwrap(NSColor(cgColor: color)).alphaComponent, theme == .dark ? 0.35 : 0.12, accuracy: 0.001)
            XCTAssertNil(veil.hitTest(NSPoint(x: 10, y: 10)), "The palette's dismiss surface owns its clicks")
            let paletteIn = veil.layer?.animation(forKey: PanelVeil.animationKey)
            try await Task.sleep(for: .milliseconds(180))
            browser.hidePalette()
            let paletteOut = veil.layer?.animation(forKey: PanelVeil.animationKey)
            try await Task.sleep(for: .milliseconds(110))
            XCTAssertTrue(veil.isHidden)
            browser.advanceTabSwitch(1); browser.advanceTabSwitch(1)
            XCTAssertFalse(browser.tabSwitcher.isHidden)
            XCTAssertTrue(browser.veil === veil, "The view itself is shared")
            XCTAssertEqual(veil.layer?.backgroundColor, color)
            let switcherIn = veil.layer?.animation(forKey: PanelVeil.animationKey)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertEqual(switcherIn?.duration, PanelVeil.fadeInDuration)
                XCTAssertEqual(switcherIn?.duration, paletteIn?.duration)
                XCTAssertEqual(curve(switcherIn), curve(paletteIn))
            }
            let views = browser.root.subviews
            XCTAssertLessThan(try XCTUnwrap(views.firstIndex { $0 === veil }), try XCTUnwrap(views.firstIndex { $0 === browser.tabSwitcher }))
            XCTAssertNotNil(veil.hitTest(NSPoint(x: 10, y: 10)), "The switcher's shared veil dismisses on outside clicks")
            browser.cancelTabSwitch()
            XCTAssertNil(veil.hitTest(NSPoint(x: 10, y: 10)), "Exit never swallows the next click")
            let switcherOut = veil.layer?.animation(forKey: PanelVeil.animationKey)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertEqual(switcherOut?.duration, PanelVeil.fadeOutDuration)
                XCTAssertEqual(switcherOut?.duration, paletteOut?.duration)
                XCTAssertEqual(curve(switcherOut), curve(paletteOut))
            }
            try await Task.sleep(for: .milliseconds(110))
            XCTAssertTrue(veil.isHidden)
        }
    }

    @MainActor func testRapidPanelHandoffsKeepOneVeilVisibleAndRestoreItsClickAndStackingBehavior() async throws {
        let browser = makeBrowser(); defer { clean(browser) }
        browser.addTab(); browser.addTab(); browser.showWindow(nil); browser.newTab()
        browser.advanceTabSwitch(1); browser.advanceTabSwitch(1)
        XCTAssertTrue(browser.palette.isHidden); XCTAssertFalse(browser.tabSwitcher.isHidden)
        XCTAssertFalse(browser.veil.isHidden)
        browser.newTab()
        XCTAssertFalse(browser.palette.isHidden); XCTAssertTrue(browser.tabSwitcher.isHidden)
        XCTAssertFalse(browser.veil.isHidden); XCTAssertNil(browser.veil.hitTest(NSPoint(x: 10, y: 10)))
        let views = browser.root.subviews
        XCTAssertEqual(views.filter { $0 is PanelVeil }.count, 1)
        XCTAssertLessThan(try XCTUnwrap(views.firstIndex { $0 === browser.veil }), try XCTUnwrap(views.firstIndex { $0 === browser.dismissArea }))
        XCTAssertLessThan(try XCTUnwrap(views.firstIndex { $0 === browser.dismissArea }), try XCTUnwrap(views.firstIndex { $0 === browser.palette }))
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertFalse(browser.veil.isHidden, "A cancelled exit cannot hide the new panel's veil")
        browser.hidePalette()
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertTrue(browser.veil.isHidden)
    }
}
