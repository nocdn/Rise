import AppKit

@MainActor extension BrowserController {
    /// The shield: turns blocking off or on for the site showing. With blocking off everywhere, it
    /// turns it back on, for this site too.
    func toggleAdBlockingHere() {
        let url = selectedTab?.url
        let allowed = adBlocker.allowedSite(for: url)
        if !adBlocker.enabled {
            toggleAdBlocking()
            if let allowed { adBlockPrompt.setAllowed(false, site: allowed) }
            else if let site = AdBlocker.site(of: url) { adBlockPrompt.announce(blocking: true, site: site) }
        } else if let allowed { adBlockPrompt.setAllowed(false, site: allowed) }
        else if let site = AdBlocker.site(of: url) { adBlockPrompt.setAllowed(true, site: site) }
    }
    func toggleAdBlocking() {
        blockingChangeGeneration += 1; let generation = blockingChangeGeneration
        historySwipe.cancel(); hideLinkStatus()
        // A warmed response may have been fetched under the previous policy.
        linkPreloader.cancelAll()
        let value = !adBlocker.enabled
        let change = adBlocker.setEnabled(value)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await change.value
                guard self.blockingChangeGeneration == generation else { return }
                // Switched in the site controls, they stay open through the reload it takes.
                if self.siteControlsPopover.isShown, let tab = self.selectedTab, let url = tab.page.url {
                    self.siteControlsReload = (tab.id, url, Date().addingTimeInterval(5))
                }
                let visible = Set(self.visibleTabIDs)
                for tab in self.tabs where tab.page.url != nil {
                    if visible.contains(tab.id) { tab.needsBlockingReload = false; tab.page.reloadIgnoringCache() }
                    else { tab.needsBlockingReload = true }
                }
                self.peekTab?.page.reloadIgnoringCache()
                for saved in self.suspendedPeeks.values { saved.tab.needsBlockingReload = true }
                self.update()
            } catch { self.showMessage("Couldn’t change ad blocking", error.localizedDescription) }
        }
    }
}
