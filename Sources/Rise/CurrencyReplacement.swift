import AppKit
import RiseCore

/// Replace on Page, while it has a page's prices in the person's currency: the coins in its bar,
/// grown in as a permission's icon is and staying until it's reverted, and the permission panel
/// coming down out of them to say how many it replaced, with Revert in place of its check and
/// cross. ⌘Z reverts too, for a little while.
@MainActor final class CurrencyReplacement {
    weak var browser: BrowserController?
    let panel = PermissionPanel()
    /// The tab whose replacement the panel tells of.
    private weak var tab: BrowserTab?
    /// A tab whose icon stays while its reverted panel goes back up into it.
    private(set) weak var leavingTab: BrowserTab?
    private(set) var leavingCode: String?
    /// The last replacement ⌘Z reverts, until when.
    private weak var undoTab: BrowserTab?
    private var undoUntil = Date.distantPast
    private var putAway: DispatchWorkItem?
    /// Its time up while the pointer was on it: it goes as the pointer leaves.
    private var holdsUntilExit = false
    /// Each replaced tab's address and load, as last seen.
    private var seen: [ObjectIdentifier: (url: URL?, loading: Bool)] = [:]
    static let undoWindow: TimeInterval = 10, shownFor: TimeInterval = 5
    static let world = BrowserController.currencyWorld

    init(browser: BrowserController) {
        self.browser = browser
        applyTheme(browser.theme)
        panel.setRevertShortcut("⌘Z")
        panel.onPointerExit = { [weak self] in
            guard let self, holdsUntilExit else { return }
            holdsUntilExit = false; panel.hide()
        }
        panel.onRevert = { [weak self] in self?.revert() }
        panel.onGone = { [weak self] in self?.panelGone() }
    }
    /// Revert turns money's colour under the pointer, as Allow turns green.
    func applyTheme(_ theme: RiseTheme) { panel.applyTheme(theme); panel.revertButton.hoverTint = Self.accent(theme) }

    /// The colour of money: the deep pink Rise on iPhone gives its currency setting.
    static func accent(_ theme: RiseTheme) -> NSColor {
        NSColor(hex: theme.appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0xE84884 : 0xC41E62)
    }
    static func message(_ count: Int, _ code: String) -> String {
        "Replaced \(count) \(count == 1 ? "value" : "values") with \(code) on the page"
    }
    private func notice(_ count: Int, _ code: String) -> PermissionPanel.Notice {
        let message = Self.message(count, code)
        return PermissionPanel.Notice(image: TablerIcon.coinsImage(size: PermissionPanel.iconSize), accent: Self.accent, text: { theme, font in
            let text = NSMutableAttributedString(string: message, attributes: [.font: font, .foregroundColor: theme.text])
            let range = (message as NSString).range(of: " \(code) ")
            if range.location != NSNotFound {
                text.addAttribute(.foregroundColor, value: Self.accent(theme), range: NSRange(location: range.location+1, length: range.length-2))
            }
            return text
        }, message: message)
    }

    /// Rewrites `tab`'s prices into `code`, or puts them back.
    func set(_ on: Bool, in tab: BrowserTab, to code: String, rates: ExchangeRates) {
        guard let page = tab.page as? ChromiumPage else { return }
        if !on { revert(tab); return }
        page.evaluate(CurrencyAmounts.applyBody, arguments: ["options": CurrencyAmounts.replaceOptions(to: code, rates: rates)],
                      in: nil, world: Self.world) { [weak self, weak tab] result in
            guard let self, let tab, case .success(let value) = result else { return }
            replaced((value as? NSNumber)?.intValue ?? 0, with: code, in: tab)
        }
    }

    /// Replaced on `tab`'s page: its icon grows into its bar, then the panel comes down out of it.
    func replaced(_ count: Int, with code: String, in tab: BrowserTab) {
        guard let browser else { return }
        tab.replacedCurrency = (code, count)
        seen[ObjectIdentifier(tab)] = (tab.page.url, tab.isLoading)
        if leavingTab === tab { leavingTab = nil; leavingCode = nil }
        undoTab = tab; undoUntil = Date().addingTimeInterval(Self.undoWindow)
        browser.update()
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DispatchQueue.main.asyncAfter(deadline: .now()+(still ? 0 : PlainNavBar.PermissionMotion.promptDelay)) { [weak self, weak tab] in
            guard let self, let tab, tab.replacedCurrency != nil else { return }
            show(for: tab, putAwayAfter: Self.shownFor)
        }
    }

