import UIKit
import WebKit

/// An amount of money selected in another currency, first in the selection menu as its value in the
/// person's own (`CurrencyAmounts`: "£66.06" reads "€76.82"), in place of the system's conversion.
/// It opens to Copy, Replace on Page, which rewrites every amount on the page into their currency
/// until it's unchecked, and Other Currencies, whose choice is copied and shown in a toast.
@MainActor enum SelectionCurrencyMenu {
    static let menuIdentifier = UIMenu.Identifier("dev.bartosz.Rise.selectionCurrency")

    static func build(_ builder: UIMenuBuilder, in page: WKWebView) {
        guard builder.system == .context else { return }
        let elements = elements(for: SelectionTimeMenu.selection(in: page), in: page)
        guard !elements.isEmpty else { return }
        let menu = UIMenu(identifier: menuIdentifier, options: .displayInline, children: elements)
        // After a time's, which is as much the selection's own.
        if builder.menu(for: SelectionTimeMenu.menuIdentifier) != nil { builder.insertSibling(menu, afterMenu: SelectionTimeMenu.menuIdentifier) }
        else { builder.insertChild(menu, atStartOfMenu: .root) }
    }

    /// Each amount in `text`, converted. One already in the person's currency has nothing to say,
    /// unless it's the page's own rewrite, when it offers to put the page back.
    static func elements(for text: String, in page: WKWebView?, primary: String = PrimaryCurrency.code(),
                         rates: ExchangeRates? = ExchangeRateStore.shared.rates) -> [UIMenuElement] {
        guard text.contains(where: \.isNumber) else { return [] }
        ExchangeRateStore.shared.refreshIfStale()
        guard let rates, rates.rates[primary] != nil else { return [] }
        let replaced = page.map(SelectionTimeMenu.isCurrencyReplaced) ?? false
        let amounts = CurrencyAmounts.find(in: text, host: page?.url?.host, rates: rates).filter { replaced || $0.currency != primary }
        let currencies = CurrencyAmounts.currencies(in: rates)
        let groups = [currencies.popular, currencies.others].map { $0.filter { $0.code != primary } }
        return amounts.enumerated().compactMap { index, amount in
            guard let converted = CurrencyAmounts.converted(amount, to: primary, rates: rates),
                  let title = CurrencyAmounts.label(amount, of: amounts.count, to: primary, rates: rates) else { return nil }
            let copy = UIAction(title: "Copy “\(converted)”", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = converted
            }
            let replace = UIAction(title: "Replace on Page", image: UIImage(systemName: "arrow.left.arrow.right"),
                                   state: replaced ? .on : .off) { [weak page] _ in
                if let page { setReplaced(!replaced, in: page, primary: primary, rates: rates) }
            }
            // The most traded first, then every other by name, each in a section of its own.
            let others = UIMenu(title: "Other Currencies", image: UIImage(systemName: "globe"), children: groups.map { group in
                UIMenu(options: .displayInline, children: group.map { currency in
                    let action = UIAction(title: currency.name) { [weak page] _ in
                        guard let value = CurrencyAmounts.converted(amount, to: currency.code, rates: rates) else { return }
                        UIPasteboard.general.string = value
                        page.flatMap(browser)?.showCopiedAmount(value)
                    }
                    action.subtitle = currency.code
                    return action
                })
            })
            return UIMenu(title: title, image: MenuIcons.selectionCurrency,
                          identifier: UIMenu.Identifier("\(menuIdentifier.rawValue).\(index)"), children: [copy, replace, others])
        }
    }

    /// Rewrites the page's amounts into `primary`, or puts them back, in the main frame.
    static func setReplaced(_ on: Bool, in page: WKWebView, primary: String, rates: ExchangeRates, announces: Bool = true) {
        let body = on ? CurrencyAmounts.applyBody : CurrencyAmounts.restoreBody
        let arguments: [String: Any] = on ? ["options": CurrencyAmounts.replaceOptions(to: primary, rates: rates)] : [:]
        page.callAsyncJavaScript(body, arguments: arguments, in: nil, in: SelectionTimeMenu.world) { [weak page] result in
            guard let page, case .success(let value) = result else { return }
            SelectionTimeMenu.setCurrencyReplaced(on, in: page)
            UISelectionFeedbackGenerator().selectionChanged()
            guard announces else { return }
            let count = on ? (value as? NSNumber)?.intValue ?? 0 : nil
            // Tapping it, while it shows what was replaced, puts the page's own prices back.
            let revert: (() -> Void)? = (count ?? 0) > 0 ? { [weak page] in
                if let page { setReplaced(false, in: page, primary: primary, rates: rates, announces: false) }
            } : nil
            browser(page)?.showCurrencyToast(replacedToast(count, in: primary), revert: revert)
        }
    }

    /// What Replace on Page did: how many prices it rewrote, or that it put them back (nil).
    static func replacedToast(_ count: Int?, in currency: String) -> String {
        guard let count else { return "Original prices restored" }
        switch count {
        case 0: return "No other prices to replace"
        case 1: return "Replaced 1 price with \(currency)"
        default: return "Replaced \(count) prices with \(currency)"
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
    /// An amount in another currency, copied from the selection menu.
    func showCopiedAmount(_ amount: String) { showCurrencyToast("Copied \(amount)") }

    /// Says what Replace on Page did, or what was copied. With `revert`, a tap on it (not a drag)
    /// reverts, its words turning into saying so, and it stays its usual time from then.
    func showCurrencyToast(_ message: String, revert: (() -> Void)? = nil) {
        let toast = CurrencyToast(message: message, glyph: MenuIcons.currency, name: "currency")
        toast.revert = revert
        showToast(toast)
        toast.leave(after: 2)
        UIAccessibility.post(notification: .announcement, argument: toast.label.text)
    }

    func showTimeToast(_ message: String, revert: (() -> Void)? = nil) {
        let toast = CurrencyToast(message: message, glyph: UIImage(systemName: "clock"), name: "times")
        toast.revertedMessage = TimePageConversion.restoredMessage
        toast.displayDuration = TimePageConversion.noticeDuration
        toast.revert = revert
        showToast(toast)
        toast.leave(after: toast.displayDuration)
        UIAccessibility.post(notification: .announcement, argument: toast.label.text)
    }
}

/// A toast that a tap can answer: Replace on Page's reverts the page.
@MainActor final class CurrencyToast: Toast {
    static let reverted = "Reverted currencies"
    var revertedMessage = CurrencyToast.reverted
    var displayDuration: TimeInterval = 2
    var revert: (() -> Void)? { didSet { tap.isEnabled = revert != nil; accessibilityTraits = revert == nil ? .staticText : .button } }
    private let tap = UITapGestureRecognizer()

    override init(message: String, motionName: String, leadingInset: CGFloat = 47, trailingInset: CGFloat = 22) {
        super.init(message: message, motionName: motionName, leadingInset: leadingInset, trailingInset: trailingInset)
        tap.addTarget(self, action: #selector(tapped)); tap.isEnabled = false
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        guard let revert, !dismissed else { return }
        self.revert = nil
        revert()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        setMessage(revertedMessage)
        accessibilityLabel = revertedMessage
        UIAccessibility.post(notification: .announcement, argument: revertedMessage)
        leave(after: displayDuration)
    }
}
