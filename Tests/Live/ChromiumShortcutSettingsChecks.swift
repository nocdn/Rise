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
        // A real shifted letter arrives uppercase in both character fields.
        let character = modifiers.contains(.shift) ? character.uppercased() : character
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: browser.window!.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!)
        }
    }
    struct Failure: Error {}
    func record(_ id: String, replacing: Bool = false) async throws {
        if replacing {
            for remaining in stride(from: browser.keyboardShortcuts.bindings(id).count, to: 0, by: -1) {
                await click("[data-command=\"\(id)\"] .remove")
                guard await wait("Remove the previous \(id) binding", { self.browser.keyboardShortcuts.bindings(id).count == remaining-1 }) else { throw Failure() }
            }
        }
        browser.window?.makeFirstResponder(settings.page.view)
        await click("[data-command=\"\(id)\"] .add")
        guard await wait("The \(id) recording dialog is ready", { self.browser.shortcutRecordingID == id }) else { throw Failure() }
    }
    func save() async throws {
        await click("#saveShortcut")
        guard await wait("Save closes the recorder", { self.browser.shortcutRecordingID == nil }) else { throw Failure() }
    }
    func filter(_ value: String) async {
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
        _ = await js("find(editor.shadowRoot, 'cr-search-field').setValue(\(encoded)[0]); return true")
    }
    func click(_ selector: String) async {
        check(await js("const button = editor.shadowRoot.querySelector('\(selector)'); button?.click(); return !!button") as? Bool == true, "Settings control: \(selector)")
    }
    func capture(_ name: String) async {
        try? await Task.sleep(for: .milliseconds(150))
        if let image = await settings.page.snapshot(width: nil), let tiff = image.tiffRepresentation,
           let bytes = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            do { try bytes.write(to: folder.appendingPathComponent(name+".png")) }
            catch { check(false, "Save visual capture: \(error)") }
        } else { check(false, "Capture the rendered shortcut editor") }
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
        guard await wait("Helium's shortcut editor loads", {
            await self.js("return !!editor?.shadowRoot?.querySelector('.shortcut-chip')") as? Bool == true
        }) else { return }
        check(await js("return find(document, '#riseShortcuts')?.textContent.includes('Keyboard shortcuts')") as? Bool == true, "Keyboard shortcuts remains in Rise's sidebar")
        check((await js("return editor.shadowRoot.querySelectorAll('.command-row[data-command]').length") as? Int ?? 0) > 65, "All Rise actions remain available")
        check(await js("return editor.shadowRoot.querySelector('#resetAllButton').disabled") as? Bool == true, "Reset all to defaults starts disabled")
        check(await js("return !editor.shadowRoot.querySelector('cr-shortcut-input') && !!editor.shadowRoot.querySelector('.shortcut-label')") as? Bool == true, "Compact shortcut chips replace the old input rows")
        await filter("new tab")
        guard await wait("Search finds an action by name", { await self.js("return editor.shadowRoot.querySelectorAll('.command-row[data-command]').length === 1 && !!editor.shadowRoot.querySelector('[data-command=newTab]')") as? Bool == true }) else { throw Failure() }
        await filter("⌘T")
        await wait("Search also finds shortcut key symbols") { await self.js("return editor.shadowRoot.querySelector('.command-row[data-command]')?.dataset.command === 'newTab'") as? Bool == true }
        await filter("Command+T")
        await wait("Search also finds serialized key names") { await self.js("return editor.shadowRoot.querySelector('.command-row[data-command]')?.dataset.command === 'newTab'") as? Bool == true }
        await filter("no such shortcut")
        await wait("An unmatched search explains that there are no results") { await self.js("return !!editor.shadowRoot.querySelector('#noResults')") as? Bool == true }
        await filter("")
        await wait("Clearing search restores all actions") { await self.js("return editor.shadowRoot.querySelectorAll('.command-row[data-command]').length > 65") as? Bool == true }
        await capture("helium-shortcuts-light")

        try await record("newTab", replacing: true)
        check(await js("return editor.shadowRoot.querySelector('#saveShortcut').disabled") as? Bool == true, "Save requires a captured shortcut")
        key("a", [], code: 0)
        await wait("An unmodified letter shows validation") { await self.js("return editor.shadowRoot.querySelector('.warning')?.textContent.includes('Include Command')") as? Bool == true }
        key("y", [.command, .control, .option, .shift], code: 16)
        await wait("Recording previews every modifier") { await self.js("return editor.shadowRoot.querySelector('#captureTarget')?.textContent.includes('⌘⌃⌥⇧Y')") as? Bool == true }
        await capture("helium-shortcuts-recorder")
        check(browser.keyboardShortcuts.bindings("newTab").isEmpty, "Preview does not save or execute the shortcut")
        await click("#captureDialog .cancel-button")
        await wait("Cancel stops native recording") { self.browser.shortcutRecordingID == nil }
        check(browser.keyboardShortcuts.bindings("newTab").isEmpty, "Cancel leaves bindings untouched")

        try await record("newTab")
        key("y", [.command, .control, .option, .shift], code: 16)
        await wait("A valid preview enables Save") { await self.js("return editor.shadowRoot.querySelector('#saveShortcut')?.disabled === false") as? Bool == true }
        key("\r", [], code: 36)
        guard await wait("Enter saves the preview and closes recording", { self.browser.shortcutRecordingID == nil && self.browser.keyboardShortcuts.bindings("newTab") == [KeyboardShortcut("Command+Ctrl+Alt+Shift+Y")!] }) else { throw Failure() }
        check(!browser.palette.isPresented, "Recording did not execute New Tab")
        check(browser.keyboardShortcuts.commands.first { $0.id == "newTab" }!.items[0].keyEquivalentModifierMask == [.command, .control, .option, .shift], "Native menus update after Save")
        _ = await js("document.documentElement.dataset.shortcutDocument = 'before'; return true")
        settings.page.reload()
        guard await wait("The saved shortcut survives reloading Settings", { await self.js("return document.documentElement.dataset.shortcutDocument !== 'before' && editor?.shadowRoot.querySelector('[data-command=newTab] .shortcut-label')?.textContent.includes('⌘⌃⌥⇧Y')") as? Bool == true }) else { throw Failure() }

        try await record("newTab")
        key("\u{F709}", [], code: 97)
        await wait("Function keys can be previewed") { self.browser.shortcutRecordingCandidate == KeyboardShortcut("F6") }
        try await save()
        await wait("Add preserves existing bindings and adds the second shortcut") { self.browser.keyboardShortcuts.bindings("newTab").count == 2 }
        check(KeyboardShortcuts(preferences: prefs).bindings("newTab").count == 2, "Both shortcuts are persisted")
        await click("[data-command=newTab] [data-shortcut=F6]")
        await wait("The chip's remove control removes only that shortcut") { self.browser.keyboardShortcuts.bindings("newTab").count == 1 }

        try await record("searchTabs", replacing: true)
        let tabCount = browser.tabs.count
        key("q", .command, code: 12)
        await wait("Conflicts explain which command will lose its shortcut") { await self.js("return editor.shadowRoot.querySelector('.warning')?.textContent.includes('Saving will remove')") as? Bool == true }
        check(browser.tabs.count == tabCount && browser.shortcutRecordingID == "searchTabs", "Previewing ⌘Q never quits or changes a binding")
        key("\u{1B}", [], code: 53)
        await wait("Escape closes the dialog and stops native recording") { self.browser.shortcutRecordingID == nil }

        try await record("searchTabs")
        key("s", [.command, .control, .shift], code: 1)
        await wait("Search Tabs has a preview") { self.browser.shortcutRecordingCandidate == KeyboardShortcut("Command+Ctrl+Shift+S") }
        try await save()
        key("s", [.command, .control, .shift], code: 1)
        check(browser.sidebar.isSearchingTabs, "The saved shortcut runs with Chromium focused")
        browser.sidebar.endTabSearch(); browser.window?.makeFirstResponder(settings.page.view)
        key("a", [.command, .shift], code: 0)
        check(!browser.sidebar.isSearchingTabs, "The removed default stays disabled")

        let closeID = browser.keyboardShortcuts.commands.first { browser.keyboardShortcuts.bindings($0.id).contains(KeyboardShortcut("Command+W")!) }!.id
        try await record("pinCurrentTab")
        key("w", .command, code: 13)
        await wait("A conflicting chord is previewed safely") { self.browser.shortcutRecordingCandidate == KeyboardShortcut("Command+W") }
        try await save()
        check(browser.tabs.count == tabCount && browser.keyboardShortcuts.bindings(closeID).isEmpty
              && browser.keyboardShortcuts.bindings("pinCurrentTab") == [KeyboardShortcut("Command+W")!], "Explicit Save moves a conflicting shortcut, just like Helium")
        await click("[data-command=\"\(closeID)\"] .reset")
        await wait("Per-command Reset restores defaults and reclaims their shortcut") { self.browser.keyboardShortcuts.bindings(closeID).contains(KeyboardShortcut("Command+W")!) && self.browser.keyboardShortcuts.bindings("pinCurrentTab").isEmpty }

        for (id, character, flags, code) in [
            ("moveCurrentTabToTop", "m", [.command, .option, .shift] as NSEvent.ModifierFlags, UInt16(46)),
            ("undo:", "z", [.control, .option] as NSEvent.ModifierFlags, UInt16(6))
        ] {
            try await record(id, replacing: true)
            key(character, flags, code: code)
            await wait("Preview \(id)") { self.browser.shortcutRecordingCandidate != nil }
            try await save()
        }
        _ = browser.addTab(); _ = browser.addTab(); browser.select(settings.id)
        let before = browser.tabs.map(\.id)
        key("m", [.command, .option, .shift], code: 46)
        check(browser.tabs.first?.id == settings.id, "The customized jump-to-top shortcut works")
        key("z", [.control, .option], code: 6)
        check(browser.tabs.map(\.id) == before, "Customized Undo restores tab order")
        _ = await js("find(editor.shadowRoot, 'cr-search-field').getSearchInput().focus(); return true")
        key("a", [], code: 0)
        await wait("Text input works after leaving the recorder") { await self.js("return editor.searchTerm_ === 'a'") as? Bool == true }
        key("z", [.control, .option], code: 6)
        await wait("Customized Undo still works in Chromium's search field") { await self.js("return editor.searchTerm_ === ''") as? Bool == true }

        await click("#resetAllButton")
        await wait("Reset all opens Helium's confirmation dialog") { await self.js("return !!editor.shadowRoot.querySelector('#resetDialog')") as? Bool == true }
        await click("#resetDialog .cancel-button")
        check(browser.keyboardShortcuts.bindings("newTab") != [KeyboardShortcut("Command+T")!], "Cancelling Reset all preserves custom shortcuts")
        await click("#resetAllButton"); await click("#confirmReset")
        await wait("Confirming Reset all restores every default") {
            self.browser.keyboardShortcuts.bindings("newTab") == [KeyboardShortcut("Command+T")!] &&
            self.browser.keyboardShortcuts.bindings("searchTabs") == [KeyboardShortcut("Command+Shift+A")!] &&
            self.browser.keyboardShortcuts.bindings("undo:") == [KeyboardShortcut("Command+Z")!]
        }
        await filter("move tab")
        await wait("The complete list can still be filtered after resetting") { await self.js("return editor.shadowRoot.querySelectorAll('.command-row[data-command]').length === 3") as? Bool == true }
        await filter("")
        try await record("newTab")
        _ = await js("document.documentElement.dataset.shortcutDocument = 'before'; return true")
        settings.page.reload()
        await wait("Reloading the document stops its old native recorder") { self.browser.shortcutRecordingID == nil }
        guard await wait("The editor is ready after cancelling by reload", { await self.js("return document.documentElement.dataset.shortcutDocument !== 'before' && !!editor?.shadowRoot.querySelector('.shortcut-chip')") as? Bool == true }) else { throw Failure() }
        try await record("newTab")
        let other = browser.addTab()
        check(browser.shortcutRecordingID == nil, "Leaving Settings cancels the native recorder")
        browser.select(settings.id)
        await wait("Returning to Settings has no stale recording dialog") { await self.js("return !editor.shadowRoot.querySelector('#captureDialog')") as? Bool == true }
        browser.closeTab(other.id)
        browser.chooseTheme(.dark)
        await wait("The editor follows Rise's dark appearance") { await self.js("return matchMedia('(prefers-color-scheme: dark)').matches") as? Bool == true }
        await capture("helium-shortcuts-dark")
    }
}
