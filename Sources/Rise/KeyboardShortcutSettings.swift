import AppKit

@MainActor extension BrowserController {
    func handleKeyboardShortcutsRequest(_ body: [String: Any], from page: WebPage?, reply: @escaping (Any?, String?) -> Void) {
        let id = body["id"] as? String ?? ""
        var error: String?
        switch body["action"] as? String {
        case "list": break
        case "set":
            guard let index = body["index"] as? Int, let value = body["shortcut"] as? String else { reply(nil, "Invalid shortcut"); return }
            error = keyboardShortcuts.set(id, at: index, to: value)
        case "reset": error = keyboardShortcuts.reset(id)
        case "resetAll": keyboardShortcuts.resetAll()
        case "capture":
            if body["capturing"] as? Bool == true {
                guard let page, selectedTab?.page === page, let index = body["index"] as? Int,
                      keyboardShortcuts.commands.contains(where: { $0.id == id }),
                      (0...keyboardShortcuts.bindings(id).count).contains(index) else { reply(nil, "Invalid recorder"); return }
                shortcutRecordingPage = page; shortcutRecordingID = id; shortcutRecordingIndex = index
                shortcutRecordedKeyCode = nil
            } else if shortcutRecordingID == id, shortcutRecordingIndex == body["index"] as? Int {
                shortcutRecordingPage = nil; shortcutRecordingID = nil
            }
        default: reply(nil, "Unknown request"); return
        }
        reply(["commands": keyboardShortcuts.settings, "error": error ?? ""], nil)
    }

    func keyboardShortcutsChanged() {
        let newTabKey = keyboardShortcuts.bindings("newTab").first?.display ?? ""
        sidebar.newTab.toolTip = newTabKey.isEmpty ? "New Tab" : "New Tab (\(newTabKey))"
        func shortcut(_ id: String) -> String { keyboardShortcuts.bindings(id).first?.display ?? "" }
        for (button, id) in [(sidebar.titlebarNewTab, "newTab"), (sidebar.cleanUpButton, "cleanUpTabs"),
                             (sidebar.archiveButton, "toggleDownloads"), (toolbarButtons[0], "toggleSidebar"),
                             (navBar.copyButton, "copyURL"), (splitBar.copyButton, "copyURL")] as [(ChromeButton, String)] {
            button.hoverHint?.setShortcut(shortcut(id))
        }
        for buttons in [Array(toolbarButtons.dropFirst()), splitBarButtons] {
            buttons[0].hoverHint?.setShortcut(shortcut("goBack"))
            buttons[1].hoverHint?.setShortcut(shortcut("goForward"))
            (buttons[2] as? ReloadButton)?.setHintShortcuts(reload: shortcut("reload"), stop: shortcut("stopLoadingPage"))
        }
        for tab in tabs where ["rise", "chrome"].contains(tab.url?.scheme ?? "") && tab.url?.host == "settings" {
            tab.page.evaluate("dispatchEvent(new Event('rise-settings-ready'))", arguments: [:], in: nil, world: .page) { _ in }
        }
    }

    /// Recording happens before AppKit's menu and Chromium shortcuts, so even ⌘W or ⌘Q
    /// can be recorded safely. The UI is Chromium's own cr-shortcut-input control.
    func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
        if event.type == .keyDown || event.type == .keyUp, event.keyCode == shortcutRecordedKeyCode {
            if event.type == .keyUp { shortcutRecordedKeyCode = nil }
            return true
        }
        if let id = shortcutRecordingID, let page = shortcutRecordingPage {
            if selectedTab?.page === page, selectedTab?.url?.host == "settings",
               ["rise", "chrome"].contains(selectedTab?.url?.scheme ?? "") {
                guard event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged else { return false }
                guard event.type == .keyDown else { return true }
                var detail: [String: Any] = ["id": id, "index": shortcutRecordingIndex]
                if event.keyCode == 53 {
                    shortcutRecordedKeyCode = event.keyCode
                    detail["cancelled"] = true
                    shortcutRecordingID = nil; shortcutRecordingPage = nil
                } else if let binding = KeyboardShortcut(event: event), binding.isAssignable {
                    if let error = keyboardShortcuts.set(id, at: shortcutRecordingIndex, to: binding.rawValue) { detail["error"] = error }
                    else {
                        shortcutRecordedKeyCode = event.keyCode
                        detail["shortcut"] = binding.rawValue
                        shortcutRecordingID = nil; shortcutRecordingPage = nil
                    }
                } else { detail["error"] = "Include Command, Control or Option, or use a function key. Escape cancels." }
                page.evaluate("dispatchEvent(new CustomEvent('rise-shortcut-recorded', {detail: payload}))", arguments: ["payload": detail], in: nil, world: .page) { _ in }
                return true
            }
            shortcutRecordingPage = nil; shortcutRecordingID = nil
        }
        guard event.type == .keyDown else { return false }
        if let command = keyboardShortcuts.command(for: event) {
            if command.id == "undo:" || command.id == "redo:" {
                if (window as? BrowserWindow)?.undoEvent?(event) == true { return true }
                return NSApp.sendAction(NSSelectorFromString(command.id), to: nil, from: command.items.first)
            }
            let early = ["moveCurrentTabUp", "moveCurrentTabDown", "moveCurrentTabToTop",
                         "tabSwitcherNext", "tabSwitcherPrevious", "smartRename", "activateSuggestedTab"]
            if early.contains(command.id) || command.id.hasPrefix("selectTab") { return false }
            guard let item = command.items.first, let action = item.action else { return false }
            tabMoveSequence = nil; tabOrderUndoPending = false
            if let target = item.target as? NSMenuItemValidation, !target.validateMenuItem(item) { return true }
            NSApp.sendAction(action, to: item.target, from: item)
            return true
        }
        return keyboardShortcuts.isRemovedDefault(event)
    }
}
