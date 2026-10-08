import XCTest
import AppKit
import WebKit
@testable import Rise

final class TabAudioTests: XCTestCase {
    private var preferenceSuites: [String] = []
    override func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        super.tearDown()
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.TabAudioTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setFrameAutosaveName("")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        browser.showWindow(nil)
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func wait(_ description: String, timeout: TimeInterval = 10, until predicate: @escaping () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out: \(description)")
        throw NSError(domain: "TabAudioTests", code: 1)
    }
    /// A page looping a silent clip: WebKit counts any audible track as sound,
    /// whatever its samples, so the test makes no noise.
    @MainActor private func soundTab(in browser: BrowserController) async throws -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let tab = browser.addTab(configuration: configuration)
        tab.webView.loadHTMLString("""
          <!doctype html><title>Sound fixture</title><script>
          const rate = 8000, samples = rate, buffer = new ArrayBuffer(44 + samples*2), view = new DataView(buffer);
          const text = (offset, value) => [...value].forEach((c, i) => view.setUint8(offset+i, c.charCodeAt(0)));
          text(0, 'RIFF'); view.setUint32(4, 36 + samples*2, true); text(8, 'WAVEfmt ');
          view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
          view.setUint32(24, rate, true); view.setUint32(28, rate*2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
          text(36, 'data'); view.setUint32(40, samples*2, true);
          const audio = new Audio(URL.createObjectURL(new Blob([buffer], {type: 'audio/wav'})));
          audio.loop = true; audio.play(); window.sound = audio;
          </script>
          """, baseURL: URL(string: "https://example.com/sound"))
        try await wait("page plays sound") { tab.isPlayingAudio }
        return tab
    }

    @MainActor func testTheAudioButtonAppearsBeforeTheTitleAndMutesWithoutPausing() async throws {
        let browser = browser(); defer { clean(browser) }
        let quiet = browser.addTab()
        let tab = try await soundTab(in: browser)
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        try await wait("row shows the audio button") { row.showsAudio }
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.audio.isHidden)
        XCTAssertGreaterThan(row.audio.frame.minX, row.icon.frame.maxX, "After the favicon")
        XCTAssertLessThan(row.audio.frame.maxX, row.titleField.frame.minX, "Before the title")
        XCTAssertEqual(row.audio.frame.size, row.close.frame.size, "The same square as the close button")
        XCTAssertEqual(row.audio.frame.midY, row.icon.frame.midY, accuracy: 0.5)
        let quietRow = try XCTUnwrap(browser.sidebar.rows[quiet.id]); quietRow.layoutSubtreeIfNeeded()
        XCTAssertFalse(quietRow.showsAudio); XCTAssertTrue(quietRow.audio.isHidden)
        XCTAssertEqual(row.titleField.frame.minX, quietRow.titleField.frame.minX+24, "The title moves over to make room")
        XCTAssertTrue(row.hitTest(row.convert(NSPoint(x: row.audio.frame.midX, y: row.audio.frame.midY), to: row.superview)) === row.audio)

        _ = row.audio.accessibilityPerformPress()
        XCTAssertTrue(row.audio.muted, "The slash appears at once")
        XCTAssertTrue(tab.isAudioMuted)
        XCTAssertEqual(tab.webView.value(forKey: "_mediaMutedState") as? UInt, 1, "WebKit mutes the page")
        try await Task.sleep(for: .milliseconds(300))
        let paused = try await tab.webView.evaluateJavaScript("window.sound.paused") as? Bool
        XCTAssertEqual(paused, false, "Muting keeps it playing")
        XCTAssertTrue(row.showsAudio, "A muted tab keeps its button")

        _ = row.audio.accessibilityPerformPress()
        XCTAssertFalse(row.audio.muted); XCTAssertFalse(tab.isAudioMuted)
        XCTAssertEqual(tab.webView.value(forKey: "_mediaMutedState") as? UInt, 0)

        _ = try await tab.webView.evaluateJavaScript("window.sound.pause()")
        try await wait("tab stops playing") { !tab.isPlayingAudio }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(row.showsAudio, "A short pause keeps the title where it is")
        try await wait("button leaves after the sound stops", timeout: 4) { !row.showsAudio }
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.titleField.frame.minX, quietRow.titleField.frame.minX)
    }
}
