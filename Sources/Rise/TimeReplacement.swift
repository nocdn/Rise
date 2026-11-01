import AppKit
import RiseCore

/// Local times use the same permission-style notice as replaced prices. A held shortcut is
/// deliberately silent, bound to the page it began on, and always restored on focus loss.
@MainActor final class TimeReplacement {
    static let command = "toggleLocalTimes", holdDuration: TimeInterval = 0.3
    static let world = ScriptWorld.named("Rise.Times")
    weak var browser: BrowserController?
    let panel = PermissionPanel()
    private let conversions = NSMapTable<ChromiumPage, TimePageConversion>.weakToStrongObjects()
    private weak var noticePage: ChromiumPage?
    private weak var undoPage: ChromiumPage?
    private var undoUntil = Date.distantPast
    private var putAway: DispatchWorkItem?
    private var holdsUntilExit = false
    private var held: (page: ChromiumPage, wasActive: Bool, began: TimeInterval, modifiers: NSEvent.ModifierFlags)?
    private var heldKey: UInt16?
    init(browser: BrowserController) {
        self.browser = browser
        panel.applyTheme(browser.theme); panel.setRevertShortcut("⌘Z")
        panel.onRevert = { [weak self] in
            guard let self, let page = noticePage else { return }
            set(false, in: page, announces: false); panel.hide()
        }
        panel.onPointerExit = { [weak self] in
            guard let self, holdsUntilExit else { return }
            holdsUntilExit = false; panel.hide()
        }
    }
    func conversion(for page: ChromiumPage) -> TimePageConversion {
        if let existing = conversions.object(forKey: page) { return existing }
        let conversion = TimePageConversion { [weak page] body, arguments in
            guard let page else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                page.evaluate(body, arguments: arguments, in: nil, world: Self.world, userGesture: false) { continuation.resume(with: $0) }
            }
        }
        conversions.setObject(conversion, forKey: page)
        return conversion
    }
    func isActive(in page: ChromiumPage) -> Bool { conversions.object(forKey: page)?.isActive == true }

    func set(_ on: Bool, in page: ChromiumPage, announces: Bool = true) {
        let conversion = conversion(for: page)
        Task { [weak self, weak page] in
            do {
                let count = try await conversion.set(on)
                guard let self, let page, announces, self.held == nil, conversion.isActive == on else { return }
                if on { undoPage = page; undoUntil = Date().addingTimeInterval(CurrencyReplacement.undoWindow) }
                show(on ? TimePageConversion.message(count) : TimePageConversion.restoredMessage, in: page, canRevert: on && count > 0)
            } catch {
                guard let self, let page, announces else { return }
                show("Couldn’t replace times on this page", in: page, canRevert: false)
            }
        }
    }
    func toggle() {
        cancelHold()
        guard let page = browser?.findTab?.page as? ChromiumPage else { return }
        set(!isActive(in: page), in: page)
    }
    private func show(_ message: String, in page: ChromiumPage, canRevert: Bool) {
        guard let browser, browser.findTab?.page === page else { return }
        putAway?.cancel(); holdsUntilExit = false; noticePage = page
        panel.tell(PermissionPanel.Notice(image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil)!, accent: { $0.text },
            text: { theme, font in NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: theme.text]) }, message: message))
        panel.revertButton.isHidden = !canRevert
        PermissionCoordinator.place(panel, over: page.view, in: browser)
        panel.present()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if panel.isPointerInside { holdsUntilExit = true } else { panel.hide() }
        }
        putAway = work; DispatchQueue.main.asyncAfter(deadline: .now()+TimePageConversion.noticeDuration, execute: work)
    }
    func layoutPanel() {
        if let held, browser?.findTab?.page !== held.page { cancelHold() }
        guard let browser, let page = noticePage, !panel.isHidden else { return }
        guard browser.findTab?.page === page else { panel.hide(); return }
        PermissionCoordinator.place(panel, over: page.view, in: browser)
    }
    func handleUndoKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let browser, browser.palette.isHidden, !(browser.window?.firstResponder is NSTextView),
              browser.keyboardShortcuts.matches("undo:", event), Date() < undoUntil,
              let page = undoPage, browser.findTab?.page === page, isActive(in: page) else { return false }
        undoPage = nil; set(false, in: page, announces: false); panel.hide(); return true
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .keyUp, heldKey == event.keyCode {
            finishHold(at: event.timestamp); heldKey = nil; return true
        }
        if event.type == .flagsChanged, let held, !event.modifierFlags.isSuperset(of: held.modifiers) {
            finishHold(at: event.timestamp); return false
        }
        guard event.type == .keyDown else { return false }
        if heldKey == event.keyCode { return true } // Key repeats and AppKit's second dispatch.
        guard let browser, browser.keyboardShortcuts.matches(Self.command, event) else { return false }
        guard browser.palette.isHidden, !(browser.window?.firstResponder is NSTextView),
              let page = browser.findTab?.page as? ChromiumPage else { return true }
        heldKey = event.keyCode
        let active = isActive(in: page)
        held = (page, active, event.timestamp, event.modifierFlags.intersection(KeyboardShortcut.modifierMask))
        panel.hide()
        if !active { set(true, in: page, announces: false) }
        return true
    }
    private func finishHold(at timestamp: TimeInterval) {
        guard let held else { return }
        guard browser?.findTab?.page === held.page else { cancelHold(); return }
        self.held = nil
        if timestamp-held.began >= Self.holdDuration {
            if !held.wasActive { set(false, in: held.page, announces: false) }
        } else {
            // A quick release commits the conversion, or toggles a previously converted page off.
            if held.wasActive { set(false, in: held.page) }
            else {
                Task { [weak self, weak page = held.page] in
                    guard let self, let page else { return }
                    let conversion = conversion(for: page)
                    // Serialize after any in-flight initial DOM pass before announcing its count.
                    await conversion.waitUntilReady()
                    guard conversion.isActive, self.held == nil else { return }
                    undoPage = page; undoUntil = Date().addingTimeInterval(CurrencyReplacement.undoWindow)
                    show(TimePageConversion.message(conversion.count), in: page, canRevert: conversion.count > 0)
                }
            }
        }
    }
    func cancelHold() {
        heldKey = nil
        guard let held else { return }
        self.held = nil
        if !held.wasActive { set(false, in: held.page, announces: false) }
    }
}

@MainActor extension BrowserController {
    @objc func toggleLocalTimes() { timeReplacement.toggle() }
    func timeReplaceItem(in page: ChromiumPage) -> NSMenuItem {
        let replaced = timeReplacement.isActive(in: page)
        let item = menuItem("Replace on Page", checked: replaced) { [weak self, weak page] in
            guard let self, let page else { return }
            timeReplacement.set(!replaced, in: page)
        }
        item.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        return item
    }
}
