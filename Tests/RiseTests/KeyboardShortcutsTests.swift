import XCTest
import AppKit
@testable import Rise

final class KeyboardShortcutsTests: XCTestCase {
    @MainActor private func withBrowser(_ test: (BrowserController, UserDefaults) throws -> Void) rethrows {
        _ = NSApplication.shared
        let suite = "rise-shortcuts-tests-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        let old = NSApp.mainMenu
        defer {
            NSApp.mainMenu = old; browser.cancelTabSwitch(); browser.hidePalette(); browser.saveWork?.cancel()
            browser.tabs.forEach { $0.cancelLoad() }; browser.suggestionFavicons.cancel(); browser.window?.orderOut(nil)
            preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder)
        }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        try test(browser, preferences)
    }
    @MainActor private func key(_ character: String, _ modifiers: NSEvent.ModifierFlags, code: UInt16 = 0, in browser: BrowserController) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }
    func testShortcutSerializationIncludesPunctuationAllModifiersAndFunctionKeys() {
        for raw in ["Command+Shift+[", "Command+Ctrl+Alt+Up", "Command+Ctrl+Alt+Shift+K", "Command+Comma", "Ctrl+Tab", "F12", "Command+Plus"] {
            let binding = KeyboardShortcut(raw)
            XCTAssertNotNil(binding, raw)
            XCTAssertEqual(binding.flatMap { KeyboardShortcut($0.rawValue) }, binding)
        }
        for raw in ["A", "Shift+A", "Command+", "Command+Command+A", "Command+Unknown", "Escape"] { XCTAssertNil(KeyboardShortcut(raw), raw) }
    }
    @MainActor func testMenuCommandsAndUnassignedCommandsAreAllExposed() {
        withBrowser { browser, _ in
            let commands = browser.keyboardShortcuts.commands
            for id in ["newTab", "searchTabs", "moveCurrentTabToTop", "moveCurrentTabUp", "moveCurrentTabDown", "showSettings", "undo:", "tabSwitcherNext", "smartRename", "selectTab9", "pinCurrentTab"] {
                XCTAssertTrue(commands.contains { $0.id == id }, id)
            }
            XCTAssertGreaterThan(commands.count, 65)
            XCTAssertTrue(browser.keyboardShortcuts.bindings("pinCurrentTab").isEmpty)
            XCTAssertEqual(browser.keyboardShortcuts.bindings("toggleSidebar").count, 2, "The existing ⌘B and ⌘S aliases stay available")
        }
    }
    @MainActor func testChangesPersistUpdateMenusAndRemovedDefaultsStayDisabled() {
        withBrowser { browser, preferences in
            let shortcuts = browser.keyboardShortcuts
            XCTAssertNil(shortcuts.set("newTab", at: 0, to: "Command+Alt+N"))
            let item = shortcuts.commands.first { $0.id == "newTab" }!.items[0]
            XCTAssertEqual(item.keyEquivalent, "n"); XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
            XCTAssertEqual(KeyboardShortcuts(preferences: preferences).bindings("newTab"), [KeyboardShortcut("Command+Alt+N")!])
            browser.addTab(); browser.hidePalette()
            XCTAssertTrue(browser.window!.performKeyEquivalent(with: key("t", .command, code: 17, in: browser)))
            XCTAssertFalse(browser.palette.isPresented, "The old shortcut cannot fall through to Chromium")
            XCTAssertTrue(browser.window!.performKeyEquivalent(with: key("n", [.command, .option], code: 45, in: browser)))
            XCTAssertTrue(browser.palette.isPresented)
            XCTAssertNil(shortcuts.set("newTab", at: 0, to: ""))
            XCTAssertTrue(shortcuts.bindings("newTab").isEmpty)
            XCTAssertNil(shortcuts.reset("newTab"))
            XCTAssertEqual(shortcuts.bindings("newTab"), [KeyboardShortcut("Command+T")!])
            let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
            XCTAssertEqual(shortcuts.commands.first { $0.id == "newTab" }!.items[0].keyEquivalent, "t", "Rebuilding the menu keeps its shortcut")
        }
    }
    @MainActor func testConflictsAdditionalBindingsAndResets() {
        withBrowser { browser, _ in
            let shortcuts = browser.keyboardShortcuts
            XCTAssertNotNil(shortcuts.set("searchTabs", at: 0, to: "Command+T"))
            XCTAssertNil(shortcuts.set("newTab", at: 0, to: ""))
            XCTAssertNil(shortcuts.set("searchTabs", at: 0, to: "Command+T"))
            XCTAssertNil(shortcuts.reset("newTab"), "Reset restores the default and reclaims its binding, as Helium does")
            XCTAssertTrue(shortcuts.bindings("searchTabs").isEmpty)
            XCTAssertNil(shortcuts.set("searchTabs", at: 0, to: "Command+Ctrl+K"))
            XCTAssertNil(shortcuts.set("searchTabs", at: 1, to: "Command+Alt+Y"))
            XCTAssertEqual(shortcuts.bindings("searchTabs").count, 2)
            browser.addTab()
            XCTAssertTrue(browser.window!.performKeyEquivalent(with: key("y", [.command, .option], code: 16, in: browser)))
            XCTAssertTrue(browser.sidebar.isSearchingTabs)
            shortcuts.resetAll()
            XCTAssertEqual(shortcuts.bindings("newTab"), [KeyboardShortcut("Command+T")!])
            XCTAssertEqual(shortcuts.bindings("searchTabs"), [KeyboardShortcut("Command+Shift+A")!])
        }
    }
    @MainActor func testCustomizedMovementAndUndoUseTheSavedBindings() {
        withBrowser { browser, _ in
            let current = browser.addTab(), other = browser.addTab(), third = browser.addTab()
            browser.select(current.id)
            XCTAssertNil(browser.keyboardShortcuts.set("moveCurrentTabUp", at: 0, to: "Ctrl+Shift+K"))
            XCTAssertNil(browser.keyboardShortcuts.set("moveCurrentTabToTop", at: 0, to: "Command+Ctrl+Shift+P"))
            XCTAssertNil(browser.keyboardShortcuts.set("undo:", at: 0, to: "Command+Alt+Z"))
            XCTAssertTrue(browser.window!.performKeyEquivalent(with: key("k", [.control, .shift], code: 40, in: browser)))
            XCTAssertEqual(browser.tabs.map(\.id), [third.id, current.id, other.id])
            XCTAssertTrue(browser.window!.performKeyEquivalent(with: key("p", [.command, .control, .shift], code: 35, in: browser)))
            XCTAssertEqual(browser.tabs.map(\.id), [current.id, third.id, other.id])
            XCTAssertTrue(browser.window!.performKeyEquivalent(with: key("z", [.command, .option], code: 6, in: browser)))
            XCTAssertEqual(browser.tabs.map(\.id), [third.id, other.id, current.id])
            XCTAssertEqual(browser.selectedID, current.id)
        }
    }
    @MainActor func testNativeRecordingConsumesConflictingAndDestructiveShortcuts() {
        withBrowser { browser, _ in
            let tab = browser.addTab(); tab.requestedURL = URL(string: "rise://settings/keyboardShortcuts")!
            browser.handleKeyboardShortcutsRequest(["action": "capture", "id": "newTab", "index": 0, "capturing": true], from: tab.page) { _, error in XCTAssertNil(error) }
            XCTAssertTrue(browser.handleKeyboardShortcut(key("q", .command, code: 12, in: browser)), "Recording ⌘Q never quits Rise")
            XCTAssertEqual(browser.shortcutRecordingID, "newTab", "A conflicting shortcut keeps listening")
            XCTAssertTrue(browser.handleKeyboardShortcut(key("n", [.command, .option], code: 45, in: browser)))
            XCTAssertEqual(browser.shortcutRecordingID, "newTab")
            XCTAssertEqual(browser.shortcutRecordingCandidate, KeyboardShortcut("Command+Alt+N"))
            XCTAssertEqual(browser.keyboardShortcuts.bindings("newTab"), [KeyboardShortcut("Command+T")!], "Recording is a preview until Save")
            browser.handleKeyboardShortcutsRequest(["action": "assign", "id": "newTab", "shortcut": "Command+Alt+N"], from: tab.page) { _, error in XCTAssertNil(error) }
            XCTAssertEqual(browser.keyboardShortcuts.bindings("newTab"), [KeyboardShortcut("Command+T")!, KeyboardShortcut("Command+Alt+N")!])
            XCTAssertFalse(browser.palette.isPresented, "Recording never executes the chosen command")
        }
    }
    @MainActor func testExplicitAssignmentMovesOnlyTheChosenShortcutAndPersistsBothCommands() {
        withBrowser { browser, preferences in
            let shortcuts = browser.keyboardShortcuts
            XCTAssertNil(shortcuts.assign("Command+T", to: "searchTabs"))
            XCTAssertTrue(shortcuts.bindings("newTab").isEmpty)
            XCTAssertEqual(shortcuts.bindings("searchTabs"), [KeyboardShortcut("Command+Shift+A")!, KeyboardShortcut("Command+T")!])
            XCTAssertEqual(KeyboardShortcuts(preferences: preferences).bindings("newTab"), [])
            XCTAssertNil(shortcuts.assign("Command+T", to: "searchTabs"))
            XCTAssertEqual(shortcuts.bindings("searchTabs").count, 2, "Saving the same chord twice doesn't duplicate it")
            XCTAssertNotNil(shortcuts.assign("A", to: "newTab"))
            XCTAssertTrue(shortcuts.bindings("newTab").isEmpty, "Invalid assignments leave every binding intact")
            XCTAssertNil(shortcuts.remove("Command+T", from: "searchTabs"))
            XCTAssertEqual(shortcuts.bindings("searchTabs"), [KeyboardShortcut("Command+Shift+A")!])
            XCTAssertNil(shortcuts.reset("newTab"))
            XCTAssertEqual(shortcuts.bindings("newTab"), [KeyboardShortcut("Command+T")!])
        }
    }
    @MainActor func testCancellingPreviewAndModifierReleaseNeverChangeBindings() {
        withBrowser { browser, _ in
            let tab = browser.addTab(); tab.requestedURL = URL(string: "rise://settings/keyboardShortcuts")!
            browser.handleKeyboardShortcutsRequest(["action": "capture", "id": "newTab", "index": 1, "capturing": true], from: tab.page) { _, error in XCTAssertNil(error) }
            XCTAssertTrue(browser.handleKeyboardShortcut(key("y", [.command, .control], code: 16, in: browser)))
            let release = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: browser.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
            XCTAssertTrue(browser.handleKeyboardShortcut(release))
            XCTAssertEqual(browser.shortcutRecordingCandidate, KeyboardShortcut("Command+Ctrl+Y"))
            XCTAssertTrue(browser.handleKeyboardShortcut(key("\u{1B}", [], code: 53, in: browser)))
            XCTAssertNil(browser.shortcutRecordingID); XCTAssertNil(browser.shortcutRecordingCandidate)
            XCTAssertEqual(browser.keyboardShortcuts.bindings("newTab"), [KeyboardShortcut("Command+T")!])
            browser.handleKeyboardShortcutsRequest(["action": "capture", "id": "newTab", "index": 1, "capturing": true], from: tab.page) { _, error in XCTAssertNil(error) }
            browser.handleKeyboardShortcutsRequest(["action": "list", "resetCapture": true], from: tab.page) { _, error in XCTAssertNil(error) }
            XCTAssertNil(browser.shortcutRecordingID, "A newly loaded editor cancels the old document's recorder")
            browser.handleKeyboardShortcutsRequest(["action": "capture", "id": "newTab", "index": 1, "capturing": true], from: tab.page) { _, error in XCTAssertNil(error) }
            _ = browser.addTab()
            XCTAssertNil(browser.shortcutRecordingID, "Switching tabs cancels the settings recorder")
        }
    }
    @MainActor func testButtonHintsFollowRemappedAndRemovedShortcutsInBothPageBars() throws {
        try withBrowser { browser, _ in
            let shortcuts = browser.keyboardShortcuts
            let controls: [(String, [ChromeButton])] = [
                ("newTab", [browser.sidebar.titlebarNewTab]),
                ("cleanUpTabs", [browser.sidebar.cleanUpButton]),
                ("toggleDownloads", [browser.sidebar.archiveButton]),
                ("toggleSidebar", [browser.toolbarButtons[0]]),
                ("goBack", [browser.toolbarButtons[1], browser.splitBarButtons[0]]),
                ("goForward", [browser.toolbarButtons[2], browser.splitBarButtons[1]]),
                ("reload", [browser.toolbarButtons[3], browser.splitBarButtons[2]]),
                ("copyURL", [browser.navBar.copyButton, browser.splitBar.copyButton]),
            ]
            for (id, buttons) in controls {
                XCTAssertNil(shortcuts.set(id, at: 0, to: "Command+Ctrl+Alt+9"))
                for button in buttons {
                    XCTAssertEqual(try XCTUnwrap(button.hoverHint).shortcut, "⌘⌃⌥9", id)
                    XCTAssertNil(button.toolTip, "The native hint replaces the plain tooltip")
                }
                for _ in shortcuts.bindings(id) { XCTAssertNil(shortcuts.set(id, at: 0, to: "")) }
                for button in buttons {
                    let hint = try XCTUnwrap(button.hoverHint)
                    XCTAssertEqual(hint.hintText.string, hint.text, "An unassigned shortcut leaves no blank suffix")
                }
                shortcuts.resetAll()
            }
            for button in [browser.navBar.settingsButton, browser.splitBar.settingsButton] {
                XCTAssertEqual(try XCTUnwrap(button.hoverHint).hintText.string, "Site controls")
                XCTAssertNil(button.toolTip)
            }
        }
    }
    @MainActor func testStopHintKeepsItsOwnShortcutWhenReloadIsRemapped() throws {
        try withBrowser { browser, _ in
            let buttons = try [browser.toolbarButtons[3], browser.splitBarButtons[2]].map { try XCTUnwrap($0 as? ReloadButton) }
            buttons.forEach { $0.setMode(.stop, force: true) }
            XCTAssertNil(browser.keyboardShortcuts.set("reload", at: 0, to: "Command+Ctrl+Alt+9"))
            XCTAssertNil(browser.keyboardShortcuts.set("stopLoadingPage", at: 0, to: "F8"))
            for button in buttons {
                XCTAssertEqual(try XCTUnwrap(button.hoverHint).hintText.string, "Stop Loading  F8")
                XCTAssertNil(button.toolTip)
                button.setMode(.reload, force: true)
                XCTAssertEqual(try XCTUnwrap(button.hoverHint).hintText.string, "Reload  ⌘⌃⌥9")
            }
        }
    }
}
