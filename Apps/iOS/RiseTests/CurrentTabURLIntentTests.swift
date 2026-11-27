import AppIntents
import UIKit
import XCTest
@testable import RiseiOS

final class CurrentTabURLIntentTests: XCTestCase {
    @MainActor func testReturnsFullPageAddressAndClearsItForABlankTab() async throws {
        let fixture = try AdBlockHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }

        let url = try XCTUnwrap(URL(string: "/search?q=gta%20v#results", relativeTo: fixture.url)?.absoluteURL)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = BrowserViewController(startURL: url, websiteDataStore: .nonPersistent())
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }

        let intent = GetCurrentTabURLIntent()
        let currentPage = try await intent.perform()
        XCTAssertEqual((currentPage.value ?? nil)?.absoluteString, url.absoluteString)

        window.rootViewController = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent())
        let blankPage = try await intent.perform()
        XCTAssertNil(blankPage.value ?? nil)
    }
}
