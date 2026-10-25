#if DEBUG
import UIKit
import WebKit

@MainActor enum PopupBlockingChecks {
    private struct Failed: Error { let message: String }
    static func run(in browser: BrowserViewController) throws -> [String] {
        var checks: [String] = []
        func check(_ passed: Bool, _ name: String) throws {
            guard passed else { throw Failed(message: name) }
            checks.append(name)
        }
        struct Catalog: Decodable { let rules: [PopupDestinationRules.Rule] }
        let data = try Data(contentsOf: Bundle.main.url(forResource: "popup-rules", withExtension: "json")!)
        let count = try JSONDecoder().decode(Catalog.self, from: data).rules.count
        let rules = try PopupDestinationRules(data: data)
        try check(rules.count == count && count > 3000, "Every bundled popup regex compiles in the actual iOS matcher")
        let source = URL(string: "https://example.com/")!
        let ad = URL(string: "https://profitableratecpmnetwork.com/ad")!
        try check(rules.blocks(ad, from: source), "Known ad destination is blocked")
        for value in ["https://notprofitableratecpmnetwork.com/", "https://profitableratecpmnetwork.com.evil.test/", "https://example.com/#https://profitableratecpmnetwork.com/", "https://profitableratecpmnetwork.com@example.com/", "https://accounts.google.com/o/oauth2/auth", "https://github.com/login/oauth/authorize"] {
            try check(!rules.blocks(URL(string: value)!, from: source), "No false positive: "+value)
        }
        try check(!rules.blocks(URL(string: "https://legitimate.test/")!, from: URL(string: "https://kat.com.evil.test/")), "A lookalike source does not inherit an entity-scoped block")
        let video = URL(string: "https://streamtape.com/")!, unlisted = URL(string: "https://unlisted-ad.test/")!
        try check(rules.blocks(unlisted, from: video), "Broad maintained popup rules protect ad-heavy sites against unlisted destinations")
        try check(!rules.blocks(URL(string: "https://accounts.google.com/o/oauth2/auth")!, from: video), "A maintained sign-in exception overrides a broad popup rule")
        try check(!rules.blocks(unlisted, from: URL(string: "https://datanodes.to/")), "A broad popup exception is preserved")
        let name = "Rise.Popup.Audit."+UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = MobilePopupBlocker(preferences: defaults)
        try check(policy.isEnabled(for: source), "Protection is on by default")
        policy.setEnabled(false, for: source)
        try check(!MobilePopupBlocker(preferences: defaults).isEnabled(for: URL(string: "https://www.example.com./path")), "The site override persists and www shares the setting")
        try check(policy.isEnabled(for: URL(string: "https://sub.example.com")), "Other subdomains remain independent")
        let first = MobilePopupBlocker(preferences: nil), second = MobilePopupBlocker(preferences: nil)
        first.setEnabled(false, for: source)
        try check(second.isEnabled(for: source), "Private preferences are isolated and ephemeral")
        for value in [nil, URL(string: "about:blank"), URL(string: "file:///example.com/a"), URL(string: "ftp://example.com/")] {
            try check(!policy.isEnabled(for: value), "Non-web documents have no persistent site preference: \(value?.absoluteString ?? "nil")")
        }
        policy.setEnabled(true, for: source)
        let page = WKWebView(), sibling = WKWebView(), unrelated = WKWebView()
        policy.prepare(page, for: source); policy.prepare(sibling, for: source); second.prepare(unrelated, for: source)
        policy.setEnabled(false, for: source)
        try check(page.configuration.preferences.javaScriptCanOpenWindowsAutomatically && sibling.configuration.preferences.javaScriptCanOpenWindowsAutomatically,
                  "Disabling applies immediately to sibling pages")
        try check(!unrelated.configuration.preferences.javaScriptCanOpenWindowsAutomatically, "A different private policy remains enabled")
        policy.setEnabled(true, for: source)
        for _ in 0..<4 { policy.prepare(page, for: source) }
        try check(!page.configuration.preferences.javaScriptCanOpenWindowsAutomatically && page.configuration.userContentController.userScripts.filter { $0.source.hasPrefix(PopupIntentScript.marker) }.count == 1,
                  "Re-enabling is immediate and preparation never duplicates the script")
        let blank = WKWebView()
        policy.prepare(blank, for: URL(string: "about:blank")); policy.protectPopup(blank, openedFrom: source)
        policy.prepare(blank, for: URL(string: "about:blank")); policy.didCommit(blank)
        try check(!blank.configuration.preferences.javaScriptCanOpenWindowsAutomatically && policy.blocksPopupNavigation(to: ad, in: blank), "Blank and intermediate documents retain opener protection")
        let panel = browser.bottomBar.siteSettings
        browser.updateAdBlockingSettings()
        let url = browser.webView.url!
        let before = browser.webView.backForwardList.currentItem
        for enabled in [false, true] {
            panel.switches[1].setOn(enabled, animated: false); panel.switches[1].sendActions(for: .valueChanged)
            try check(browser.adBlocker.popups.isEnabled(for: url) == enabled && browser.webView.backForwardList.currentItem === before,
                      "The real popup row changes policy without reloading: \(enabled)")
            try check(!browser.adBlocker.isEnabled(for: url) && !browser.adBlocker.cookieBanners.isEnabled(for: url), "Ads and cookie preferences remain independent: \(enabled)")
        }
        try check(panel.switches.map(\.accessibilityLabel) == ["Block ads", "Block popups", "Block cookie banners", "Bypass paywall"], "Restored settings order and accessibility labels")
        let rows = panel.buttons.compactMap { $0 as? SettingsToggleRow }
        let icons = rows.compactMap { $0.subviews.compactMap { $0 as? UIImageView }.first }
        try check(icons.map(\.tintColor) == [.systemRed, .systemOrange, .systemGreen, .systemBlue] && MenuIcons.blockPopups != nil, "Original colours and the supplied popup icon")
        return checks
    }
}
#endif
