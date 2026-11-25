import AppKit
import RiseCore

/// A weight, distance, temperature or speed selected in other units heads the page's menu as it is
/// in the person's (`SelectionMeasurements`: "5 km" reads "3.11 mi" in the US), opening to Copy,
/// Replace on Page, which rewrites every measurement on the page into their units until it's
/// unchecked, and Other Units, each its own measurement to copy.
@MainActor extension BrowserController {
    var preferredUnits: PreferredUnits { PreferredUnits.current(in: preferences) }

    func measurementItems(for text: String, in page: ChromiumPage) -> [NSMenuItem] {
        guard !text.isEmpty, text.contains(where: \.isNumber) else { return [] }
        let replaced = measurementReplacement.isActive(in: page)
        // On a page already rewritten, its own measurements offer to put it back.
        return SelectionMeasurements.conversions(in: text, to: preferredUnits, includingOwn: replaced).map { conversion in
            let item = NSMenuItem(title: conversion.label, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: conversion.measurement.unit.kind.symbol, accessibilityDescription: nil)
            let submenu = NSMenu(); submenu.autoenablesItems = false
            let copy = menuItem("Copy “\(conversion.converted)”") { Self.copyAmount(conversion.converted) }
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            submenu.addItem(copy)
            let replace = menuItem("Replace on Page", checked: replaced) { [weak self, weak page] in
                guard let self, let page else { return }
                measurementReplacement.set(!replaced, in: page)
            }
            replace.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
            submenu.addItem(replace)
            if !conversion.others.isEmpty {
                submenu.addItem(.separator())
                let others = NSMenuItem(title: "Other Units", action: nil, keyEquivalent: "")
                others.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                let list = NSMenu(); list.autoenablesItems = false
                for other in conversion.others {
                    let entry = menuItem(other.value) { Self.copyAmount(other.value) }
                    entry.toolTip = "Copy in \(other.name.lowercased())"
                    list.addItem(entry)
                }
                others.submenu = list
                submenu.addItem(others)
            }
            item.submenu = submenu
            return item
        }
    }
}

/// Replace on Page for measurements: the page's in the person's units while it's on, saying so in
/// the same notice as local times, with Revert, and put back when the page goes.
@MainActor final class MeasurementReplacement {
    static let world = ScriptWorld.named("Rise.Measurements")
    weak var browser: BrowserController?
    let panel = PermissionPanel()
    private let conversions = NSMapTable<ChromiumPage, PageTextConversion>.weakToStrongObjects()
    private weak var noticePage: ChromiumPage?
    private var putAway: DispatchWorkItem?
    private var holdsUntilExit = false

    init(browser: BrowserController) {
        self.browser = browser
        panel.applyTheme(browser.theme)
        panel.onRevert = { [weak self] in
            guard let self, let page = noticePage else { return }
            set(false, in: page, announces: false); panel.hide()
        }
        panel.onPointerExit = { [weak self] in
            guard let self, holdsUntilExit else { return }
            holdsUntilExit = false; panel.hide()
        }
    }

    private func conversion(for page: ChromiumPage) -> PageTextConversion {
        if let existing = conversions.object(forKey: page) { return existing }
        let conversion = PageTextConversion(global: "riseMeasurements") { [weak page] body, arguments in
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
        let units = browser?.preferredUnits ?? .current(), locale = Locale.current
        Task { [weak self, weak page] in
            do {
                let count = try await conversion.set(on) { SelectionMeasurements.edits(in: $0, to: units, locale: locale) }
                guard let self, let page, announces, conversion.isActive == on else { return }
                show(on ? SelectionMeasurements.message(count, in: units) : SelectionMeasurements.restoredMessage, in: page, canRevert: on && count > 0)
            } catch {
                guard let self, let page, announces else { return }
                show("Couldn’t replace measurements on this page", in: page, canRevert: false)
            }
        }
    }

    private func show(_ message: String, in page: ChromiumPage, canRevert: Bool) {
        guard let browser, browser.findTab?.page === page else { return }
        putAway?.cancel(); holdsUntilExit = false; noticePage = page
        panel.tell(PermissionPanel.Notice(image: NSImage(systemSymbolName: "ruler", accessibilityDescription: nil)!, accent: { $0.text },
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
        guard let browser, let page = noticePage, !panel.isHidden else { return }
        guard browser.findTab?.page === page else { panel.hide(); return }
        PermissionCoordinator.place(panel, over: page.view, in: browser)
    }
}
