// Browser command mode in the real Chromium-backed desktop address palette.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumSlashCommandChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumSlashCommandMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+60) { print("FAIL command checks timed out"); exit(1) }
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ChromiumSlashCommandRun(folder: folder)
        let app = RCApplication.shared; app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumSlashCommandRun: NSObject, NSApplicationDelegate {
    let folder: URL
    private var failures = 0
    init(folder: URL) { self.folder = folder }
    private func check(_ passed: Bool, _ name: String) {
        print(passed ? "PASS" : "FAIL", name)
        if !passed { failures += 1 }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await exercise() } catch { check(false, "\(error)") }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    private func checkSharedVeil(_ browser: BrowserController) async throws {
        let originalTheme = browser.theme
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for theme in [RiseTheme.neutral, .dark] {
            browser.theme = theme; browser.update(); browser.newTab()
            let veil = browser.veil
            let color = veil.layer?.backgroundColor
            let paletteIn = veil.layer?.animation(forKey: PanelVeil.animationKey)
            try await Task.sleep(for: .milliseconds(180))
            browser.hidePalette()
            let paletteOut = veil.layer?.animation(forKey: PanelVeil.animationKey)
            try await Task.sleep(for: .milliseconds(110))
            browser.advanceTabSwitch(1); browser.advanceTabSwitch(1)
            check(!browser.tabSwitcher.isHidden && browser.veil === veil && veil.layer?.backgroundColor == color
                  && veil.frame == browser.root.bounds, "Tab switcher reuses the palette's full-window veil in \(theme)")
            if !reduced {
                check(veil.layer?.animation(forKey: PanelVeil.animationKey)?.duration == paletteIn?.duration
                      && paletteIn?.duration == PanelVeil.fadeInDuration, "Both panels use the same entry fade in \(theme)")
            }
            try await Task.sleep(for: .milliseconds(180))
            let point = browser.root.convert(NSPoint(x: 10, y: 10), to: nil)
            guard let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            browser.window!.sendEvent(click)
            check(browser.tabSwitcher.isHidden && veil.hitTest(NSPoint(x: 10, y: 10)) == nil,
                  "Outside-click dismissal releases the veil's pointer handling immediately in \(theme)")
            if !reduced {
                check(veil.layer?.animation(forKey: PanelVeil.animationKey)?.duration == paletteOut?.duration
                      && paletteOut?.duration == PanelVeil.fadeOutDuration, "Both panels use the same exit fade in \(theme)")
            }
            try await Task.sleep(for: .milliseconds(110))
            check(veil.isHidden, "The shared veil finishes hiding in \(theme)")
        }
        browser.newTab(); browser.advanceTabSwitch(1); browser.advanceTabSwitch(1); browser.newTab()
        try await Task.sleep(for: .milliseconds(220))
        check(browser.palette.isPresented && browser.tabSwitcher.isHidden && !browser.veil.isHidden
              && browser.root.subviews.filter { $0 is PanelVeil }.count == 1
              && browser.veil.hitTest(NSPoint(x: 10, y: 10)) == nil,
              "Rapid handoffs keep one visible veil with the palette's pointer behavior")
        browser.hidePalette()
        try await Task.sleep(for: .milliseconds(110))
        browser.theme = originalTheme; browser.update()
    }
    private func exercise() async throws {
        let suite = "Rise.SlashCommands.Live.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let session = folder.appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: session, restore: false, preferences: preferences)
        defer {
            browser.hidePalette(); browser.suggestionFavicons.cancel(); browser.saveWork?.cancel()
            browser.tabs.forEach { $0.cancelLoad(); $0.iconTask?.cancel() }; browser.window?.orderOut(nil)
            preferences.removePersistentDomain(forName: suite)
        }
        let tab = browser.addTab(url: URL(string: "about:blank")!)
        _ = browser.addTab(url: URL(string: "about:blank")!); browser.select(tab.id)
        browser.showWindow(nil)
        try await checkSharedVeil(browser)
        browser.browsingHistory.record(URL(string: "https://zoom.example/")!, title: "Zoom website")
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette
        guard let editor = palette.input.currentEditor() as? NSTextView else { check(false, "Native address editor exists"); return }
        func type(_ text: String) { editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange()) }
        type("zoom")
        check(palette.suggestions.allSatisfy { $0.command == nil }, "Normal suggestions contain no browser actions")
        for (query, id, title) in [
            ("/side-by-side", "Split View", "Split View"), ("/night mode", "Change Theme", "Change Theme"),
            ("/add-ons", "Extensions", "Extensions"), ("/snapshot", "Capture Page", "Capture Page")
        ] {
            type(query)
            check(palette.suggestions.contains { $0.command == id && $0.title == title }, "\(query) finds \(title) through its hidden alias")
        }
        type("/")
        check(palette.isCommandMode && !palette.suggestions.isEmpty && palette.suggestions.allSatisfy { $0.command != nil && $0.url == nil }, "Slash immediately shows only browser features")
        check(palette.autofill == nil && palette.offeredSite == nil, "Command mode has no address completion or site-search hint")
        let commands = browser.paletteCommands(matching: "").map(\.id)
        check(palette.suggestions.compactMap(\.command) == commands && commands.count > CenteredPaletteStyle.visibleRows,
              "The slash list includes every available command, beyond the visible rows")
        for _ in commands.indices.dropFirst() { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        check(palette.selectedIndex == commands.count-1 && palette.firstRow > 0 && !palette.buttons.last!.isHidden
              && palette.frame.height <= CenteredPaletteStyle.maximumHeight && editor.string == "/",
              "Down reaches the last command while the panel stays bounded and the slash stays editable")
        let arrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        guard let jump = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .numericPad, .function], timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
            isARepeat: false, keyCode: 126) else { check(false, "Command-Up event exists"); return }
        check(browser.window!.performKeyEquivalent(with: jump) && palette.selectedIndex == 0 && palette.firstRow == 0 && editor.string == "/",
              "Command-Up reveals and selects the first browser command")
        for _ in commands.indices.dropFirst() { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        let fullHeight = palette.frame.height
        editor.insertText("settings", replacementRange: editor.selectedRange())
        check(palette.suggestions.compactMap(\.command) == ["Open Settings"] && palette.firstRow == 0
              && palette.selectedIndex == 0 && palette.frame.height < fullHeight,
              "Typing after the slash filters from the top and shrinks the panel to the matches")
        type("/magnify")
        check(editor.string == "/magnify" && palette.chosenSuggestion?.command == "Zoom", "A hidden alias selects Zoom while keeping the typed query intact")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(palette.isChoosing && palette.suggestions.contains { $0.title == "150%" }, "Enter opens the existing zoom choices")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        check(browser.window!.performKeyEquivalent(with: jump) && palette.selectedIndex == 0 && palette.firstRow == 0,
              "Command-Up also jumps to the first submenu choice")
        type("150")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(abs(tab.page.zoom-1.5) < 0.001 && !palette.isPresented, "Choosing 150% changes the real Chromium page")
        check(browser.paletteCommandUsage.count(for: "Zoom") == 1, "A submenu choice counts once under Zoom")
        browser.newTab()
        guard let editor = palette.input.currentEditor() as? NSTextView else { check(false, "Address editor reopens"); return }
        editor.insertText("/", replacementRange: editor.selectedRange())
        check(palette.suggestions.first?.command == "Zoom", "Used commands rise to the top of the slash list")
        editor.insertText("zoom", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 0, length: 1)); editor.deleteBackward(nil)
        check(!palette.isCommandMode && editor.string == "zoom" && palette.suggestions.allSatisfy { $0.command == nil }, "Removing just the slash restores ordinary suggestions immediately")
        editor.selectAll(nil); editor.insertText("/", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        check(!palette.isCommandMode && editor.string.isEmpty && palette.suggestions.allSatisfy { $0.command == nil }, "Backspacing a lone slash restores the ordinary empty list")
        for _ in palette.suggestions.indices { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        check(browser.window!.performKeyEquivalent(with: jump) && palette.selectedIndex == 0
              && editor.string == AddressPalette.fieldText(for: palette.suggestions[0]),
              "Command-Up jumps to the first ordinary suggestion and fills its address")
        editor.selectAll(nil)
        editor.insertText("/no-such-command", replacementRange: editor.selectedRange())
        let tabCount = browser.tabs.count
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(palette.isPresented && palette.suggestions.isEmpty && browser.tabs.count == tabCount, "Unknown commands stay in the palette instead of navigating")
        check(palette.subviews.compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue == "No matching commands" },
              "An unmatched filter explains that no commands match")
        let restored = BrowserController(sessionURL: session, restore: false, preferences: preferences)
        defer { restored.suggestionFavicons.cancel(); restored.saveWork?.cancel(); restored.tabs.forEach { $0.cancelLoad() }; restored.window?.orderOut(nil) }
        _ = restored.addTab()
        check(restored.paletteCommandUsage.count(for: "Zoom") == 1 && restored.suggestions(for: "/").first?.command == "Zoom", "Command ranking survives creating a fresh browser controller")
    }
}
