import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class OpenHereTests: XCTestCase {
    @MainActor private func titles(_ elements: [UIMenuElement]) -> [String] {
        elements.flatMap { element -> [String] in
            if let menu = element as? UIMenu, menu.options.contains(.displayInline) || menu.title.isEmpty { return titles(menu.children) }
            return [(element as? UIAction)?.title ?? (element as? UIMenu)?.title ?? "?"]
        }
    }
    @MainActor private func suggested() -> [UIMenuElement] {
        [UIAction(title: "Open", image: UIImage(systemName: "safari"), identifier: BrowserViewController.openLinkIdentifier) { _ in },
         UIAction(title: "Add to Reading List", image: UIImage(systemName: "eyeglasses")) { _ in },
         UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in },
         UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in }]
    }

    @MainActor func testOpenHereSitsRightUnderOpenWithItsIconOnlyForWebLinks() throws {
        let browser = BrowserViewController(startURL: nil)
        browser.loadViewIfNeeded()
        let page = browser.webView
        let menu = browser.nativeLinkMenu(in: page, url: URL(string: "https://example.com/article")!, actions: suggested())
        XCTAssertEqual(titles(menu.children), ["Open", "Open Here", "Add to Reading List", "Copy Link", "Share…"])
        let open = try XCTUnwrap(menu.children[0] as? UIAction), here = try XCTUnwrap(menu.children[1] as? UIAction)
        XCTAssertEqual(here.identifier, BrowserViewController.openHereIdentifier)
        XCTAssertEqual(here.image, open.image, "The same icon as Open")

        // Inside a section of WebKit's, it stays beside Open there.
        let sectioned = browser.nativeLinkMenu(in: page, url: URL(string: "https://example.com/article")!,
                                               actions: [UIMenu(options: .displayInline, children: suggested())])
        let section = try XCTUnwrap(sectioned.children.first as? UIMenu)
        XCTAssertEqual(section.children.compactMap { ($0 as? UIAction)?.title }.prefix(2), ["Open", "Open Here"])

        for other in ["mailto:hello@example.com", "tel:+441234567890", "javascript:void(0)"] {
            let menu = browser.nativeLinkMenu(in: page, url: URL(string: other)!, actions: suggested())
            XCTAssertFalse(titles(menu.children).contains("Open Here"), other)
        }
        // Should WebKit's identifier change, its Open is still found by its title.
        var renamed = suggested()
        renamed[0] = UIAction(title: "Open", image: UIImage(systemName: "safari")) { _ in }
        XCTAssertEqual(titles(browser.nativeLinkMenu(in: page, url: URL(string: "https://example.com/")!, actions: renamed).children).prefix(2), ["Open", "Open Here"])
        let withoutOpen = browser.nativeLinkMenu(in: page, url: URL(string: "https://example.com/")!, actions: Array(suggested().dropFirst()))
        XCTAssertEqual(titles(withoutOpen.children), ["Add to Reading List", "Copy Link", "Share…"])
    }

    func testTheReferrerIsTheWebsDefault() {
        let page = URL(string: "https://github.com/mattt/iMCP?tab=readme#about")!
        XCTAssertEqual(BrowserViewController.referrer(from: page, to: URL(string: "https://github.com/mattt")!), "https://github.com/mattt/iMCP?tab=readme")
        XCTAssertEqual(BrowserViewController.referrer(from: page, to: URL(string: "https://imcp.app/download")!), "https://github.com/")
        XCTAssertNil(BrowserViewController.referrer(from: page, to: URL(string: "http://imcp.app/download")!), "Not from HTTPS to HTTP")
        XCTAssertEqual(BrowserViewController.referrer(from: URL(string: "http://127.0.0.1:8080/a")!, to: URL(string: "http://127.0.0.1:9090/b")!), "http://127.0.0.1:8080/")
        XCTAssertNil(BrowserViewController.referrer(from: URL(string: "about:blank"), to: page))
        XCTAssertNil(BrowserViewController.referrer(from: nil, to: page))
    }
}
