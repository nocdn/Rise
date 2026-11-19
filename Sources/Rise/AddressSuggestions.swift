import AppKit
import RiseCore

@MainActor extension BrowserController {
    /// Match the complete destination, including its query and anchor. History
    /// normalizes scheme/host/default ports, but intentionally drops anchors.
    func openTab(for url: URL) -> BrowserTab? {
        guard let match = AddressSuggestionEngine.openTab(for: url,
            in: tabs.map { AddressSuggestionTab(id: $0.id, title: $0.title, url: $0.url) }) else { return nil }
        return tabs.first { $0.id == match.id }
    }
    /// The address field still holds the current page's address, unchanged.
    func isEditingCurrentAddress(_ text: String) -> Bool {
        !paletteCreatesTab && !text.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines) == selectedTab?.url?.absoluteString
    }
    func suggestions(for text: String) -> [AddressSuggestion] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commandQuery = PaletteCommand.query(in: query) {
            googleSearchSuggestions.cancel(); suggestionFavicons.cancelPreview()
            return paletteCommands(matching: commandQuery).map {
                AddressSuggestion(title: $0.title, subtitle: "", symbol: $0.symbol, url: nil, tabID: nil, command: $0.id)
            }
        }
        // One more than shown, for the search for what's typed, which the palette keeps out of its rows.
        let rows = AddressAppearance.maximumSuggestions
        let candidates = AddressSuggestionEngine.suggestions(for: query, history: browsingHistory,
            tabs: tabs.map { AddressSuggestionTab(id: $0.id, title: $0.title, url: $0.url) },
            currentURL: selectedTab?.url, editingCurrentAddress: isEditingCurrentAddress(query),
            search: searchProvider, limit: rows+1)
        var result = candidates.map { value in
            // What Enter searches for reads as the search itself, like Google's suggestions below it.
            let verbatim = value.isTypedAction && value.url == searchProvider.searchURL(query)
            return AddressSuggestion(title: verbatim ? query : value.title, subtitle: value.subtitle, symbol: value.symbol, url: value.url,
                tabID: value.tabID, command: nil, completion: value.completion, fetchFavicon: value.fetchFavicon,
                isTypedAction: value.isTypedAction, isAutofill: value.isAutofill, isVerbatimSearch: verbatim)
        }
        if searchProvider.isGoogle, palette.isPresented, (palette.input.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            let remote = googleSearchSuggestions.suggestions(for: query)
            let mixed = AddressSuggestionEngine.merging(remote, into: result.map {
                AddressCandidate(title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol, url: $0.url, tabID: $0.tabID,
                    completion: $0.completion, fetchFavicon: $0.fetchFavicon, isTypedAction: $0.isTypedAction, isAutofill: $0.isAutofill)
            }, search: searchProvider, limit: rows+1)
            result = mixed.map { value in
                result.first { $0.title == value.title && $0.url == value.url } ??
                    AddressSuggestion(title: value.title, subtitle: value.subtitle, symbol: value.symbol, url: value.url, tabID: value.tabID, command: nil)
            }
        } else { googleSearchSuggestions.cancel() }
        let typedURL = candidates.first { $0.isTypedAction && !$0.fetchFavicon }?.url
        suggestionFavicons.preview(typedURL)
        return result.prefix(result.contains { $0.isVerbatimSearch } ? rows+1 : rows).map { suggestion in
            var suggestion = suggestion
            if suggestion.tabID == nil, suggestion.command == nil, let url = suggestion.url {
                suggestion.tabID = openTab(for: url)?.id
            }
            if suggestion.symbol == "globe" {
                let origin = SitePermissions.origin(suggestion.url)
                let tab = suggestion.tabID.flatMap { id in tabs.first { $0.id == id } } ??
                    tabs.first { origin != nil && SitePermissions.origin($0.url) == origin && $0.favicon != nil }
                suggestion.favicon = suggestionFavicons.image(for: suggestion.url, fetch: suggestion.fetchFavicon, dark: theme == .dark) ?? tab?.favicon(for: theme)
            }
            return suggestion
        }
    }

    @objc func confirmClearBrowsingHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Browsing History?"
        alert.informativeText = "Remove saved visits and learned address suggestions. Your open tabs and cookies will stay."
        alert.addButton(withTitle: "Clear History"); alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.clearBrowsingHistory() }
            catch {
                let failure = NSAlert(); failure.messageText = "History could not be cleared"
                failure.informativeText = error.localizedDescription; failure.beginSheetModal(for: window)
            }
        }
    }
    func clearBrowsingHistory() throws {
        try browsingHistory.clear(); try siteSearchLearner.searches.clear()
        tabSync?.captureSearches()
        palette.removeInlineCompletion(); palette.refresh()
    }
}
