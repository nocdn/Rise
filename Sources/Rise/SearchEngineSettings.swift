import AppKit
import RiseCore
import RiseChromium

@MainActor extension BrowserController {
    static let searchEnginePreferenceKey = "Rise.SearchEngine"

    var searchProvider: SearchProvider {
        if ChromiumEngine.isRunning, let name = RCEngine.defaultSearchName() {
            let google = RCEngine.searchURL(forTerms: "rise").flatMap(\.host).map { $0 == "www.google.com" || $0 == "google.com" } ?? false
            return SearchProvider(title: name, searchURL: { RCEngine.searchURL(forTerms: $0) }, isGoogle: google)
        }
        return SearchProvider(searchEngine)
    }
    /// Rise's own choice, for when Chromium isn't running, as in unit tests.
    var searchEngine: SearchEngine {
        SearchEngine(rawValue: preferences.string(forKey: Self.searchEnginePreferenceKey) ?? "") ?? .google
    }

    func selectSearchEngine(_ engine: SearchEngine) {
        preferences.set(engine.rawValue, forKey: Self.searchEnginePreferenceKey)
        googleSearchSuggestions.cancel()
        if palette.isPresented {
            let query = palette.query
            palette.removeInlineCompletion(); palette.refresh(query: query)
        }
    }

    func makeSearchEngineMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Search Engine", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Search Engine")
        for engine in SearchEngine.allCases {
            submenu.addItem(menuItem(engine.title, checked: searchEngine == engine) { [weak self] in
                self?.selectSearchEngine(engine)
            })
        }
        item.submenu = submenu
        return item
    }
}
