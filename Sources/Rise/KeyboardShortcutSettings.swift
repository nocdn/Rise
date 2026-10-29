import AppKit

@MainActor extension BrowserController {
    func handleKeyboardShortcutsRequest(_ body: [String: Any], from page: WebPage?, reply: @escaping (Any?, String?) -> Void) {
        let id = body["id"] as? String ?? ""
        var error: String?
        switch body["action"] as? String {
        case "list":
            if body["resetCapture"] as? Bool == true, shortcutRecordingPage === page {
                shortcutRecordingPage = nil; shortcutRecordingID = nil; shortcutRecordingCandidate = nil
            }
        case "set":
            guard let index = body["index"] as? Int, let value = body["shortcut"] as? String else { reply(nil, "Invalid shortcut"); return }
            error = keyboardShortcuts.set(id, at: index, to: value)
        case "assign", "remove":
            guard let value = body["shortcut"] as? String else { reply(nil, "Invalid shortcut"); return }
            error = body["action"] as? String == "assign" ? keyboardShortcuts.assign(value, to: id) : keyboardShortcuts.remove(value, from: id)
        case "reset": error = keyboardShortcuts.reset(id)
        case "resetAll": keyboardShortcuts.resetAll()
        case "capture":
            if body["capturing"] as? Bool == true {
                guard let page, selectedTab?.page === page, let index = body["index"] as? Int,
                      keyboardShortcuts.commands.contains(where: { $0.id == id }),
                      (0...keyboardShortcuts.bindings(id).count).contains(index) else { reply(nil, "Invalid recorder"); return }
                shortcutRecordingPage = page; shortcutRecordingID = id; shortcutRecordingIndex = index
                shortcutRecordedKeyCode = nil; shortcutRecordingCandidate = nil; shortcutRecordingModifiers = []
            } else if shortcutRecordingID == id, shortcutRecordingIndex == body["index"] as? Int {
                shortcutRecordingPage = nil; shortcutRecordingID = nil; shortcutRecordingCandidate = nil
            }
        case "openSystemSettings":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") { NSWorkspace.shared.open(url) }
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

    /// A recorder belongs to the settings document that opened it, not the next tab/window.
    func cancelShortcutRecording() {
        guard let id = shortcutRecordingID else { return }
        let page = shortcutRecordingPage
        let detail: [String: Any] = ["id": id, "index": shortcutRecordingIndex, "cancelled": true]
        shortcutRecordingID = nil; shortcutRecordingPage = nil; shortcutRecordingCandidate = nil
        page?.evaluate("dispatchEvent(new CustomEvent('rise-shortcut-recorded', {detail: payload}))", arguments: ["payload": detail], in: nil, world: .page) { _ in }
    }

    /// Recording happens before AppKit's menu and Chromium shortcuts, so even ⌘W or ⌘Q
    /// can be previewed safely. Only the editor's explicit Save action changes a binding.
    func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
        if event.type == .keyDown || event.type == .keyUp, event.keyCode == shortcutRecordedKeyCode {
            if event.type == .keyUp { shortcutRecordedKeyCode = nil }
            return true
        }
        if let id = shortcutRecordingID, let page = shortcutRecordingPage {
            if selectedTab?.page === page, selectedTab?.url?.host == "settings",
               ["rise", "chrome"].contains(selectedTab?.url?.scheme ?? "") {
                guard event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged else { return false }
                var detail: [String: Any] = ["id": id, "index": shortcutRecordingIndex]
                if event.type == .flagsChanged {
                    let modifiers = event.modifierFlags.intersection(KeyboardShortcut.modifierMask)
                    let added = modifiers.subtracting(shortcutRecordingModifiers)
                    shortcutRecordingModifiers = modifiers
                    guard !added.isEmpty else { return true }
                    shortcutRecordingCandidate = nil
                    detail["error"] = "Include a key that is not a modifier."
                } else if event.type != .keyDown { return true }
                else if event.keyCode == 53 {
                    shortcutRecordedKeyCode = event.keyCode
                    detail["cancelled"] = true
                    shortcutRecordingID = nil; shortcutRecordingPage = nil; shortcutRecordingCandidate = nil
                } else if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.intersection(KeyboardShortcut.modifierMask).isEmpty,
                          shortcutRecordingCandidate != nil {
                    shortcutRecordedKeyCode = event.keyCode; detail["commit"] = true
                } else if let binding = KeyboardShortcut(event: event), binding.isAssignable {
                    shortcutRecordingCandidate = binding; shortcutRecordedKeyCode = event.keyCode
                    detail["shortcut"] = binding.rawValue; detail["display"] = binding.display
                } else {
                    shortcutRecordingCandidate = nil
                    detail["error"] = "Include Command, Control or Option, or use a function key. Escape cancels."
                }
                page.evaluate("dispatchEvent(new CustomEvent('rise-shortcut-recorded', {detail: payload}))", arguments: ["payload": detail], in: nil, world: .page) { _ in }
                return true
            }
            cancelShortcutRecording()
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
