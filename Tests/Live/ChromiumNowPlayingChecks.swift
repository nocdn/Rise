// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumNowPlayingChecks.swift
import AppKit
import Carbon.HIToolbox
import RiseChromium
import RiseCore
@testable import Rise

@main @MainActor struct ChromiumNowPlayingMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+180) { print("FAIL now playing checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = NowPlayingRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// The sidebar's Now Playing: it shows a tab you've left playing, with the page's Media Session
/// details and its sound's levels, opens under the pointer, and its controls reach the page.
@MainActor final class NowPlayingRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ name: String) {
        print(value ? "PASS" : "FAIL", name)
        if !value { failures += 1 }
    }
    func waitUntil(_ seconds: Double, _ ready: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await ready()), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return await ready()
    }
    /// The sidebar's bottom, for looking at, where RISE_NOW_PLAYING_SHOTS names a folder.
    func shot(_ browser: BrowserController, _ name: String) {
        guard let out = ProcessInfo.processInfo.environment["RISE_NOW_PLAYING_SHOTS"] else { return }
        let sidebar: SidebarView = browser.sidebar
        sidebar.layoutSubtreeIfNeeded(); sidebar.displayIfNeeded()
        let rect = NSRect(x: 0, y: sidebar.bounds.height-200, width: sidebar.bounds.width, height: 200)
        guard let rep = sidebar.bitmapImageRepForCachingDisplay(in: rect) else { return }
        sidebar.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent(name+".png"))
    }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func run() async {
        let defaults = UserDefaults(suiteName: "Rise.NowPlaying.\(UUID())")!
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: defaults)
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        try? """
        <!doctype html><title>Song page</title>
        <audio id=song loop></audio>
        <script>
        song.volume = 0.03;
        navigator.mediaSession.metadata = new MediaMetadata({title: 'Starboy', artist: 'The Weeknd',
          artwork: [{src: 'missing-small.png', sizes: '64x64'}, {src: 'missing-large.png', sizes: '512x512'}]});
        window.skipped = [];
        navigator.mediaSession.setActionHandler('nexttrack', () => skipped.push('next'));
        navigator.mediaSession.setActionHandler('previoustrack', () => skipped.push('previous'));
        // From memory, so it can seek: the test's server doesn't serve ranges.
        fetch('clip.mp4').then(response => response.blob()).then(blob => { song.src = URL.createObjectURL(blob); song.play(); });
        </script>
        """.write(to: folder.appendingPathComponent("song.html"), atomically: true, encoding: .utf8)
        let tab = browser.addTab(url: URL(string: "http://rise-check.test:\(port)/song.html")!)
        func value(_ script: String) async -> Any? {
            try? await tab.page.evaluate("return \(script)", arguments: [:], in: nil, world: .page)
        }
        let card = browser.sidebar.nowPlaying
        check(await waitUntil(20) { browser.tabMedia.paused(tab.id) == false }, "The page plays")
        check(browser.tabMedia.details(tab.id)?.title == "Starboy" && browser.tabMedia.details(tab.id)?.artist == "The Weeknd",
              "Its Media Session details are read")
        check(browser.tabMedia.details(tab.id)?.artwork?.lastPathComponent == "missing-large.png", "The largest artwork is chosen")
        check(browser.tabMedia.details(tab.id)?.skipsTracks == true, "Its track actions are seen")
        try? await Task.sleep(for: .milliseconds(400))
        check(!card.isShown, "Not while its tab is shown")

        let other = browser.addTab(url: URL(string: "http://rise-check.test:\(port)/missing.html")!)
        browser.select(other.id); browser.update()
        check(await waitUntil(5) { card.isShown && !card.isHidden }, "Leaving the tab shows the card")
        browser.sidebar.layoutSubtreeIfNeeded()
        check(abs(card.frame.height-NowPlayingCard.collapsedHeight) < 0.5, "Closed, it's one row tall")
        check(card.frame.maxY <= browser.sidebar.archiveButton.frame.minY, "It sits over Downloads")
        check(browser.sidebar.scroll.frame.maxY <= card.frame.minY, "The list ends above it")
        check(card.accessibilityLabel() == "Now Playing: Starboy", "It shows the title")
        check(await waitUntil(5) { card.progress.duration > 20 }, "It knows the clip's length")
        try? await Task.sleep(for: .milliseconds(300)); shot(browser, "closed-\(browser.theme)")

        var levels: [Double]?
        let read = await waitUntil(5) {
            levels = await withCheckedContinuation { done in browser.tabMedia.status(tab.id, meter: true) { done.resume(returning: $0?.levels) } }
            return levels?.contains { $0 > 0.05 } == true
        }
        check(read, "The page's sound is measured: \(levels ?? [])")
        let playing = await value("!song.paused && !song.muted && song.volume > 0") as? Bool
        check(playing == true, "Measuring leaves the sound alone")

        // Opening under the pointer.
        let hover = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        card.mouseEntered(with: hover)
        var peak: CGFloat = 0
        let opened = await waitUntil(2) { peak = max(peak, card.expansion); return card.isExpanded && abs(card.expansion-1) < 0.001 }
        check(opened, "Under the pointer it opens")
        check(peak < 1.001, "Without overshooting: \(peak)")
        check(abs(card.frame.height-card.expandedHeight) < 0.5 && abs(card.frame.maxY-(browser.sidebar.bounds.height-46)) < 0.5,
              "Upwards, from where it sits")
        check(card.closeControl.alphaValue > 0.99 && card.waveform.alphaValue < 0.01, "The waveform gives way to the X")
        shot(browser, "open-\(browser.theme)")
        if let out = ProcessInfo.processInfo.environment["RISE_NOW_PLAYING_SHOTS"], let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) {
            card.cacheDisplay(in: card.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("card.png"))
        }
        if ProcessInfo.processInfo.environment["RISE_NOW_PLAYING_SHOTS"] != nil {
            let original = browser.theme
            for theme in [RiseTheme.dark, .neutral] where theme != original {
                browser.sidebar.update(tabs: browser.tabs, selected: browser.selectedTab, theme: theme)
                try? await Task.sleep(for: .milliseconds(300)); shot(browser, "open-\(theme)")
            }
            browser.sidebar.update(tabs: browser.tabs, selected: browser.selectedTab, theme: original)
        }

        // Leaving, it closes at once (the real pointer is elsewhere).
        card.mouseExited(with: hover)
        check(!card.isExpanded, "Leaving closes it at once")
        check(await waitUntil(0.5) { card.expansion < 0.001 }, "Within half a second")
        check(card.expansion >= -0.001, "Without dipping past closed")
        card.onSeek?(0.5, true)
        check(await waitUntil(3) { ((await value("song.currentTime") as? Double) ?? 0) > 13 }, "The bar seeks the page")
        card.forwardButton.action?()
        card.backButton.action?()
        check(await waitUntil(3) { (await value("skipped.join()") as? String) == "next,previous" }, "Skipping takes the page's tracks")

        let before = "page paused \(await value("song.paused") ?? "?"), card paused \(card.isPaused)"
        _ = card.playButton.accessibilityPerformPress()
        check(card.isPaused, "Play and pause swaps at once (before: \(before))")
        check(await waitUntil(3) { await value("song.paused") as? Bool == true }, "And pauses the page")
        try? await Task.sleep(for: .milliseconds(600))
        check(card.isShown, "Paused, the card stays")
        check(await waitUntil(1) { card.waveform.presence == 0 }, "Its waveform fades away")
        _ = card.playButton.accessibilityPerformPress()
        check(await waitUntil(3) { await value("song.paused") as? Bool == false }, "And plays it again")
        var fading = false
        check(await waitUntil(1) { let p = card.waveform.presence; fading = fading || (p > 0 && p < 1); return p == 1 } && fading,
              "Its waveform comes back smoothly")

        _ = card.audio.accessibilityPerformPress()
        check(await waitUntil(2) { tab.isAudioMuted }, "The sound button mutes the tab")
        _ = card.audio.accessibilityPerformPress()
        check(await waitUntil(2) { !tab.isAudioMuted }, "And unmutes it")

        _ = card.closeControl.accessibilityPerformPress()
        check(await waitUntil(3) { await value("song.paused") as? Bool == true }, "The X pauses")
        check(await waitUntil(2) { !card.isShown }, "And puts the card away")
        try? await Task.sleep(for: .milliseconds(1800))
        _ = await value("song.play()")
        check(await waitUntil(4) { card.isShown }, "Playing again brings it back")

        _ = card.showTabControl.accessibilityPerformPress()
        check(await waitUntil(2) { browser.selectedID == tab.id }, "The arrows show the tab")
        check(await waitUntil(2) { !card.isShown }, "Which puts the card away")

        print(failures == 0 ? "PASS now playing checks" : "FAIL \(failures) now playing checks")
        exit(failures == 0 ? 0 : 1)
    }
}
