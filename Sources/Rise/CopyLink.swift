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
    /// An Option-click on a link puts its address on the pasteboard, and says so in the page bar.
    func copyLink(_ url: URL) {
        linkPasteboard.clearContents()
        guard linkPasteboard.setString(url.absoluteString, forType: .string) else { return }
        selectedBar.showNotice("Copied Link", image: BarNotice.linkImage)
    }
}
