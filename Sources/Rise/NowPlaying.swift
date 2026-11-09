import AppKit

/// Chooses what the sidebar's Now Playing card shows (`NowPlayingCard.swift`) and drives it. It
/// follows the tab that most recently started playing among those not shown in the window; a
/// video floating in Picture in Picture counts as left too. Paused from the card, or anywhere
/// else, it stays until its tab is shown or the X puts it away; the X keeps it away until that tab
/// plays again. While it shows, the page is asked for its position, and its sound's levels while
/// it plays, 30 times a second.
@MainActor final class NowPlaying {
    weak var browser: BrowserController?
    private(set) var tabID: UUID?
    /// Tabs put away with the X, and when: their media pauses a moment after.
    private var dismissed: [UUID: CFTimeInterval] = [:]
    private var timer: Timer?
    private var asking = false
    private var refreshQueued = false
    private var seeking = false
    private var queuedSeek: (fraction: Double, final: Bool)?
    private var artwork: [URL: NSImage] = [:]
    private var loadingArtwork = Set<URL>(), failedArtwork = Set<URL>()
    private var card: NowPlayingCard? { browser?.sidebar.nowPlaying }

    init(browser: BrowserController) {
        self.browser = browser
        guard let card else { return }
        card.onTogglePlayback = { [weak self] in
            guard let self, let id = self.tabID else { return }
            self.browser?.togglePlayback(id)
        }
        card.onClose = { [weak self] in self?.dismiss() }
        card.onShowTab = { [weak self] in self?.showTab() }
        card.onSkip = { [weak self] forward in
            guard let self, let id = self.tabID else { return }
            self.browser?.tabMedia.skip(id, forward: forward)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.15) { [weak self] in self?.ask() }
        }
        card.onToggleMute = { [weak self] in
            guard let self, let id = self.tabID, let tab = self.browser?.tabs.first(where: { $0.id == id }) else { return }
            tab.setAudioMuted(!tab.isAudioMuted)
        }
        card.onSeek = { [weak self] fraction, final in self?.seek(to: fraction, final: final) }
    }

    /// Looks again at what plays, once for any number of changes in one turn of the run loop.
    func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.refreshQueued = false; self?.refresh() }
    }

    func refresh() {
        guard let browser, card != nil else { return }
        let now = CACurrentMediaTime()
        let ids = Set(browser.tabs.map(\.id))
        let media = browser.tabMedia.tabsWithMedia.filter { ids.contains($0.id) }
        dismissed = dismissed.filter { id, at in
            // Playing again, a while after the X paused it, it comes back.
            ids.contains(id) && !(media.contains { $0.id == id && !$0.paused } && now-at > 1.5)
        }
        let visible = Set(browser.visibleTabIDs)
        func left(_ id: UUID) -> Bool {
            guard dismissed[id] == nil else { return false }
            guard visible.contains(id) else { return true }
            return browser.tabs.first { $0.id == id }.map { browser.pictureInPicture.owns($0) } ?? false
        }
        var chosen = media.filter { !$0.paused && left($0.id) }.max { $0.playedAt < $1.playedAt }?.id
        // Paused, the card it already shows stays.
        if chosen == nil, let current = tabID, media.contains(where: { $0.id == current }), left(current) { chosen = current }
        show(chosen)
    }

    private func show(_ id: UUID?) {
        guard let browser, let card else { return }
        guard let id, let tab = browser.tabs.first(where: { $0.id == id }) else {
            if tabID != nil { tabID = nil; browser.sidebar.needsLayout = true }
            card.setShown(false); stopAsking()
            return
        }
        let changed = tabID != id
        tabID = id
        let details = browser.tabMedia.details(id) ?? TabMedia.Details()
        let host = tab.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        let title = details.title.isEmpty ? tab.title : details.title
        let artist = details.artist.isEmpty ? (details.title.isEmpty ? host : tab.title == title ? host : tab.title) : details.artist
        // Without artwork or an icon, a note.
        let icon = tab.favicon(for: browser.theme) ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium).applying(.init(paletteColors: [browser.theme.muted])))
        card.show(title: title, artist: artist, artwork: details.artwork.flatMap(image), icon: icon, muted: tab.isAudioMuted)
        card.setPlayback(paused: browser.playbackPaused(id) ?? true)
        if !card.isShown { card.setShown(true); browser.sidebar.needsLayout = true }
        if changed { card.showPosition(time: 0, duration: 0); ask() }
        startAsking()
    }

    // MARK: The page's position and levels

    private func startAsking() {
        let interval = card?.isPaused == false ? 1.0/30 : 0.5
        if let timer, abs(timer.timeInterval-interval) < 0.001 { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.ask() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func stopAsking() { timer?.invalidate(); timer = nil }
    private func ask() {
        guard !asking, let browser, let card, let id = tabID, card.isShown else { return }
        asking = true
        let meter = !card.isPaused
        browser.tabMedia.status(id, meter: meter) { [weak self] status in
            guard let self else { return }
            self.asking = false
            guard self.tabID == id, let card = self.card else { return }
            guard let status else { card.waveform.setLevels(nil); return }
            if !card.progress.isScrubbing, !card.progress.isTrackpadScrubbing, !self.seeking {
                card.showPosition(time: status.time, duration: status.duration)
            }
            card.waveform.setLevels(meter ? status.levels : nil)
            // The timer's pace follows the page's playing.
            card.setPlayback(paused: status.paused)
            self.startAsking()
        }
    }

    private func seek(to fraction: Double, final: Bool) {
        guard let browser, let id = tabID, fraction.isFinite else { return }
        if seeking { queuedSeek = (fraction, final); return }
        seeking = true
        browser.tabMedia.seek(id, to: fraction, final: final) { [weak self] status in
            guard let self else { return }
            self.seeking = false
            if let status, self.tabID == id, let card = self.card, !card.progress.isScrubbing, !card.progress.isTrackpadScrubbing {
                card.showPosition(time: status.time, duration: status.duration)
            }
            if let next = self.queuedSeek { self.queuedSeek = nil; self.seek(to: next.fraction, final: next.final) }
        }
    }

    // MARK: The card's buttons

    /// The X: pauses what plays and puts the card away until the tab plays again.
    private func dismiss() {
        guard let browser, let id = tabID else { return }
        if browser.playbackPaused(id) == false { browser.togglePlayback(id) }
        dismissed[id] = CACurrentMediaTime()
        refresh()
    }
    /// The arrows, or a click on the card: back to the tab, bringing a floating video home with it.
    private func showTab() {
        guard let browser, let id = tabID else { return }
        if browser.pictureInPicture.sourceTabID == id { browser.pictureInPicture.returnToTab() }
        else { browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true); browser.select(id) }
    }

    // MARK: Artwork

    /// The artwork once it has loaded, which shows the card again.
    private func image(_ url: URL) -> NSImage? {
        if let image = artwork[url] { return image }
        guard !loadingArtwork.contains(url), !failedArtwork.contains(url) else { return nil }
        loadingArtwork.insert(url)
        Task { [weak self] in
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("image/avif,image/webp,image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
            let data = try? await URLSession.shared.data(for: request).0
            let image = data.flatMap(NSImage.init(data:))
            guard let self else { return }
            self.loadingArtwork.remove(url)
            guard let image else { self.failedArtwork.insert(url); return }
            if self.artwork.count > 12 { self.artwork.removeAll() }
            self.artwork[url] = image
            self.setNeedsRefresh()
        }
        return nil
    }
}
