import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class PopupBlockingTests: XCTestCase {
    @MainActor func testPolicyPersistsPerSiteWithoutChangingOtherProtections() throws {
        let name = "Rise.Popup.Tests."+UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let filter = MobileAdBlocker(preferences: defaults)
        let url = URL(string: "https://www.example.com/path")!
        XCTAssertTrue(filter.popups.isEnabled(for: url))
        filter.popups.setEnabled(false, for: url)
        XCTAssertFalse(MobilePopupBlocker(preferences: defaults).isEnabled(for: URL(string: "https://example.com./other")))
        XCTAssertTrue(filter.popups.isEnabled(for: URL(string: "https://sub.example.com/")))
        XCTAssertTrue(filter.isEnabled(for: url))
        XCTAssertTrue(filter.cookieBanners.isEnabled(for: url))
        XCTAssertTrue(filter.popups.isEnabled(for: URL(string: "https://youtube.com/")))
        for invalid in [nil, URL(string: "about:blank"), URL(string: "file:///example.com/a"), URL(string: "ftp://example.com/")] {
            XCTAssertFalse(filter.popups.isEnabled(for: invalid))
        }
    }

    @MainActor func testPrivatePreferencesAreEphemeralAndIndependent() {
        let first = MobilePopupBlocker(preferences: nil), second = MobilePopupBlocker(preferences: nil)
        let url = URL(string: "https://example.com")!
        first.setEnabled(false, for: url)
        XCTAssertFalse(first.isEnabled(for: url))
        XCTAssertTrue(second.isEnabled(for: url))
        first.setEnabled(true, for: url)
        XCTAssertTrue(first.isEnabled(for: url))
    }

    func testAllBundledRulesCompileAndKnownAdsRespectExceptions() throws {
        struct Catalog: Decodable { let rules: [PopupDestinationRules.Rule] }
        let data = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "popup-rules", withExtension: "json")))
        let count = try JSONDecoder().decode(Catalog.self, from: data).rules.count
        let rules = try PopupDestinationRules(data: data)
        XCTAssertEqual(rules.count, count, "No bundled regex may silently disappear")
        XCTAssertGreaterThan(count, 3000)
        let source = URL(string: "https://example.com")!
        for value in ["https://profitableratecpmnetwork.com/ad", "https://sub.profitableratecpmnetwork.com:443/ad"] {
            XCTAssertTrue(rules.blocks(URL(string: value)!, from: source))
        }
        for value in ["https://notprofitableratecpmnetwork.com/", "https://profitableratecpmnetwork.com.evil.test/", "https://example.com/#https://profitableratecpmnetwork.com/", "https://profitableratecpmnetwork.com@example.com/", "https://accounts.google.com/o/oauth2/auth", "https://github.com/login/oauth/authorize"] {
            XCTAssertFalse(rules.blocks(URL(string: value)!, from: source), value)
        }
    }

    func testDomainScopePartyAndExceptionPrecedence() {
        func rule(_ pattern: String, exception: Bool = false, include: [String] = [], exclude: [String] = [], party: Int = 0, important: Bool = false) -> PopupDestinationRules.Rule {
            .init(pattern: pattern, exception: exception, include: include, exclude: exclude, party: party, matchCase: false, important: important)
        }
        let rules = PopupDestinationRules(rules: [
            rule("/ad", include: ["example.com"], exclude: ["safe.example.com"], party: 1),
            rule("/ad/good", exception: true), rule("/ad/critical", important: true),
            rule("/ad/critical", exception: true)])
        let destination = URL(string: "https://elsewhere.test/ad")!
        XCTAssertTrue(rules.blocks(destination, from: URL(string: "https://www.example.com")))
        XCTAssertFalse(rules.blocks(destination, from: URL(string: "https://safe.example.com")))
        XCTAssertFalse(rules.blocks(destination, from: URL(string: "https://notexample.com")))
        XCTAssertFalse(rules.blocks(URL(string: "https://cdn.example.com/ad")!, from: URL(string: "https://app.example.com")))
        XCTAssertFalse(rules.blocks(URL(string: "https://elsewhere.test/ad/good")!, from: URL(string: "https://example.com")))
        XCTAssertTrue(rules.blocks(URL(string: "https://elsewhere.test/ad/critical")!, from: URL(string: "https://example.com")))
    }

    @MainActor func testSettingUpdatesLiveSiblingPagesButNotPrivatePolicy() {
        let policy = MobilePopupBlocker(preferences: nil), other = MobilePopupBlocker(preferences: nil)
        let first = WKWebView(), sibling = WKWebView(), unrelated = WKWebView()
        let url = URL(string: "https://example.com")!
        policy.prepare(first, for: url); policy.prepare(sibling, for: url); other.prepare(unrelated, for: url)
        policy.setEnabled(false, for: url)
        XCTAssertTrue(first.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(sibling.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(unrelated.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        policy.setEnabled(true, for: url)
        XCTAssertFalse(first.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        for _ in 0..<4 { policy.prepare(first, for: url) }
        XCTAssertEqual(first.configuration.userContentController.userScripts.filter { $0.source.hasPrefix(PopupIntentScript.marker) }.count, 1)
    }

    @MainActor func testBlankPopupInheritsProtectionForItsRedirectChain() {
        let policy = MobilePopupBlocker(preferences: nil), page = WKWebView()
        let source = URL(string: "https://example.com")!, blank = URL(string: "about:blank")!
        policy.prepare(page, for: blank); policy.protectPopup(page, openedFrom: source)
        policy.prepare(page, for: blank)
        XCTAssertFalse(page.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        let ad = URL(string: "https://profitableratecpmnetwork.com/")!
        XCTAssertTrue(policy.blocksPopupNavigation(to: ad, in: page))
        policy.didCommit(page)
        XCTAssertTrue(policy.blocksPopupNavigation(to: ad, in: page), "A blank or intermediate document must not drop redirect protection")
        policy.setEnabled(false, for: source)
        XCTAssertFalse(policy.blocksPopupNavigation(to: ad, in: page))
    }

    @MainActor func testRestoredRowsUseSuppliedIconAndOriginalColours() throws {
        let panel = SiteSettingsPanel(frame: CGRect(x: 0, y: 0, width: 402, height: SiteSettingsPanel.height))
        panel.layoutIfNeeded()
        XCTAssertEqual(panel.switches.map(\.accessibilityLabel), ["Block ads", "Block popups", "Block cookie banners", "Bypass paywall"])
        let rows = panel.buttons.compactMap { $0 as? SettingsToggleRow }
        let symbols = rows.compactMap { $0.subviews.compactMap { $0 as? UIImageView }.first }
        XCTAssertEqual(symbols.map(\.tintColor), [.systemRed, .systemOrange, .systemGreen, .systemBlue])
        XCTAssertNotNil(MenuIcons.blockPopups)
        rows.forEach { $0.layoutIfNeeded() }
        XCTAssertEqual(symbols[1].bounds.size, symbols[2].bounds.size)
        XCTAssertEqual(symbols[1].image, MenuIcons.blockPopups)
    }
}
