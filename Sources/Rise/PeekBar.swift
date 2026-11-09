import AppKit

/// A Peek has a page bar of its own across its card's top, as a split's right page has
/// (`SplitNavBar.swift`): its address and title, its back, forward and reload, and its page's
/// buttons, without the sidebar's button, the extensions' or developer mode's. While a Peek is
/// open, what the menus, shortcuts and page bars do to a page, they do to the Peek's (`commandTab`).
@MainActor extension BrowserController {
    static let peekBarHeight = PlainNavBar.Metrics.height
    func installPeekBar() {
        let room = PlainNavBar.Metrics.navigationCentres[1]-PlainNavBar.Metrics.navigationCentres[0]
        peekBarButtons = [
            HistoryArrowButton(direction: .back, title: "Back (⌘[)", action: { [weak self] in self?.goBack() }),
            HistoryArrowButton(direction: .forward, title: "Forward (⌘])", action: { [weak self] in self?.goForward() }),
            ReloadButton(title: "Reload (⌘R)", action: { [weak self] in self?.reload() }),
        ]
        (peekBarButtons[2] as? ReloadButton)?.onRepeatedPress = { [weak self] in self?.adBlockPrompt.noteReload() }
        peekBar.navigation = peekBarButtons
        peekBar.navigationCentres = PlainNavBar.Metrics.navigationCentres.dropFirst().map { $0-room }
        peekBar.leadingRoom = room
        peekBar.onOpenAddress = { [weak self] in self?.focusAddress() }
        peekBar.addressMenu = { [weak self] bar in self?.addressMenu(for: bar) }
    }
    /// The page that menus, shortcuts and the page bars' buttons act on: an open Peek's, in front of
    /// the selected tab's.
    var commandTab: BrowserTab? { peekTab ?? selectedTab }
    /// Whether the bar is across the open Peek's card; a Peek becoming a split's half gives it up.
    var showsPeekBar: Bool {
        guard peekTab != nil, let clip = peekCard?.subviews.first else { return false }
        return peekBar.superview === clip
    }
    /// Each bar and the page it shows, the Peek's included.
    var allPageBarTabs: [(bar: PlainNavBar, tab: BrowserTab)] {
        guard showsPeekBar, let peekTab else { return pageBarTabs }
        return pageBarTabs + [(peekBar, peekTab)]
    }
    /// The Peek's page shows under its bar.
    var peekContentInset: CGFloat { showsPeekBar ? Self.peekBarHeight : 0 }
    /// Across a new Peek card's top, above its page, showing that page from the start.
    func attachPeekBar(to clip: NSView, above page: NSView) {
        peekBar.isHidden = false; peekBarTabID = nil
        clip.addSubview(peekBar, positioned: .above, relativeTo: page)
    }
    /// A card's contents at its size: the bar across its top and the page under it, or, with no
    /// bar, the page filling it.
    func layoutPeekContents(_ card: NSView, web: NSView) {
        guard let clip = card.subviews.first else { return }
        clip.frame = card.bounds
        let inset = peekBar.superview === clip ? Self.peekBarHeight : 0
        if inset > 0 { peekBar.frame = NSRect(x: 0, y: 0, width: clip.bounds.width, height: inset) }
        if web.superview === clip { web.frame = NSRect(x: 0, y: inset, width: clip.bounds.width, height: max(0, clip.bounds.height-inset)) }
    }
    /// Its page's address, title, zoom, load and history, as the window's bar shows the selected page's.
    func updatePeekBar() {
        guard showsPeekBar, let tab = peekTab else { peekBarTabID = nil; return }
        showPageBar(peekBar, tab: tab, shown: &peekBarTabID)
        peekBarButtons[0].isEnabled = canNavigate(tab.page, .back)
        peekBarButtons[1].isEnabled = canNavigate(tab.page, .forward)
        (peekBarButtons[2] as? ReloadButton)?.setMode(tab.isLoading ? .stop : .reload)
    }
    /// A card's stand-in shaped after a card at `frame`: its bar, when it has one, along its top and
    /// its page under it, each keeping its proportion to the card's width.
    func shapePeekGhost(_ ghost: PeekGhost, like frame: NSRect, bar: PeekBarStill?) {
        let width = max(1, frame.width)
        ghost.barStill = bar
        ghost.barAspect = bar.map { Self.peekBarHeight/max(1, $0.width) } ?? 0
        ghost.pageAspect = max(0, frame.height-ghost.barAspect*width)/width
    }
    /// The bar as it is, for a card's stand-in to carry along its top while it travels.
    func peekBarStill() -> PeekBarStill? {
        guard showsPeekBar, peekBar.bounds.width > 0 else { return nil }
        peekBar.layoutSubtreeIfNeeded()
        guard let bitmap = peekBar.bitmapImageRepForCachingDisplay(in: peekBar.bounds) else { return nil }
        peekBar.cacheDisplay(in: peekBar.bounds, to: bitmap)
        let image = NSImage(size: peekBar.bounds.size); image.addRepresentation(bitmap)
        return PeekBarStill(image: image, color: peekBar.color, width: peekBar.bounds.width)
    }
}

/// A picture of the Peek's bar, its colour behind it, and the card width it was taken at, which its
/// height keeps its proportion to as the stand-in grows and shrinks.
struct PeekBarStill {
    var image: NSImage
    var color: NSColor
    var width: CGFloat
}
