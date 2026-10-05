import AppKit
import RiseCore

@MainActor extension BrowserController {
    static let searchEnginePreferenceKey = "Rise.SearchEngine"

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
