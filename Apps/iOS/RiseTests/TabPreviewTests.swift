import XCTest
import UIKit
@testable import RiseiOS

final class TabPreviewTests: XCTestCase {
    @MainActor private func wait(_ check: () -> Bool) async throws {
        for _ in 0..<200 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The background previews did not arrive")
        throw NSError(domain: "RisePreviewTest", code: 1)
    }

    @MainActor func testBackgroundCardsAndFaviconsPopulateWhileTheGridIsOpenAndRestoreFromCache() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let folder = URL.temporaryDirectory.appendingPathComponent("RisePreviewTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("session.json"))
        let blank = MobileBrowserSession.Tab(url: nil)
        let red = MobileBrowserSession.Tab(url: fixture.url.appendingPathComponent("preview/red"), title: "Red article")
        let blue = MobileBrowserSession.Tab(url: fixture.url.appendingPathComponent("preview/blue"), title: "Blue article")
        let session = MobileBrowserSession(tabs: [blank, red, blue], selectedTabID: blank.id)
        store.save(session); store.flush()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let cacheURL = folder.appendingPathComponent("previews")
        let browser = BrowserViewController(sessionStore: store, previewCacheURL: cacheURL)
        window.rootViewController = browser; window.makeKeyAndVisible(); browser.view.layoutIfNeeded()
        browser.showTabSwitcher()
        try await wait { browser.tabs.dropFirst().allSatisfy { $0.snapshot != nil && $0.favicon != nil } }
        XCTAssertEqual(fixture.pageRequests, 2, "One serial temporary renderer loads each missing preview once")
        XCTAssertEqual(browser.tabIndex, 0)
        XCTAssertTrue(browser.tabs.dropFirst().allSatisfy { $0.webView.url == nil }, "Previewing must preserve lazy tabs and their history")
        XCTAssertEqual(browser.tabs.map(\.sessionTab), session.tabs, "Rendering redirects/titles must not change the shared list")
        for index in 1...2 {
            XCTAssertTrue(browser.tabSwitcher.cells[index].card.image.image === browser.tabs[index].snapshot,
                          "The already visible grid must receive the new picture")
            let cg = try XCTUnwrap(browser.tabs[index].snapshot?.cgImage)
            let color = try XCTUnwrap(PageEdgeColor.dominantColor(of: cg))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            if index == 1 { XCTAssertGreaterThan(r, b+0.3) }
            else { XCTAssertGreaterThan(b, r+0.3) }
            let attachment = XCTAttachment(image: try XCTUnwrap(browser.tabs[index].snapshot))
            attachment.name = "Background tab \(index)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        browser.tabPreviews?.cache.flush()
        browser.saveSession(flush: true)
        XCTAssertEqual(store.load()?.selectedTabID, blank.id)
        browser.setTabPreviewsActive(false)
        window.rootViewController = nil
        let requests = fixture.pageRequests
        let restored = BrowserViewController(sessionStore: store, previewCacheURL: cacheURL)
        XCTAssertEqual(restored.tabIndex, 0)
        window.rootViewController = restored; window.makeKeyAndVisible(); restored.view.layoutIfNeeded()
        try await wait { restored.tabs.dropFirst().allSatisfy { $0.snapshot != nil && $0.favicon != nil } }
        XCTAssertEqual(fixture.pageRequests, requests, "Cached previews should need no page loads after relaunch")
        XCTAssertTrue(restored.tabs.dropFirst().allSatisfy { $0.webView.url == nil })
        XCTAssertEqual(restored.tabs.map(\.id), session.tabs.map(\.id))
        restored.setTabPreviewsActive(false)
    }

    @MainActor func testCacheRejectsChangedAddressesAndRemovesClosedTabs() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("RisePreviewCacheTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = TabPreviewCache(folder: folder), id = UUID(), url = URL(string: "https://example.com/old")!
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { context in
            UIColor.systemRed.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        }
        cache.save(id: id, url: url, picture: picture, favicon: nil)
        let original = await cache.load(id: id, url: url)
        XCTAssertNotNil(original)
        let changed = await cache.load(id: id, url: URL(string: "https://example.com/new")!)
        XCTAssertNil(changed)
        cache.prune(keeping: []); cache.flush()
        let closed = await cache.load(id: id, url: url)
        XCTAssertNil(closed)
    }
}
