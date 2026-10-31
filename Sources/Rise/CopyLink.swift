import AppKit

@MainActor extension BrowserController {
    /// ⇧⌘C, the page bar's copy button and the Copy URL items put the page's address on the
    /// pasteboard and say so in the page bar, in the address's place, with the copy button's
    /// confirmation glyph. Copying again while it says so holds it longer.
    @objc func copyURL() {
        guard let url = selectedTab?.url, url.absoluteString != "about:blank" else { return }
        linkPasteboard.clearContents()
        guard linkPasteboard.setString(url.absoluteString, forType: .string) else { return }
        selectedBar.copyButton.showCopied()
        siteInfoPopover.close(); siteControlsPopover.close(); permissionCoordinator.cancel(); hidePalette()
        selectedBar.showCopied()
    }
    /// The address's menu, on a right-click: copying it, alone or as a Markdown link, and saying
    /// so in the bar as ⇧⌘C does; going to the address on the pasteboard; and editing the address.
    /// A split's other page becomes the selected one first, as a click on its bar makes it.
    func addressMenu(for bar: PlainNavBar) -> NSMenu? {
        guard let tab = pageBarTabs.first(where: { $0.bar === bar })?.tab ?? selectedTab, tab.url != nil else { return nil }
        if tab.id != selectedID { select(tab.id) }
        let menu = NSMenu()
        func add(_ title: String, _ id: String?, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = menuItem(title, action: action)
            if let id, let binding = keyboardShortcuts.bindings(id).first {
                item.keyEquivalent = binding.keyEquivalent; item.keyEquivalentModifierMask = binding.modifiers
            }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Copy URL", "copyURL") { [weak self] in self?.copyURL() }
        add("Copy as Markdown Link", nil) { [weak self] in self?.copyMarkdownLink() }
        menu.addItem(.separator())
        let pasted = linkPasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        add("Paste and Go", nil, enabled: !pasted.isEmpty && !pasted.contains("\n")) { [weak self] in self?.submitAddress(pasted, suggestion: nil) }
        add("Edit Address", "focusAddress") { [weak self] in self?.focusAddress() }
        menu.autoenablesItems = false
        return menu
    }
    /// The page as a Markdown link, `[title](address)`, its title the address where it has none.
    @objc func copyMarkdownLink() {
        guard let tab = selectedTab, let url = tab.url, url.absoluteString != "about:blank" else { return }
        let words = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (words.isEmpty ? AddressDisplay.text(url.absoluteString) : words)
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let address = url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        linkPasteboard.clearContents()
        guard linkPasteboard.setString("[\(title)](\(address))", forType: .string) else { return }
        siteInfoPopover.close(); siteControlsPopover.close(); hidePalette()
        selectedBar.showNotice("Copied Markdown Link", image: BarNotice.linkImage)
    }
    /// An Option-click on a link puts its address on the pasteboard, and says so in the page bar.
    func copyLink(_ url: URL) {
        linkPasteboard.clearContents()
        guard linkPasteboard.setString(url.absoluteString, forType: .string) else { return }
        selectedBar.showNotice("Copied Link", image: BarNotice.linkImage)
    }
}
