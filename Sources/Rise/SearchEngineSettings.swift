import AppKit
import RiseCore
#if RISE_CHROMIUM
import RiseChromium
#endif

/// The search engine the address bar searches with: on Chromium, the default chosen in Chrome's
/// Search engine section of rise://settings; on WebKit, Rise's own choice.
struct SearchProvider {
    let title: String
    let searchURL: (String) -> URL?
    /// Google, which offers suggestions as you type.
    let isGoogle: Bool
}

@MainActor extension BrowserController {
    static let searchEnginePreferenceKey = "Rise.SearchEngine"

    var searchProvider: SearchProvider {
        #if RISE_CHROMIUM
        if ChromiumEngine.isRunning, let name = RCEngine.defaultSearchName() {
            let google = RCEngine.searchURL(forTerms: "rise").flatMap(\.host).map { $0 == "www.google.com" || $0 == "google.com" } ?? false
            return SearchProvider(title: name, searchURL: { RCEngine.searchURL(forTerms: $0) }, isGoogle: google)
        }
        #endif
        let engine = searchEngine
        return SearchProvider(title: engine.title, searchURL: { engine.searchURL(for: $0) }, isGoogle: engine == .google)
    }
    /// Rise's own choice, for WebKit.
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
