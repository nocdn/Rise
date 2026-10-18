import AppKit

@MainActor extension BrowserController {
    static let calendarBadgeKey = "Rise.CalendarUpcomingBadge"
    /// Whether a Calendar tab shows when its next event starts, such as "in 17m", after its title.
    var showsCalendarBadge: Bool { preferences.object(forKey: Self.calendarBadgeKey) as? Bool ?? true }
    func setShowsCalendarBadge(_ on: Bool) {
        preferences.set(on, forKey: Self.calendarBadgeKey)
        refreshCalendarBadges()
    }
    /// Only the account whose events are loaded has a countdown.
    func calendarBadge(for tab: BrowserTab, now: Date = Date()) -> String? {
        guard showsCalendarBadge, calendarAgenda.hasLoaded, let account = CalendarAccount(url: tab.url),
              account == calendarAgenda.account else { return nil }
        return CalendarSchedule.badge(calendarAgenda.events, now: now)
    }
    /// The countdowns move on every few seconds while a Calendar tab is open, which also keeps
    /// its events fresh.
    func refreshCalendarBadges() {
        for tab in tabs {
            let badge = calendarBadge(for: tab)
            sidebar.rows[tab.id]?.setBadge(badge); sidebar.pinnedView.tiles[tab.id]?.setBadge(badge)
        }
        let counting = showsCalendarBadge && tabs.contains { CalendarAccount(url: $0.url) != nil }
        if counting, calendarAgenda.clock == nil {
            calendarAgenda.clock = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.preloadCalendarAgenda() }
            }
        } else if !counting {
            calendarAgenda.clock?.invalidate(); calendarAgenda.clock = nil
        }
    }
}