    /// The icon puts its panel away, and brings it back.
    func toggle(from bar: PlainNavBar) {
        guard let tab = browser?.pageBarTabs.first(where: { $0.bar === bar })?.tab, tab.replacedCurrency != nil else { return }
        if panel.isPresented, self.tab === tab { putAway?.cancel(); holdsUntilExit = false; panel.hide() } else { show(for: tab, putAwayAfter: nil) }
    }

    private func show(for tab: BrowserTab, putAwayAfter seconds: TimeInterval?) {
        guard let replaced = tab.replacedCurrency, let browser,
              browser.pageBarTabs.contains(where: { $0.tab === tab }) else { return }
        putAway?.cancel(); putAway = nil; holdsUntilExit = false
        if panel.isPresented, self.tab !== tab { panel.hide() }
        self.tab = tab
        panel.tell(notice(replaced.count, replaced.code))
        // Placed before it comes down: until then it's hidden, which `layoutPanel` leaves be.
        PermissionCoordinator.place(panel, over: tab.page.view, in: browser)
        panel.present()
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, panel.isPresented else { return }
            // Read while it's being read: it goes once the pointer leaves it.
            if panel.isPointerInside { holdsUntilExit = true } else { panel.hide() }
        }
        putAway = work
        DispatchQueue.main.asyncAfter(deadline: .now()+seconds, execute: work)
    }

    /// Puts the page's own prices back: the panel goes up into the icon, which then goes.
    func revert(_ tab: BrowserTab? = nil) {
        guard let tab = tab ?? self.tab, let code = tab.replacedCurrency?.code else { return }
        (tab.page as? ChromiumPage)?.evaluate(CurrencyAmounts.restoreBody, arguments: [:], in: nil, world: Self.world) { _ in }
        cleared(tab, code: code)
    }

    /// `tab`'s page has its own prices again.
    private func cleared(_ tab: BrowserTab, code: String) {
        tab.replacedCurrency = nil
        if undoTab === tab { undoTab = nil }
        putAway?.cancel(); putAway = nil; holdsUntilExit = false
        if self.tab === tab, panel.isPresented || panel.isLeaving {
            leavingTab = tab; leavingCode = code
            panel.hide()
        }
        browser?.update()
    }
    private func panelGone() {
        guard leavingTab != nil else { return }
        leavingTab = nil; leavingCode = nil
        browser?.update()
    }

    /// The code `tab`'s bar shows the icon for: its replacement, or one going.
    func shownCode(for tab: BrowserTab?) -> String? {
        guard let tab else { return nil }
        return tab.replacedCurrency?.code ?? (leavingTab === tab ? leavingCode : nil)
    }

    /// A page that has gone somewhere else has its own prices: asked, as one changing its address
    /// in place keeps the replacement.
    func pageChanged(_ tab: BrowserTab) {
        // Asked once its address changes or a load finishes, not on every step of one.
        let key = ObjectIdentifier(tab), now = (url: tab.page.url, loading: tab.isLoading), before = seen[key]
        guard let code = tab.replacedCurrency?.code, let page = tab.page as? ChromiumPage else { seen[key] = nil; return }
        seen[key] = now
        guard let before, before.url != now.url || before.loading && !now.loading else { return }
        page.evaluate(CurrencyAmounts.isReplacedBody, arguments: [:], in: nil, world: Self.world, userGesture: false) { [weak self, weak tab] result in
            guard let self, let tab, tab.replacedCurrency?.code == code, (try? result.get()) as? Bool != true else { return }
            cleared(tab, code: code)
        }
    }

    /// Over its tab's page, under its bar; away once that page isn't shown.
    func layoutPanel() {
        guard let browser, !panel.isHidden || panel.isPresented else { return }
        guard let tab, browser.pageBarTabs.contains(where: { $0.tab === tab }) else {
            if panel.isPresented { putAway?.cancel(); panel.hide() }
            return
        }
        PermissionCoordinator.place(panel, over: tab.page.view, in: browser)
    }

    /// ⌘Z, for a little while after replacing, puts the prices back.
    func handleUndoKey(_ event: NSEvent) -> Bool {
        guard let browser, event.type == .keyDown, browser.palette.isHidden, !(browser.window?.firstResponder is NSTextView),
              browser.keyboardShortcuts.matches("undo:", event), Date() < undoUntil,
              let tab = undoTab, tab.replacedCurrency != nil, browser.pageBarTabs.contains(where: { $0.tab === tab }) else { return false }
        revert(tab)
        return true
    }
}
