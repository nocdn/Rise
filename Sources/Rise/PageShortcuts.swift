import AppKit
import RiseChromium

/// A shortcut on its way to the page, which gets it before Rise does.
struct PendingPageKey {
    let commandID: String
    let keyCode: UInt16
    let timestamp: TimeInterval
    let isRepeat: Bool
    let shortcut: String
}

/// A page gets the shortcuts it might want before Rise does, as in Chrome, so ⌘Z, ⌘B and ⌘F work in
/// Google Docs and the like. One it doesn't use comes back and runs as usual. One it keeps says so
/// in the page bar, if Rise's own command for that key could run now, and pressing it again while
/// the bar says so runs Rise's command.
@MainActor extension BrowserController {
    /// How long the bar offers Rise's command for a shortcut the page kept.
    static let pageShortcutAgainWindow: TimeInterval = 1.25
    /// What's the browser's alone, as Chrome keeps them from pages: a page can't stop you leaving it.
    static let browserOnlyCommands: Set<String> = [
        "newTab", "closeCurrentTab", "performClose:", "reopenTab", "nextTab", "previousTab", "showSettings",
        "terminate:", "hide:", "hideOtherApplications:", "performMiniaturize:", "toggleFullScreen:",
    ]
    /// The page's own editing: when it keeps these it has done them, and Rise has nothing to offer.
    static let editingCommands: Set<String> = ["cut:", "copy:", "paste:", "pasteAndMatchStyle:", "selectAll:"]
    private static let findCommands: Set<String> = ["showFind", "findNext", "findPrevious", "skipToNextMatch", "skipToPreviousMatch"]
    private static let undoCommands: Set<String> = ["undo:", "redo:"]

    /// The page view that has the keyboard, if one does.
    var keyboardBrowserView: RCBrowserView? {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if let browserView = current as? RCBrowserView { return browserView }
            view = current.superview
        }
        return nil
    }

    /// Sends the shortcut on to the page if it's the page's to try first. A second press while the
    /// bar offers Rise's command is Rise's, and holding the keys down is still the first press.
    func letPageTryShortcut(_ command: KeyboardShortcuts.Command, _ event: NSEvent) -> Bool {
        // The window sees a key press more than once on its way to the page.
        if let pending = pendingPageKey, pending.timestamp == event.timestamp, pending.keyCode == event.keyCode { return true }
        guard !Self.browserOnlyCommands.contains(command.id), !command.id.hasPrefix("selectTab"),
              let browserView = keyboardBrowserView else { return false }
        // An open find bar's commands stay its own, though the page has the keyboard.
        if Self.findCommands.contains(command.id), findBar.isPresented { return false }
        if let again = shortcutAgain, again.id == command.id, Date() < again.until, !event.isARepeat {
            shortcutAgain = nil; selectedBar.hideNotice()
            return false
        }
        if !Self.undoCommands.contains(command.id) { tabMoveSequence = nil; tabOrderUndoPending = false }
        pendingPageKey = PendingPageKey(commandID: command.id, keyCode: event.keyCode, timestamp: event.timestamp, isRepeat: event.isARepeat,
                                        shortcut: KeyboardShortcut(event: event)?.display ?? "")
        browserView.watchNextKeyPress()
        return true
    }
    /// The page used the shortcut. The bar offers Rise's command, if there's one it could run now.
    func pageUsedKey(code: UInt16) {
        guard let pending = pendingPageKey, pending.keyCode == code else { return }
        pendingPageKey = nil
        guard !pending.isRepeat, let action = browserAction(for: pending.commandID) else { return }
        shortcutAgain = (pending.commandID, Date().addingTimeInterval(Self.pageShortcutAgainWindow))
        selectedBar.showNotice("Press \(pending.shortcut) again to \(action)", image: BarNotice.commandImage, hold: Self.pageShortcutAgainWindow)
    }
    /// The page had no use for the shortcut. Rise's undo goes ahead of the menu bar's, which would
    /// only ask the page to undo; anything else goes to the menu bar next.
    func handleUnusedPageKey(_ event: NSEvent) -> Bool {
        guard let pending = pendingPageKey, pending.keyCode == event.keyCode else { return false }
        pendingPageKey = nil
        return Self.undoCommands.contains(pending.commandID) && runBrowserUndo(event)
    }
    /// Rise's own undo, of what it last did, ahead of the page's: ⌘Z after a tab moved, say.
    func runBrowserUndo(_ event: NSEvent) -> Bool {
        timeReplacement.handleUndoKey(event) || currencyReplacement.handleUndoKey(event) || handleSelectionItemUndoKey(event)
            || handleTabOrderUndoKey(event) || palette.handleUndoKey(event, shortcuts: keyboardShortcuts)
            || handleSplitUndoKey(event) || handlePeekUndoKey(event)
    }
    /// What ⌘Z or ⇧⌘Z would do in Rise now, in `runBrowserUndo`'s order, in words after "to".
    private func browserUndoAction(redo: Bool) -> String? {
        if !redo {
            if timeReplacement.canUndo { return "undo Replace Times" }
            if currencyReplacement.canUndo { return "undo Replace Prices" }
        }
        if let item = selectionItemUndoAction(redo: redo) { return item }
        if let order = tabOrderUndoAction(redo: redo) { return order }
        guard !redo else { return nil }
        if splitUndo != nil { return "undo Split View" }
        if peekUndo != nil { return "return to the Peek" }
        return nil
    }
    /// Rise's command for a shortcut, in words after "to", if it could run now.
    private func browserAction(for id: String) -> String? {
        if Self.undoCommands.contains(id) { return browserUndoAction(redo: id == "redo:") }
        guard !Self.editingCommands.contains(id), let command = keyboardShortcuts.commands.first(where: { $0.id == id }),
              let item = command.items.first, item.action != nil,
              let target = item.target as? NSMenuItemValidation, target.validateMenuItem(item) else { return nil }
        // Again and skip have nothing to go on without an earlier search.
        if Self.findCommands.contains(id), id != "showFind", findBar.input.stringValue.isEmpty { return nil }
        // Validating a menu item sets its title for now, such as Hide or Show Sidebar.
        return (id.hasPrefix("selectTab") ? command.title : item.title).replacingOccurrences(of: "…", with: "")
    }
    /// A document on a canvas, with no text in the page for find to search: Google Docs and Sheets.
    static func drawsItsOwnText(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased() == "docs.google.com", url.pathComponents.count > 1 else { return false }
        return ["document", "spreadsheets"].contains(url.pathComponents[1])
    }
}
