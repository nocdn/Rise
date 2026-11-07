import AppKit

/// Reloading a page again and again may mean ad blocking has broken it, so Rise offers to leave its
/// site alone, in the panel sites' permissions ask in. It asks once per site each time Rise runs.
@MainActor final class AdBlockPrompt {
    static let reloads = 3, within: TimeInterval = 20
    static let message = "Disable ad-blocking on this site?"
    /// The site controls' slashed shield, as heavy and as large as the panel's and the bar's icons.
    static let icon = AdBlockButton.slashedShield(canvas: 16, pointSize: 14, weight: .medium, stroke: 1.33, description: "Ad-blocking")
    /// A little smaller in the page bar, in the same box, so the words stay where they'd be.
    static let noticeIcon = AdBlockButton.slashedShield(canvas: 16, pointSize: 12, weight: .medium, stroke: 1.15, description: "Ad-blocking")
    static let noticeNudge: CGFloat = 3
    weak var browser: BrowserController?
    let panel = PermissionPanel()
    private var streak: (tab: UUID, site: String, times: [Date])?
    private var declined: Set<String> = []
    /// The page asked over, and its site.
    private weak var page: WebPage?
    private var site: String?
    /// Changes to uBlock Origin's list, one at a time.
    private var writing: Task<Void, Never>?
    init(browser: BrowserController) {
        self.browser = browser
        panel.applyTheme(browser.theme)
        panel.setShortcuts(allow: KeyboardShortcut("Command+Alt+Enter")?.display ?? "", deny: KeyboardShortcut("Command+Alt+Backspace")?.display ?? "",
                           allowHint: "Disable ad-blocking", denyHint: "Keep blocking")
        panel.answer = { [weak self] in self?.answer($0) }
    }
    /// A reload the person asked for, of the selected tab.
    func noteReload(at now: Date = Date()) {
        guard let browser, let tab = browser.selectedTab, !tab.developer, browser.adBlocker.enabled,
              let site = AdBlocker.site(of: tab.page.url), browser.adBlocker.allowedSite(for: tab.page.url) == nil,
              !declined.contains(site), !panel.isPresented, !browser.permissionCoordinator.isShowingPrompt else { return }
        var times = streak.flatMap { $0.tab == tab.id && $0.site == site ? $0.times : nil } ?? []
        times = times.filter { now.timeIntervalSince($0) < Self.within } + [now]
        guard times.count >= Self.reloads else { streak = (tab.id, site, times); return }
        streak = nil
        page = tab.page; self.site = site
        panel.offer(PermissionPanel.Notice(
            image: Self.icon,
            accent: { SiteCapability.notifications.accent($0) },
            text: { theme, font in Self.text(theme: theme, font: font) }, message: Self.message))
        PermissionCoordinator.place(panel, over: tab.page.view, in: browser)
        panel.present()
    }
    static func text(theme: RiseTheme, font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString(string: message, attributes: [.font: font, .foregroundColor: theme.text])
        text.addAttribute(.foregroundColor, value: SiteCapability.notifications.accent(theme), range: (message as NSString).range(of: "ad-blocking"))
        return text
    }
    func answer(_ allowed: Bool) {
        guard panel.isPresented, let site else { return }
        panel.hide(); self.site = nil
        if allowed { setAllowed(true, site: site) } else { declined.insert(site) }
    }
    /// Leaves a site unblocked or blocks it again, and reloads its pages, once uBlock Origin has its list.
    func setAllowed(_ allowed: Bool, site: String) {
        browser?.adBlocker.setAllowed(allowed, site: site)
        let earlier = writing
        writing = Task { [weak self] in
            await earlier?.value
            guard let self else { return }
            do {
                try await self.write(allowed, site: site)
                self.announce(blocking: !allowed, site: site)
                self.reloadPages(of: site)
            } catch {
                self.browser?.adBlocker.setAllowed(!allowed, site: site)
                self.browser?.showMessage("Couldn’t change ad blocking on this site", error.localizedDescription)
                self.browser?.update()
            }
        }
    }
    /// Says so in the page bar, if that's still the site showing.
    func announce(blocking: Bool, site: String) {
        guard let browser, let shown = AdBlocker.site(of: browser.selectedTab?.url), shown == site || shown.hasSuffix("."+site) else { return }
        let state = blocking ? "enabled" : "disabled"
        browser.selectedBar.showNotice("Ad-blocking \(state) on this site", image: Self.noticeIcon, nudge: Self.noticeNudge, dotted: state)
    }
    /// A page of uBlock Origin's own, offscreen for as long as this takes.
    private func write(_ allowed: Bool, site: String) async throws {
        guard ChromiumEngine.isRunning, let browser else { return }
        _ = try? await browser.adBlocker.change?.value
        guard browser.adBlocker.enabled else { return }
        let web = BrowserTab.makePage()
        let container = HiddenAccessibilityView(frame: NSRect(x: -20000, y: 0, width: 800, height: 600))
        web.view.frame = container.bounds; container.addSubview(web.view)
        browser.root.addSubview(container, positioned: .below, relativeTo: browser.root.subviews.first)
        defer { AdBlockHiddenPage.close(web) }
        web.load(AdBlocker.allowlistPage)
        // Asked sooner, the blank document it starts on would answer, and go.
        let deadline = Date().addingTimeInterval(10)
        while web.url != AdBlocker.allowlistPage || web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        _ = try await web.evaluate(AdBlocker.allowlistScript, arguments: ["site": site, "allowed": allowed], in: nil, world: .page)
    }
    private func reloadPages(of site: String) {
        guard let browser else { return }
        // Asked for in the site controls, they stay open through the reload.
        if browser.siteControlsPopover.isShown, let tab = browser.selectedTab, let url = tab.page.url {
            browser.siteControlsReload = (tab.id, url, Date().addingTimeInterval(5))
        }
        let visible = Set(browser.visibleTabIDs)
        for tab in browser.tabs where AdBlocker.site(of: tab.page.url).map({ $0 == site || $0.hasSuffix("."+site) }) == true {
            if visible.contains(tab.id) { tab.needsBlockingReload = false; tab.page.reloadIgnoringCache() }
            else { tab.needsBlockingReload = true }
        }
        browser.update()
    }
    /// A page going to another site takes the question with it, unanswered.
    func pageChanged(_ tab: BrowserTab) {
        if tab.page === page, panel.isPresented, AdBlocker.site(of: tab.page.url) != site { panel.hide() }
        if tab.id == streak?.tab, AdBlocker.site(of: tab.page.url) != streak?.site { streak = nil }
    }
    func layoutPanel() {
        guard let browser, let page, !panel.isHidden else { return }
        guard browser.findTab?.page === page else { panel.hide(); return }
        PermissionCoordinator.place(panel, over: page.view, in: browser)
    }
    func applyTheme(_ theme: RiseTheme) { panel.applyTheme(theme) }
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, panel.isPresented, let browser else { return false }
        if browser.keyboardShortcuts.matches("allowPermission", event) { answer(true); return true }
        if browser.keyboardShortcuts.matches("denyPermission", event) { answer(false); return true }
        return false
    }
}

private enum AdBlockHiddenPage {
    @MainActor static func close(_ page: WebPage) {
        page.view.superview?.removeFromSuperview()
        (page as? ChromiumPage)?.browserView.close()
    }
}
