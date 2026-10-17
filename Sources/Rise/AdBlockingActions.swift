import AppKit

@MainActor extension BrowserController {
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
                let visible = Set(self.visibleTabIDs)
                for tab in self.tabs where tab.page.url != nil {
                    if visible.contains(tab.id) { tab.needsBlockingReload = false; tab.page.reloadIgnoringCache() }
                    else { tab.needsBlockingReload = true }
                }
                self.peekTab?.page.reloadIgnoringCache()
                for saved in self.suspendedPeeks.values { saved.tab.needsBlockingReload = true }
                self.update()
            } catch { self.showMessage("Couldn’t enable ad blocking", error.localizedDescription) }
        }
    }
}
