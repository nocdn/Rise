import AppKit

/// Events kept out of a Calendar tab's countdown: one meeting, until a week after it ends, or
/// every meeting of a repeating series.
struct CalendarCountdownHiding: Equatable {
    enum Scope: Equatable { case event, series }
    /// "event:<chip id>" to when it's forgotten, or "series:<series>" to 0, for always.
    private(set) var entries: [String: Double]
    init(entries: [String: Double] = [:]) { self.entries = entries }
    static let kept: TimeInterval = 7*24*3600

    func scope(of event: CalendarEvent) -> Scope? {
        if let series = event.series, entries["series:" + series] != nil { return .series }
        return entries["event:" + event.id] != nil ? .event : nil
    }
    /// A series can only be hidden as a whole when the event repeats; otherwise it's the event.
    mutating func set(_ scope: Scope?, for event: CalendarEvent, now: Date = Date()) {
        entries = entries.filter { $0.value == 0 || $0.value > now.timeIntervalSince1970 }
        entries["event:" + event.id] = nil
        if let series = event.series { entries["series:" + series] = nil }
        switch scope {
        case .series? where event.series != nil: entries["series:" + event.series!] = 0
        case .event?, .series?: entries["event:" + event.id] = max(event.end, now).addingTimeInterval(Self.kept).timeIntervalSince1970
        case nil: break
        }
    }
}

/// A right click on an event in a Calendar tab's card: answering its invitation, and keeping
/// it out of the tab's countdown.
@MainActor enum CalendarEventMenu {
    static func make(answer: CalendarAnswer?, canAnswer: Bool, hiding: CalendarCountdownHiding.Scope?, repeats: Bool, countsDown: Bool,
                     onAnswer: @escaping (CalendarAnswer) -> Void, onHide: @escaping (CalendarCountdownHiding.Scope?) -> Void) -> NSMenu {
        func item(_ title: String, on: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
            let handler = MenuAction(action); item.target = handler; item.representedObject = handler
            item.state = on ? .on : .off; item.isEnabled = enabled; return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""), menu = NSMenu(title: title)
            menu.autoenablesItems = false; items.forEach(menu.addItem); parent.submenu = menu; return parent
        }
        let menu = NSMenu(); menu.autoenablesItems = false
        // Calendar only asks Going? of an invitation.
        let respond = submenu("Respond", CalendarAnswer.allCases.map { choice in item(choice.title, on: answer == choice) { onAnswer(choice) } })
        respond.isEnabled = canAnswer; menu.addItem(respond)
        // An all-day event never counts down.
        menu.addItem(item("Hide from tab tooltip", on: hiding != nil, enabled: countsDown) { onHide(hiding == nil ? .event : nil) })
        if let hiding, countsDown {
            let scopes = submenu("Hiding from tooltip", [
                item("This event", on: hiding == .event) { onHide(.event) },
                item("All events", on: hiding == .series, enabled: repeats) { onHide(.series) },
            ])
            menu.addItem(scopes)
        }
        return menu
    }
}

@MainActor extension BrowserController {
    static let calendarHiddenKey = "Rise.CalendarCountdownHidden"
    var calendarCountdownHiding: CalendarCountdownHiding {
        CalendarCountdownHiding(entries: preferences.dictionary(forKey: Self.calendarHiddenKey) as? [String: Double] ?? [:])
    }
    func setCountdownHiding(_ scope: CalendarCountdownHiding.Scope?, for event: CalendarEvent) {
        var hiding = calendarCountdownHiding; hiding.set(scope, for: event)
        preferences.set(hiding.entries, forKey: Self.calendarHiddenKey)
        refreshCalendarBadges()
    }
    func calendarEventMenu(for event: CalendarEvent) -> NSMenu {
        let event = calendarAgenda.events.first { $0.id == event.id } ?? event
        return CalendarEventMenu.make(answer: event.answer, canAnswer: event.invited != false, hiding: calendarCountdownHiding.scope(of: event),
                                      repeats: event.series != nil, countsDown: !event.allDay,
                                      onAnswer: { [weak self] in self?.calendarAgenda.respond($0, to: event) },
                                      onHide: { [weak self] in self?.setCountdownHiding($0, for: event) })
    }
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
        let hiding = calendarCountdownHiding
        return CalendarSchedule.badge(calendarAgenda.events.filter { hiding.scope(of: $0) == nil }, now: now)
    }
    /// The countdowns move on every few seconds while a Calendar tab is open, which also keeps
    /// its events fresh.
    func refreshCalendarBadges() {
        for tab in tabs {
            let badge = calendarBadge(for: tab)
            sidebar.rows[tab.id]?.setBadge(badge); sidebar.pinnedView.tiles[tab.id]?.setBadge(badge)
        }
        sidebar.pinnedView.updateTileHeight()
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
