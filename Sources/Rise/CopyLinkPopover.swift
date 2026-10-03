import AppKit

final class CopyConfirmationView: FlippedView {
    var hoverChanged: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
}

@MainActor final class CopiedLinkController: NSViewController, NSPopoverDelegate {
    let url: URL
    let message: NSTextField
    let shareButton: PopoverActionButton
    weak var popover: NSPopover?
    private(set) var isHovered = false
    private var dismissTimer: Timer?

    init(url: URL, theme: RiseTheme, share: @escaping (URL) -> Void) {
        self.url = url
        message = label("Link copied", size: 13, weight: .medium, color: theme.text)
        shareButton = PopoverActionButton(symbol: "square.and.arrow.up", size: 15, title: "Send Link via AirDrop", theme: theme) { share(url) }
        super.init(nibName: nil, bundle: nil)
        // Leave the body transparent: NSPopover supplies one continuous native
        // material for both its rounded frame and sideways arrow.
        let content = CopyConfirmationView(frame: NSRect(x: 0, y: 0, width: 134, height: 44))
        view = content
        message.sizeToFit()
        message.frame.origin = NSPoint(x: 12, y: (44-message.frame.height)/2)
        shareButton.frame = NSRect(x: message.frame.maxX+8, y: 8, width: 32, height: 28)
        view.setFrameSize(NSSize(width: shareButton.frame.maxX+10, height: 44))
        view.addSubview(message); view.addSubview(shareButton)
        content.hoverChanged = { [weak self] hovered in self?.setHovered(hovered) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func startDismissal(for popover: NSPopover) {
        self.popover = popover; popover.delegate = self
        if let window = view.window {
            isHovered = view.bounds.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        if !isHovered { scheduleDismissal() }
    }
    func setHovered(_ hovered: Bool) {
        isHovered = hovered; cancelDismissal()
        if !hovered { scheduleDismissal() }
    }
    func cancelDismissal() { dismissTimer?.invalidate(); dismissTimer = nil }
    private func scheduleDismissal() {
        cancelDismissal()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHovered, self.popover?.contentViewController === self else { return }
                self.popover?.performClose(nil)
            }
        }
        dismissTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func popoverDidClose(_ notification: Notification) { cancelDismissal() }
}

@MainActor extension BrowserController {
    @objc func copyURL() {
        guard let url = selectedTab?.url, url.absoluteString != "about:blank" else { return }
        linkPasteboard.clearContents()
        guard linkPasteboard.setString(url.absoluteString, forType: .string) else { return }
        siteInfoPopover.close(); siteControlsPopover.close(); permissionCoordinator.cancel(); hidePalette()
        (copiedLinkPopover.contentViewController as? CopiedLinkController)?.cancelDismissal()
        if !sidebarVisible { toggleSidebar() }
        root.layoutSubtreeIfNeeded()
        let content = CopiedLinkController(url: url, theme: theme) { [weak self] url in self?.sendLinkViaAirDrop(url) }
        copiedLinkPopover.contentViewController = content
        copiedLinkPopover.appearance = theme.appearance
        copiedLinkPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        copiedLinkPopover.contentSize = content.view.bounds.size
        copiedLinkPopover.show(relativeTo: sidebar.address.bounds, of: sidebar.address, preferredEdge: .maxX)
        content.startDismissal(for: copiedLinkPopover)
    }
    func sendLinkViaAirDrop(_ url: URL) {
        copiedLinkPopover.close()
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
