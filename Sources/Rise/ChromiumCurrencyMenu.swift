import AppKit
import RiseCore

/// An amount of money selected in another currency heads the page's menu as its value in the
/// person's own (`CurrencyAmounts`: "£66.06" reads "€76.82"), opening to Copy, Replace on Page,
/// which rewrites every amount on the page into their currency until it's unchecked, and Other
/// Currencies, each with its own amount to copy.
@MainActor extension BrowserController {
    static let currencyWorld = ScriptWorld.named("Rise.Currency")

    /// The amounts in `text` to head the menu with. One in the person's currency has nothing to
    /// say, unless it's the page's own rewrite, when it offers to put the page back.
    func selectedAmounts(_ text: String, in page: ChromiumPage, replaced: Bool) -> [CurrencyAmount] {
        guard text.contains(where: \.isNumber) else { return [] }
        ExchangeRateStore.shared.refreshIfStale()
        guard let rates = ExchangeRateStore.shared.rates else { return [] }
        let primary = PrimaryCurrency.code(in: preferences)
        return CurrencyAmounts.find(in: text, host: page.url?.host, rates: rates).filter { replaced || $0.currency != primary }
    }

    func currencyItems(for amounts: [CurrencyAmount], in tab: BrowserTab, replaced: Bool) -> [NSMenuItem] {
        guard let rates = ExchangeRateStore.shared.rates else { return [] }
        let primary = PrimaryCurrency.code(in: preferences)
        let currencies = CurrencyAmounts.currencies(in: rates)
        let groups = [currencies.popular, currencies.others].map { $0.filter { $0.code != primary } }
        return amounts.compactMap { amount in
            guard let converted = CurrencyAmounts.converted(amount, to: primary, rates: rates),
                  let title = CurrencyAmounts.label(amount, of: amounts.count, to: primary, rates: rates) else { return nil }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "banknote", accessibilityDescription: nil)
            let submenu = NSMenu(); submenu.autoenablesItems = false
            let copied = convertedCopy(converted)
            let copy = menuItem("Copy “\(copied)”") { Self.copyAmount(copied) }
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            submenu.addItem(copy)
            let replace = menuItem("Replace on Page", checked: replaced) { [weak self, weak tab] in
                guard let self, let tab else { return }
                currencyReplacement.set(!replaced, in: tab, to: primary, rates: rates)
            }
            submenu.addItem(replace)
            submenu.addItem(.separator())
            let others = NSMenuItem(title: "Other Currencies", action: nil, keyEquivalent: "")
            others.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            let list = NSMenu(); list.autoenablesItems = false
            // The most traded first, then every other by name.
            for (index, group) in groups.enumerated() {
                if index > 0, !group.isEmpty, !list.items.isEmpty { list.addItem(.separator()) }
                for currency in group {
                    let entry = NSMenuItem(title: "\(currency.name) (\(currency.code))", action: nil, keyEquivalent: "")
                    entry.submenu = CurrencyAmountMenu(amount, in: currency.code, rates: rates, keepsUnits: copiesConversionUnits)
                    list.addItem(entry)
                }
            }
            others.submenu = list
            submenu.addItem(others)
            item.submenu = submenu
            return item
        }
    }

    static func copyAmount(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
}

/// A currency's submenu: the amount in it, to copy, worked out only as it opens, so a menu of
/// every currency costs nothing until one is looked at. Copied, it's the number alone unless
/// units are kept (`copiesConversionUnits`).
@MainActor final class CurrencyAmountMenu: NSMenu, NSMenuDelegate {
    private let amount: CurrencyAmount, currency: String, rates: ExchangeRates, keepsUnits: Bool

    init(_ amount: CurrencyAmount, in currency: String, rates: ExchangeRates, keepsUnits: Bool = false) {
        self.amount = amount; self.currency = currency; self.rates = rates; self.keepsUnits = keepsUnits
        super.init(title: "")
        autoenablesItems = false
        delegate = self
        // A submenu with nothing in it doesn't open.
        addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
    }
    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let text = CurrencyAmounts.converted(amount, to: currency, rates: rates) else { return }
        removeAllItems()
        let item = NSMenuItem(title: text, action: #selector(copyAmount(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = keepsUnits ? text : AddressCalculation.bareNumber(in: text) ?? text
        addItem(item)
    }

    @objc private func copyAmount(_ item: NSMenuItem) {
        if let text = item.representedObject as? String { BrowserController.copyAmount(text) }
    }
}
