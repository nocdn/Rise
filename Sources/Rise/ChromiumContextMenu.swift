#if RISE_CHROMIUM
import AppKit
import RiseChromium

/// The menu a right-click in a Chromium page opens: WebKit's page menu, with Rise's "Open Link in
/// Peek", in place of CEF's own short one.
@MainActor extension BrowserController {
    func showContextMenu(_ info: RCContextMenu, in page: ChromiumPage) {
        let menu = contextMenu(for: info, in: page)
        guard !menu.items.isEmpty else { return }
        let view = page.view
        presentContextMenu(menu, NSPoint(x: info.point.x, y: view.isFlipped ? info.point.y : view.bounds.height-info.point.y), view)
    }

    func contextMenu(for info: RCContextMenu, in page: ChromiumPage) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = menuItem(title, action: action); item.isEnabled = enabled
            menu.addItem(item)
        }
        func group() { if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) } }
        func copy(_ url: URL) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL]); pasteboard.setString(url.absoluteString, forType: .string)
        }
        let opener = tabs.first { $0.page === page }
        func openInNewTab(_ url: URL) { addTab(url: url).returnsTo = opener?.id }

        // A misspelling: the spellchecker's suggestions, first.
        if info.editable, !info.misspelledWord.isEmpty {
            if info.suggestions.isEmpty { add("No Guesses Found", enabled: false) {} }
            for word in info.suggestions.prefix(5) { add(word) { info.replaceMisspelling(with: word) } }
            group()
            add("Learn Spelling") { info.learnMisspelledWord() }
            group()
        }
        if let link = info.linkURL {
            add("Open Link") { page.load(link) }
            add("Open Link in New Tab") { openInNewTab(link) }
            // As on WebKit: not from a Peek's own page.
            if page !== peekTab?.page, ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                add("Open Link in Peek") { [weak self, weak page] in self?.showPeek(url: link, from: page?.view) }
            }
            group()
            add("Download Linked File") { page.browserView.download(link) }
            add("Copy Link") { copy(link) }
        }
        if let source = info.sourceURL, info.mediaKind != .none {
            group()
            let noun = info.mediaKind == .image ? "Image" : info.mediaKind == .video ? "Video" : "Audio"
            add("Open \(noun) in New Tab") { openInNewTab(source) }
            add("Download \(noun)") { page.browserView.download(source) }
            add("Copy \(noun) Address") { copy(source) }
            if info.mediaKind == .image { add("Copy Image", enabled: info.hasImageContents) { info.copyImage() } }
        }
        let selection = info.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A link's own text isn't a selection to look up, as on WebKit.
        if !selection.isEmpty, info.linkURL == nil {
            group()
            let shown = selection.count > 30 ? selection.prefix(30).trimmingCharacters(in: .whitespaces) + "…" : selection
            add("Look Up “\(shown)”") { info.lookUp() }
            let provider = searchProvider
            if let search = provider.searchURL(selection) {
                add("Search with \(provider.title)") { [weak self] in self?.addTab(url: search) }
            }
        }
        if info.editable {
            group()
            add("Cut", enabled: info.editFlags.contains(.canCut)) { info.perform(.cut) }
            add("Copy", enabled: info.editFlags.contains(.canCopy)) { info.perform(.copy) }
            add("Paste", enabled: info.editFlags.contains(.canPaste)) { info.perform(.paste) }
            if #available(macOS 15.2, *) {
                let writingTools = NSMenuItem.writingToolsItems
                if !writingTools.isEmpty { group(); writingTools.forEach(menu.addItem) }
            }
        } else if !selection.isEmpty, info.linkURL == nil {
            group()
            add("Copy") { info.perform(.copy) }
        }
        // Nothing in particular: the page itself.
        if menu.items.isEmpty {
            add("Back", enabled: page.canGoBack) { page.goBack() }
            add("Forward", enabled: page.canGoForward) { page.goForward() }
            add("Reload") { page.reload() }
        }
        if opener != nil {
            group()
            add("Inspect Element") { [weak self, weak page] in
                guard let self, let page else { return }
                self.inspectElement(info, in: page)
            }
        }
        return menu
    }
}
#endif
