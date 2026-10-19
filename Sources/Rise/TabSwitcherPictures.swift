import AppKit

/// Pictures for Control-Tab's cards of tabs that haven't been on screen, such as tabs restored at
/// launch or opened in the background. Each page renders out of sight, behind the shown page as a
/// Peek's standby page does, long enough for its picture.
@MainActor extension BrowserController {
    /// The tabs Control-Tab goes through, most recently used first, the current one leading.
    var switcherTabIDs: [UUID] {
        let ids = tabs.map(\.id)
        var order = recentTabIDs.filter { ids.contains($0) }
        order += ids.filter { !order.contains($0) }
        if let selectedID { order.removeAll { $0 == selectedID }; order.insert(selectedID, at: 0) }
        return Array(order.prefix(tabSwitcherLimit))
    }
    var tabsNeedingSwitcherPictures: [BrowserTab] {
        let visible = Set(visibleTabIDs)
        return switcherTabIDs.compactMap { id in tabs.first { $0.id == id } }.filter { tab in
            guard !visible.contains(tab.id), tab.thumbnail == nil, let url = tab.url, url != tab.backgroundPictureURL else { return false }
            // A page held elsewhere, such as in a floating window or full screen, stays there.
            return tab.page.view.superview == nil && !pictureInPicture.owns(tab) && !tab.isInNativeFullscreen
        }
    }
    /// A moment after the tabs change, so the page being shown loads first.
    func scheduleSwitcherPictures() {
        guard ChromiumEngine.isRunning, switcherPictureWork == nil, switcherPictureTask == nil,
              !tabsNeedingSwitcherPictures.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.switcherPictureWork = nil
            self.switcherPictureTask = Task { [weak self] in
                while let self, let tab = self.tabsNeedingSwitcherPictures.first { await self.takeSwitcherPicture(of: tab) }
                self?.switcherPictureTask = nil
            }
        }
        switcherPictureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+1, execute: work)
    }
    private func takeSwitcherPicture(of tab: BrowserTab) async {
        tab.backgroundPictureURL = tab.url
        let page = tab.page, host = switcherPictureHost
        host.alphaValue = 0
        if host.superview == nil { root.addSubview(host, positioned: .below, relativeTo: pageShadow) }
        host.frame = pageShadow.frame
        // Out of sight, the page takes no hover and makes no sound.
        setCovered(true, tab)
        if !tab.heldSinceBackgroundPicture { tab.heldSinceBackgroundPicture = true; page.setAudioMuted(true) }
        page.view.frame = host.bounds; host.addSubview(page.view)
        if page.url == nil, !tab.hasAttemptedNavigation, !page.isLoading, let url = tab.requestedURL { tab.load(url) }
        // Selecting or closing the tab meanwhile ends this.
        func outOfSight() -> Bool { page.view.superview === host && tab.page === page && tabs.contains { $0 === tab } }
        let loaded = Date()+10
        while outOfSight(), page.isLoading || page.url == nil, Date() < loaded { try? await Task.sleep(for: .milliseconds(100)) }
        if outOfSight() { try? await Task.sleep(for: .milliseconds(400)) } // Its first paint.
        if outOfSight() {
            tab.captureThumbnail()
            let pictured = Date()+2
            while outOfSight(), tab.thumbnail == nil, Date() < pictured { try? await Task.sleep(for: .milliseconds(50)) }
        }
        guard page.view.superview === host else { return }
        page.view.removeFromSuperview()
        guard tabs.contains(where: { $0 === tab }), tab.page === page else { return }
        page.setMediaSuspended(true)
        setCovered(peekTab != nil, tab)
    }
    /// Shown at last, a page loaded for its picture plays and takes hover again.
    func releaseBackgroundPicturePage(_ tab: BrowserTab) {
        guard tab.heldSinceBackgroundPicture else { return }
        tab.heldSinceBackgroundPicture = false
        tab.page.setAudioMuted(tab.isAudioMuted); tab.page.setMediaSuspended(false)
        setCovered(peekTab != nil, tab)
    }
}
