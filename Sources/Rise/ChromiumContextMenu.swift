import AppKit
import RiseCore
import RiseChromium

/// The menu a right-click in a Chromium page opens: WebKit's page menu, with Rise's "Open Link in
/// Peek", in place of CEF's own short one.
@MainActor extension BrowserController {
    func showContextMenu(_ info: RCContextMenu, in page: ChromiumPage) {
        // A request that arrives after its page has left the window, as one can once a menu's own
        // item has opened another tab, has nowhere to show: AppKit raises rather than pops it up.
        let view = page.view
        guard view.window != nil else { return }
        let menu = contextMenu(for: info, in: page)
        guard !menu.items.isEmpty else { return }
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
        func openInNewTab(_ url: URL) { addTab(url: url, opener: opener?.id ?? selectedID).returnsTo = opener?.id }

        // An event in the selection heads the menu as its time, opening to Calendar, Reminders and
        // Google Calendar, filled in (`SelectionEvents`); a time selected in another zone, in the
        // person's own (`SelectionTimes`). An event that is one of those times takes its converted label.
        let source = page.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let event = info.selectionText.isEmpty ? nil : SelectionEvents.find(in: info.selectionText, pageTitle: (opener ?? (page === peekTab?.page ? peekTab : nil))?.title)
        let shown = opener ?? (page === peekTab?.page ? peekTab : nil)
        let timesReplaced = timeReplacement.isActive(in: page)
        var times = SelectionTimes.find(in: info.selectionText, includingLocal: timesReplaced)
        if let event {
            let matched = times.firstIndex { !$0.isZoneOnly && $0.start == event.start }
            let title = matched.map { SelectionTimes.label(times[$0], of: times.count) }
            let view = page.view, point = NSPoint(x: info.point.x, y: view.isFlipped ? info.point.y : view.bounds.height-info.point.y)
            let item = selectionEventItem(event, title: title, source: source, at: point, in: view) { openInNewTab($0) }
            if let matched, let submenu = item.submenu {
                let copied = SelectionTimes.copied(times[matched])
                let copy = menuItem("Copy “\(copied)”") { Self.copyAmount(copied) }
                copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
                submenu.insertItem(copy, at: 0); submenu.insertItem(timeReplaceItem(in: page), at: 1)
            }
            menu.addItem(item)
            if let matched { times.remove(at: matched) }
        }
        // A note about the selection, lighter than a section heading's semibold: weight 450 on the
        // system font's own scale, between regular (400) and medium (510), which named weights snap to.
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let note = NSFont(descriptor: small.fontDescriptor.addingAttributes([.variation: [NSNumber(value: 0x77676874 /* wght */): 450]]), size: 0) ?? small
        for time in times {
            let title = SelectionTimes.label(time, of: times.count)
            if time.isZoneOnly {
                let header = NSMenuItem.sectionHeader(title: title)
                header.attributedTitle = NSAttributedString(string: title, attributes: [.font: note, .foregroundColor: NSColor.secondaryLabelColor])
                menu.addItem(header)
            } else {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
                let submenu = NSMenu(); submenu.autoenablesItems = false
                let copied = SelectionTimes.copied(time)
                let copy = menuItem("Copy “\(copied)”") { Self.copyAmount(copied) }
                copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
                submenu.addItem(copy); submenu.addItem(timeReplaceItem(in: page)); item.submenu = submenu
                menu.addItem(item)
            }
        }
        if timesReplaced && times.isEmpty && event == nil { menu.addItem(timeReplaceItem(in: page)) }
        // An amount in another currency, in the person's.
        let currencyReplaced = shown?.replacedCurrency != nil
        let amounts = info.selectionText.isEmpty ? [] : selectedAmounts(info.selectionText, in: page, replaced: currencyReplaced)
        if let shown { currencyItems(for: amounts, in: shown, replaced: currencyReplaced).forEach(menu.addItem) }
        // A weight, distance, temperature or speed in other units, in the person's.
        let measurements = measurementItems(for: info.selectionText, in: page)
        measurements.forEach(menu.addItem)
        // An address, on Google Maps in a Peek that grows out of the selection: beside a link's own
        // Peek when the address is a link, or else heading the menu. Not from a Peek's own page.
        let address = info.selectionText.isEmpty || page === peekTab?.page ? nil : SelectionAddresses.find(in: info.selectionText)
        func addMap() {
            guard let address else { return }
            add("Open Map in Peek") { [weak self, weak page] in
                self?.showPeek(url: SelectionAddresses.mapsURL(for: address), from: page?.view, fromSelection: true)
            }
        }
        if info.linkURL == nil { addMap() }
        if event != nil || !times.isEmpty || !amounts.isEmpty || !measurements.isEmpty || (address != nil && info.linkURL == nil) { menu.addItem(.separator()) }

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
            addMap()
            group()
            // An email address or phone number on its own, not the link that writes or rings it.
            let copies = LinkCopy(link)
            if copies.isDownloadable { add("Download Linked File") { info.download(link) } }
            add(copies.title) {
                guard let text = copies.text else { copy(link); return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
            // The system's own, as Safari's: the share sheet, from the menu, for the link.
            let picker = NSSharingServicePicker(items: [link])
            sharingPicker = picker
            menu.addItem(picker.standardShareMenuItem)
            if let airDrop = AirDropMenuItem.make(for: [link], in: { [weak page] in page?.view.window }) { menu.addItem(airDrop) }
            // A repository's link: starred as the person signed in to GitHub, in a section of its own.
            if let repository = GitHubRepository(url: link) {
                group()
                add("Star GitHub Repo") { [weak self] in self?.starGitHubRepository(repository) }
            }
        }
        if let source = info.sourceURL, info.mediaKind != .none {
            group()
            let noun = info.mediaKind == .image ? "Image" : info.mediaKind == .video ? "Video" : "Audio"
            add("Open \(noun) in New Tab") { openInNewTab(source) }
            add("Download \(noun)") {
                guard info.mediaKind == .video else { info.download(source); return }
                Task { info.download(await ContextMenuVideoSource.resolve(source, in: page)) }
            }
            add("Copy \(noun) Address") { copy(source) }
            if info.mediaKind == .image { add("Copy Image", enabled: info.hasImageContents) { info.copyImage() } }
            // The file itself rather than its address, which a link's own AirDrop above would send.
            if AirDropMenuItem.canSend([source]) {
                let video = info.mediaKind == .video
                menu.addItem(AirDropMenuItem.item(title: "AirDrop \(noun)") { [weak self, weak page] in
                    guard let page else { return }
                    self?.airDropMedia(source, named: noun, video: video, from: info, in: page)
                })
            }
        }
        let selection = info.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A link's own text isn't a selection to look up, as on WebKit.
        if !selection.isEmpty, info.linkURL == nil {
            group()
            if !info.editable {
                add("Ask About Selection…") { [weak self, weak page] in
                    if let page { self?.annotations.create(in: page, fallback: selection) }
                }
            }
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
            // Chrome's preview offers just the selection, as its menu does here.
            add("Print…", enabled: page.browserView.canPrint) { info.printPage() }
        }
        // Nothing in particular: the page itself.
        if menu.items.isEmpty {
            add("Back", enabled: page.canGoBack) { page.goBack() }
            add("Forward", enabled: page.canGoForward) { page.goForward() }
            add("Reload") { page.reload() }
            group()
            add("Print…", enabled: page.browserView.canPrint) { info.printPage() }
        }
        // Selection utilities share a section near the end, after lookup and editing.
        let utilities = [base64DecodeItem(for: info.selectionText), base64EncodeItem(for: info.selectionText)].compactMap { $0 }
        if !utilities.isEmpty { group(); utilities.forEach(menu.addItem) }
        // Extensions' entries, where Chrome puts them.
        let entries = info.extensionItems
        if !entries.isEmpty {
            group()
            entries.map(extensionMenuItem).forEach(menu.addItem)
        }
        if opener != nil {
            group()
            add("Inspect Element") { [weak self, weak page] in
                guard let self, let page else { return }
                self.inspectElement(info, in: page)
            }
        }
        return menu.separatingIconSections()
    }

    /// An extension's entry, or one of the page's own (as DevTools gives), as a menu item.
    func extensionMenuItem(_ entry: RCExtensionMenuItem) -> NSMenuItem {
        if entry.separator { return .separator() }
        let item = entry.children.isEmpty ? menuItem(entry.title, checked: entry.checked) { entry.perform() }
            : NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        item.isEnabled = entry.enabled
        if let icon = entry.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        if !entry.children.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            entry.children.map(extensionMenuItem).forEach(submenu.addItem)
            item.submenu = submenu
        }
        return item
    }
}
