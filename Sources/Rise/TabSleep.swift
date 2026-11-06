import AppKit
import RiseCore

/// Tabs left in the background a while let their pages go, as tabs restored at launch start
/// out: each keeps its place, title, icon, picture and history, and loads again from that history
/// when it's next shown. A tab isn't let go while it's among the most recently used, pinned,
/// playing or holding media, shown anywhere, loading, or has a form part-filled.
@MainActor extension BrowserController {
    static let tabSleepMinutesKey = "Rise.TabSleepMinutes"
    /// How long a tab stays out of sight before it sleeps: 30 minutes unless set (0: never).
    var tabSleepDelay: TimeInterval? {
        let minutes = preferences.object(forKey: Self.tabSleepMinutesKey) == nil ? 30 : preferences.integer(forKey: Self.tabSleepMinutesKey)
        return minutes > 0 ? TimeInterval(minutes*60) : nil
    }
    /// The most recently used tabs, which stay awake however long ago they were seen.
    static let wakefulTabCount = 5

    func startTabSleep() {
        tabSleepTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleepIdleTabs()
                self?.tabUseTick()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        tabSleepTimer = timer
    }
    func stopTabSleep() { tabSleepTimer?.invalidate(); tabSleepTimer = nil }

    /// The tabs that could sleep now, before their pages are asked about forms.
    func tabsReadyToSleep(now: Date = Date()) -> [BrowserTab] {
        guard ChromiumEngine.isRunning, let delay = tabSleepDelay else { return [] }
        let visible = Set(visibleTabIDs)
        for tab in tabs where visible.contains(tab.id) { tab.lastSeen = now }
        let wakeful = Set(recentTabIDs.prefix(Self.wakefulTabCount) + (selectedID.map { [$0] } ?? []))
        return tabs.filter { tab in
            !visible.contains(tab.id) && !wakeful.contains(tab.id) && !tab.pinned && now.timeIntervalSince(tab.lastSeen) >= delay
                && tab.canSleep && !tab.isLoading && !tab.isPlayingAudio && playbackPaused(tab.id) == nil
                && tab.page.view.superview == nil && !pictureInPicture.owns(tab) && !tab.isInNativeFullscreen
                && peek(for: tab.id) == nil && !tabSwitchOrder.contains(tab.id) && !tabsAskedToSleep.contains(tab.id)
        }
    }
    /// Lets each tab that's been out of sight long enough sleep, once its page says no form is
    /// part-filled. A frozen page answers when it next wakes.
    func sleepIdleTabs(now: Date = Date()) {
        for tab in tabsReadyToSleep(now: now) {
            tabsAskedToSleep.insert(tab.id)
            let page = tab.page, asked = Date()
            Task { [weak self, weak tab] in
                let editing = await page.evaluate(Self.editingScript, arguments: [:], world: "Rise.TabSleep") as? Bool
                guard let self, let tab else { return }
                self.tabsAskedToSleep.remove(tab.id)
                // Still the page asked, and still ready: the answer may have taken a while.
                let answered = now.addingTimeInterval(Date().timeIntervalSince(asked))
                guard editing == false, tab.page === page, self.tabsReadyToSleep(now: answered).contains(where: { $0 === tab }) else { return }
                self.sleep(tab)
            }
        }
    }
    func sleep(_ tab: BrowserTab) {
        let view = tab.page.view
        historySwipe.cancel(for: tab.page)
        permissionCoordinator.cancel(for: view)
        if errorWebView === view { errorWebView = nil }
        guard tab.sleep() != nil else { return }
        _ = configure(tab)
        update()
    }
    static let editingScript = TabArchiveRules.editingScript
}
