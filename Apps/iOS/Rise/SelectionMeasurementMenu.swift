import UIKit
import WebKit

/// A weight, distance, temperature or speed selected in other units, in the selection menu as it
/// is in the person's (`SelectionMeasurements`: "5 km" reads "3.11 mi" in the US), in place of the
/// system's conversion. It opens to Copy, Replace on Page, which rewrites every measurement on the
/// page into their units until it's unchecked, and Other Units, whose choice is copied and shown in a toast.
@MainActor enum SelectionMeasurementMenu {
    static let menuIdentifier = UIMenu.Identifier("dev.bartosz.Rise.selectionMeasurements")

    static func build(_ builder: UIMenuBuilder, in page: WKWebView) {
        guard builder.system == .context else { return }
        let elements = elements(for: SelectionTimeMenu.selection(in: page), in: page)
        guard !elements.isEmpty else { return }
        let menu = UIMenu(identifier: menuIdentifier, options: .displayInline, children: elements)
        // After an amount's or a time's, which come first as they did before.
        if builder.menu(for: SelectionCurrencyMenu.menuIdentifier) != nil { builder.insertSibling(menu, afterMenu: SelectionCurrencyMenu.menuIdentifier) }
        else if builder.menu(for: SelectionTimeMenu.menuIdentifier) != nil { builder.insertSibling(menu, afterMenu: SelectionTimeMenu.menuIdentifier) }
        else { builder.insertChild(menu, atStartOfMenu: .root) }
    }

    /// Whether `text` has a measurement Rise reads, in the person's units or not, so the system's
    /// conversion of it goes.
    static func hasMeasurement(in text: String) -> Bool { !SelectionMeasurements.find(in: text).isEmpty }

    /// Each measurement in `text` that's in other units, converted. On a page Replace on Page has
    /// rewritten, those in the person's units too, to put it back.
    static func elements(for text: String, in page: WKWebView?, units: PreferredUnits = .current()) -> [UIMenuElement] {
        let replaced = page.map(SelectionTimeMenu.isMeasurementReplaced) ?? false
        return SelectionMeasurements.conversions(in: text, to: units, includingOwn: replaced).enumerated().map { index, conversion in
            let converted = conversion.converted
            let copy = UIAction(title: "Copy “\(converted)”", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = converted
            }
            let replace = UIAction(title: "Replace on Page", image: UIImage(systemName: "arrow.left.arrow.right"),
                                   state: replaced ? .on : .off) { [weak page] _ in
                if let page { SelectionTimeMenu.replaceMeasurements(!replaced, in: page) }
            }
            var children: [UIMenuElement] = [copy, replace]
            if !conversion.others.isEmpty {
                children.append(UIMenu(title: "Other Units", image: UIImage(systemName: "globe"), children: conversion.others.map { other in
                    let action = UIAction(title: other.value) { [weak page] _ in
                        UIPasteboard.general.string = other.value
                        page.flatMap(browser)?.showCopiedMeasurement(other.value, kind: conversion.measurement.unit.kind)
                    }
                    action.subtitle = other.name
                    return action
                }))
            }
            return UIMenu(title: conversion.label, image: UIImage(systemName: conversion.measurement.unit.kind.symbol),
                          identifier: UIMenu.Identifier("\(menuIdentifier.rawValue).\(index)"), children: children)
        }
    }

    private static func browser(_ page: WKWebView) -> BrowserViewController? {
        var responder: UIResponder? = page
        while let next = responder?.next {
            if let browser = next as? BrowserViewController { return browser }
            responder = next
        }
        return nil
    }
}

@MainActor extension BrowserViewController {
    /// A measurement in other units, copied from the selection menu.
    func showCopiedMeasurement(_ value: String, kind: MeasurementKind) { showMeasurementToast("Copied \(value)") }

    /// Says what Replace on Page did, or what was copied. With `revert`, a tap on it puts the page's own back.
    func showMeasurementToast(_ message: String, revert: (() -> Void)? = nil) {
        let toast = CurrencyToast(message: message, glyph: MenuIcons.units, name: "measurements")
        toast.revertedMessage = SelectionMeasurements.restoredMessage
        toast.displayDuration = TimePageConversion.noticeDuration
        toast.revert = revert
        showToast(toast)
        toast.leave(after: toast.displayDuration)
        UIAccessibility.post(notification: .announcement, argument: toast.label.text)
    }
}
