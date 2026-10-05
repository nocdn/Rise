import XCTest
import AppKit
import RiseCore
@testable import Rise

final class SearchEngineTests: XCTestCase {
    @MainActor func testNativeSubmenuDefaultsToGoogleAndSelectionPersists() throws {
        _ = NSApplication.shared
        let suite = "Rise.SearchEngineTests.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: file, restore: false, preferences: preferences)
        defer { clean(browser); preferences.removePersistentDomain(forName: suite) }
        let menu = try XCTUnwrap(browser.makeMoreSiteMenu().items.first { $0.title == "Search Engine" }?.submenu)
        XCTAssertEqual(menu.items.map(\.title), ["Google", "Kagi"])
        XCTAssertEqual(menu.items.map(\.state), [.on, .off])
        let action = try XCTUnwrap(menu.items[1].target as? MenuAction)
        action.invoke()
        XCTAssertEqual(browser.searchEngine, .kagi)
        XCTAssertEqual(browser.makeSearchEngineMenu().submenu?.items.map(\.state), [.off, .on])
        let restored = BrowserController(sessionURL: file, restore: false, preferences: preferences)
        defer { clean(restored) }
        XCTAssertEqual(restored.searchEngine, .kagi)
        restored.selectSearchEngine(.google)
        XCTAssertEqual(browser.searchEngine, .google)
        preferences.set("unsupported", forKey: BrowserController.searchEnginePreferenceKey)
        XCTAssertEqual(browser.searchEngine, .google)
    }
    @MainActor func testAddressSuggestionsAndBothAddressInputsUseTheChosenEngine() throws {
        _ = NSApplication.shared
        let suite = "Rise.SearchRoutingTests.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: file, restore: false, preferences: preferences)
        defer { clean(browser); preferences.removePersistentDomain(forName: suite) }
        browser.selectSearchEngine(.kagi)
        let suggestion = try XCTUnwrap(browser.suggestions(for: "cats & dogs").first)
        XCTAssertEqual(suggestion.title, "Search Kagi for “cats & dogs”")
        XCTAssertEqual(suggestion.url, SearchEngine.kagi.searchURL(for: "cats & dogs"))
        XCTAssertEqual(browser.suggestions(for: "https://www.google.com/search?q=literal").first?.url?.host, "www.google.com")
        browser.paletteCreatesTab = true
        browser.submitAddress("cats & dogs", suggestion: nil)
        XCTAssertEqual(browser.selectedTab?.url, suggestion.url)
        browser.navigateDeveloperAddress("another query")
        XCTAssertEqual(browser.selectedTab?.url, SearchEngine.kagi.searchURL(for: "another query"))
        browser.selectSearchEngine(.google)
        XCTAssertEqual(browser.suggestions(for: "cats & dogs").first?.title, "Search Google for “cats & dogs”")
        XCTAssertEqual(browser.suggestions(for: "cats & dogs").first?.url?.host, "www.google.com")
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.hidePalette(); browser.googleSearchSuggestions.cancel(); browser.suggestionFavicons.cancel(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad(); $0.iconTask?.cancel() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
}
