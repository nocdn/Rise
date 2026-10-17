import XCTest
@testable import Rise

// Preloading itself is checked on Chromium: Tests/Live/ChromiumFeatureChecks.swift.
final class LinkPreloadingTests: XCTestCase {
    func testEligibilityRejectsSpecialSchemesAndSameDocumentLinks() {
        let source = URL(string: "https://example.com/page")!
        for value in ["https://example.com/page#part", "mailto:test@example.com", "file:///tmp/page", "javascript:alert(1)", "https://user:secret@example.com/other"] {
            XCTAssertFalse(LinkPreloader.isEligible(URL(string: value)!, from: source))
        }
        XCTAssertTrue(LinkPreloader.isEligible(URL(string: "https://other.example/page")!, from: source))
    }
    func testTheSmartFilterLeavesOutLinksThatActRatherThanShowAPage() {
        let actions = [
            "https://news.ycombinator.com/logout?auth=abc&goto=news",
            "https://news.ycombinator.com/vote?id=1&how=up&auth=abc&goto=news",
            "https://news.ycombinator.com/hide?id=1&auth=abc",
            "https://mail.google.com/mail/u/0/?logout&hl=en",
            "https://accounts.google.com/Logout",
            "https://www.amazon.co.uk/gp/flex/sign-out.html",
            "https://en.wikipedia.org/wiki/Special:UserLogout",
            "https://example.com/account/signOut",
            "https://example.com/users/sign_out",
            "https://example.com/wyloguj",
            "https://example.com/posts/5/delete",
            "https://example.com/cart/add_to_cart?id=5",
            "https://example.com/notifications/mark-all-as-read",
            "https://example.com/newsletter/unsubscribe?email=a%40b.c",
            "https://example.com/wp-admin/post.php?post=5&action=trash&_wpnonce=abc",
            "https://example.com/items/5?_method=delete",
            "https://example.com/confirm-email?token=abc",
            "https://example.com/password/reset/abc",
            "https://example.com/auth/github/callback?code=abc&state=xyz",
            "https://github.com/login/oauth/authorize?client_id=abc",
            "https://example.com/invitations/5/accept",
            "https://example.com/files/report.pdf",
            "https://example.com/downloads/Rise.dmg",
        ]
        for value in actions {
            XCTAssertTrue(LinkPreloader.looksLikeAnAction(URL(string: value)!), value)
            XCTAssertFalse(LinkPreloader.isEligible(URL(string: value)!, from: nil), value)
        }
        let pages = [
            "https://news.ycombinator.com/item?id=1",
            "https://en.wikipedia.org/wiki/Star_Wars",
            "https://www.bbc.co.uk/news/world-report-2024",
            "https://github.com/imputnet/helium/pulls",
            "https://www.amazon.co.uk/dp/B000",
            "https://www.youtube.com/watch?v=abc",
            "https://example.com/blog/how-we-built-it",
            "https://example.com/favorites",
            "https://example.com/search?q=rust",
            "https://etherscan.io/block/123",
        ]
        for value in pages { XCTAssertFalse(LinkPreloader.looksLikeAnAction(URL(string: value)!), value) }
        XCTAssertEqual(LinkPreloader.words("signOut-NOW_ok"), ["sign", "out", "now", "ok"])
    }
}
