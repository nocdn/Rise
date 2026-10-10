import AppKit

@MainActor extension BrowserController {
    /// ⇧⌘C, the sidebar's copy button and the Copy URL items put the page's address on the
    /// pasteboard and say so in the blue notice, with the copy button's confirmation glyph and
    /// AirDrop for the copied link. Copying again while the notice is down holds it longer.
    @objc func copyURL() {
        guard let url = selectedTab?.url, url.absoluteString != "about:blank" else { return }
        linkPasteboard.clearContents()
        guard linkPasteboard.setString(url.absoluteString, forType: .string) else { return }
        sidebar.copyButton.showCopied()
        siteInfoPopover.close(); siteControlsPopover.close(); permissionCoordinator.cancel(); hidePalette()
        showInfo("Link copied", image: InfoPlaque.linkCopiedIcon,
                 action: .init(symbol: "square.and.arrow.up", title: "Send Link via AirDrop") { [weak self] in self?.sendLinkViaAirDrop(url) }, kind: "link")
    }
    func sendLinkViaAirDrop(_ url: URL) {
        if let airDropHandler { airDropHandler(url); return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
            showMessage("AirDrop Unavailable", "AirDrop isn’t available on this Mac right now.")
            return
        }
        airDropService = service; service.delegate = self
        service.perform(withItems: [url])
    }
}

extension BrowserController: NSSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? { window }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { airDropService = nil }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { airDropService = nil }
}
