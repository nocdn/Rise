// Native shortcut recording, Settings controls and customized dispatch in a real Rise window.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumShortcutSettingsChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ShortcutSettingsMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL shortcut settings timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder+"/chromium", keychain: false) else { exit(1) }
        let run = ShortcutSettingsRun(folder: URL(fileURLWithPath: folder))
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}
@MainActor final class ShortcutSettingsRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var menus: AppDelegate!
    var settings: BrowserTab!
    var failures = 0
    let suite = "rise-shortcut-settings-\(UUID())"
    let deep = """
    function find(root, selector) {
      return root.querySelector(selector) || [...root.querySelectorAll('*')]
        .map(node => node.shadowRoot && find(node.shadowRoot, selector)).find(Boolean);
    }
    const editor = find(document, 'settings-rise-keyboard-shortcuts');
    """
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ message: String) { print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 } }
    @discardableResult func wait(_ message: String, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(15)
        while !(await condition()), Date() < end { try? await Task.sleep(for: .milliseconds(30)) }
        let passed = await condition(); check(passed, message); return passed
    }
    func js(_ source: String) async -> Any? {
        do { return try await settings.page.evaluate(deep+source, arguments: [:], in: nil, world: .page) }
        catch { print("JavaScript:", source.prefix(100), error.localizedDescription); return nil }
    }
    func key(_ character: String, _ modifiers: NSEvent.ModifierFlags, code: UInt16) {
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: browser.window!.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!)
        }
    }
    func record(_ id: String, index: Int = 0) async {
        browser.window?.makeFirstResponder(settings.page.view)
        let source = """
        const row = editor.shadowRoot.querySelector('[data-command="\(id)"].command');
        row.querySelectorAll('cr-shortcut-input')[\(index)].shadowRoot.querySelector('#edit').click(); return true;
        """
        check(await js(source) as? Bool == true, "Open the native \(id) recorder")
        await wait("The recorder is ready") { self.browser.shortcutRecordingID == id && self.browser.shortcutRecordingIndex == index }
    }
    func click(_ selector: String) async {
        check(await js("const button = editor.shadowRoot.querySelector('\(selector)'); button?.click(); return !!button") as? Bool == true, "Settings control: \(selector)")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async throws {
        let prefs = UserDefaults(suiteName: suite)!
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
        browser.showWindow(nil); browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        settings = browser.addTab(url: URL(string: "rise://settings/keyboardShortcuts")!)
        let loaded = await wait("The Keyboard shortcuts settings page loads") {
            await self.js("return !!editor?.shadowRoot?.querySelector('cr-shortcut-input')") as? Bool == true
        }
        guard loaded else { return }
        check(await js("return find(document, '#riseShortcuts')?.textContent.includes('Keyboard shortcuts')") as? Bool == true, "Keyboard shortcuts appears in the settings sidebar")
        let count = await js("return editor.shadowRoot.querySelectorAll('.command').length") as? Int ?? 0
        check(count > 65, "All app menu commands and contextual shortcuts are editable (\(count) commands)")

        await record("newTab")
        key("y", [.command, .control, .option, .shift], code: 16)
        await wait("Record all four modifiers with Chromium's own input") { self.browser.keyboardShortcuts.bindings("newTab") == [KeyboardShortcut("Command+Ctrl+Alt+Shift+Y")!] }
        await wait("Recording ends after saving") { self.browser.shortcutRecordingID == nil }
        check(!browser.palette.isPresented, "Recording did not execute New Tab")
        let item = browser.keyboardShortcuts.commands.first { $0.id == "newTab" }!.items[0]
        check(item.keyEquivalentModifierMask == [.command, .control, .option, .shift], "The menu shortcut updates immediately")
        settings.page.reload()
        await wait("The saved shortcut survives reloading Settings") {
            await self.js("return editor?.shadowRoot.querySelector('[data-command=newTab].command cr-shortcut-input')?.shortcut === 'Command+Ctrl+Alt+Shift+Y'") as? Bool == true
        }
        print("Recorder state:", await js("return JSON.stringify({html: editor.shadowRoot.querySelector('[data-command=newTab].command').innerHTML})") ?? "missing")

        await click("[data-command=newTab].command .add")
        await wait("Add shortcut starts another native recorder") { self.browser.shortcutRecordingID == "newTab" && self.browser.shortcutRecordingIndex == 1 }
        key("\u{F709}", [], code: 97)
        await wait("Function keys can be added as a second shortcut") { self.browser.keyboardShortcuts.bindings("newTab").count == 2 }
        await wait("Both recorded shortcuts appear in the UI") {
            await self.js("return editor.shadowRoot.querySelector('[data-command=newTab].command').querySelectorAll('cr-shortcut-input')[1]?.shortcut === 'F6'") as? Bool == true
        }
        check(KeyboardShortcuts(preferences: prefs).bindings("newTab").count == 2, "Both shortcuts are persisted")
        _ = await js("editor.shadowRoot.querySelector('[data-command=newTab].command').querySelectorAll('cr-shortcut-input')[1].shadowRoot.querySelector('#clear').click(); return true")
        await wait("The native clear button removes only that binding") { self.browser.keyboardShortcuts.bindings("newTab").count == 1 }

        await record("searchTabs")
        let tabCount = browser.tabs.count
        key("w", .command, code: 13)
        await wait("Conflicting shortcuts show an explanation") { await self.js("return editor.shadowRoot.textContent.includes('Already assigned')") as? Bool == true }
        check(browser.tabs.count == tabCount && browser.shortcutRecordingID == "searchTabs", "Recording ⌘W neither closes the page nor overwrites another command")
        key("\u{1B}", [], code: 53)
        await wait("Escape cancels recording") { self.browser.shortcutRecordingID == nil }

        await record("searchTabs")
        key("s", [.command, .control, .shift], code: 1)
        await wait("Search Tabs accepts a custom binding") { self.browser.keyboardShortcuts.bindings("searchTabs") == [KeyboardShortcut("Command+Ctrl+Shift+S")!] }
        browser.window?.makeFirstResponder(settings.page.view)
        key("s", [.command, .control, .shift], code: 1)
        check(browser.sidebar.isSearchingTabs, "The custom shortcut runs with a Chromium page focused")
        browser.sidebar.endTabSearch(); browser.window?.makeFirstResponder(settings.page.view)
        key("a", [.command, .shift], code: 0)
        check(!browser.sidebar.isSearchingTabs, "The removed default no longer runs")

        await record("moveCurrentTabToTop")
        key("m", [.command, .option, .shift], code: 46)
        await wait("The jump-to-top shortcut can be customized") { self.browser.keyboardShortcuts.bindings("moveCurrentTabToTop") == [KeyboardShortcut("Command+Alt+Shift+M")!] }
        await record("undo:")
        key("z", [.control, .option], code: 6)
        await wait("Undo can be customized") { self.browser.keyboardShortcuts.bindings("undo:") == [KeyboardShortcut("Ctrl+Alt+Z")!] }
        _ = browser.addTab(); _ = browser.addTab(); browser.select(settings.id)
        let before = browser.tabs.map(\.id)
        key("m", [.command, .option, .shift], code: 46)
        check(browser.tabs.first?.id == settings.id, "The custom jump-to-top shortcut moves the current tab")
        key("z", [.control, .option], code: 6)
        check(browser.tabs.map(\.id) == before, "Custom Undo restores its previous position")

        await click("[data-command=newTab].command .reset")
        await wait("Per-command Reset restores New Tab's default") { self.browser.keyboardShortcuts.bindings("newTab") == [KeyboardShortcut("Command+T")!] }
        _ = await js("editor.shadowRoot.querySelector('#filter').shadowRoot.querySelector('input').focus(); return true")
        key("a", [], code: 0)
        await wait("Settings accepts text after recording") { await self.js("return editor.shadowRoot.querySelector('#filter').value === 'a'") as? Bool == true }
        key("z", [.control, .option], code: 6)
        await wait("Custom Undo also undoes text in Chromium's focused field") { await self.js("return editor.shadowRoot.querySelector('#filter').value === ''") as? Bool == true }
        await click("#resetAll")
        await wait("Reset all restores every shortcut") {
            self.browser.keyboardShortcuts.bindings("searchTabs") == [KeyboardShortcut("Command+Shift+A")!] &&
            self.browser.keyboardShortcuts.bindings("undo:") == [KeyboardShortcut("Command+Z")!] &&
            self.browser.keyboardShortcuts.bindings("moveCurrentTabToTop") == [KeyboardShortcut("Command+Ctrl+Alt+Up")!]
        }
        _ = await js("editor.shadowRoot.querySelector('#filter').value = 'move tab'; return true")
        await wait("The shortcut list can be searched") {
            await self.js("return editor.shadowRoot.querySelectorAll('.command').length === 3") as? Bool == true
        }
    }
}
