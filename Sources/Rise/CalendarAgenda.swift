import AppKit

/// Keep the account in the tab's URL, including accounts selected with `authuser`.
struct CalendarAccount: Equatable {
    let baseURL: URL
    init?(url: URL?) {
        guard let url, url.scheme == "https", url.host == "calendar.google.com",
              url.path == "/calendar" || url.path.hasPrefix("/calendar/") else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = url.path.split(separator: "/")
        if path.count >= 3, path[1] == "u" || path[1] == "b", Int(path[2]) != nil { parts.path = "/calendar/\(path[1])/\(path[2])/" }
        else { parts.path = "/calendar/" }
        parts.queryItems = parts.queryItems?.filter { $0.name == "authuser" }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        parts.fragment = nil
        guard let base = parts.url else { return nil }; baseURL = base
    }
    /// Calendar's views that draw events as chips, in the address after `r/`.
    static let views: Set<String> = ["day", "week", "month", "customday", "customweek"]
    /// The view, `day` or `week`, showing `day`. Calendar needs the view named to go to a date.
    func url(view: String, day: DateComponents) -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.path += "r/\(view)/\(day.year ?? 1970)/\(day.month ?? 1)/\(day.day ?? 1)"
        return parts.url!
    }
    /// The view the tab shows, so opening an event there keeps it.
    static func view(of url: URL?) -> String? {
        guard let path = url?.path.split(separator: "/"), let r = path.firstIndex(of: "r"), r+1 < path.count else { return nil }
        let view = String(path[r+1])
        return views.contains(view) ? view : nil
    }
}

struct CalendarEvent: Equatable {
    /// Calendar's `data-eventid`: the same chip on every day the event covers.
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    /// The event's colour in Calendar, as 0xRRGGBB.
    var color: UInt32? = nil
}

/// One day of Calendar's day view, as the page draws it.
struct CalendarDay: Decodable, Equatable {
    struct Chip: Decodable, Equatable {
        let id: String
        let title: String
        /// The chip's screen reader text, such as "3pm to 3:05pm, Tiny, …".
        let label: String
        let allDay: Bool
        /// Points from the top of the day's column, and the chip's height.
        let top: Double
        let height: Double
        /// The chip's fill and border, as CSS colours.
        var fill: String? = nil
        var border: String? = nil
    }
    /// Calendar's `data-datekey`: (year − 1970) << 9 | month << 5 | day.
    let key: Int
    /// The day's column, which is 24 hours tall.
    let height: Double
    let chips: [Chip]

    var date: DateComponents { DateComponents(year: (key >> 9)+1970, month: (key >> 5) & 15, day: key & 31) }
    static func key(_ day: DateComponents) -> Int { ((day.year ?? 1970)-1970) << 9 | (day.month ?? 0) << 5 | (day.day ?? 0) }
}

enum CalendarSchedule {
    /// Calendar leaves this gap below each chip, and draws none shorter than a quarter hour.
    static let chipGap = 2.0, shortestChip = 15

    /// Every event in `days`, once. A chip's position gives its times to the minute, in any
    /// language; only a chip drawn at the shortest size takes its end from its label.
    static func events(_ days: [CalendarDay], calendar: Calendar = .current) -> [CalendarEvent] {
        var events: [String: CalendarEvent] = [:], order: [String] = []
        for day in days {
            guard day.height > 0, let midnight = calendar.date(from: day.date) else { continue }
            // The column has a border beyond its 24 hours: 1,441 points for 60-point hours.
            let perMinute = max(1, (day.height/24).rounded())/60
            for chip in day.chips {
                let event: CalendarEvent, color = Self.color(fill: chip.fill, border: chip.border)
                if chip.allDay {
                    let next = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight
                    event = CalendarEvent(id: chip.id, title: chip.title, start: midnight, end: next, allDay: true, color: color)
                } else {
                    let start = max(0, min(1440, Int((chip.top/perMinute).rounded())))
                    var end = max(start+1, min(1440, Int(((chip.top+chip.height+chipGap)/perMinute).rounded())))
                    if end-start <= shortestChip, let labelled = labelledEnd(chip.label, after: start, before: end) { end = labelled }
                    event = CalendarEvent(id: chip.id, title: chip.title, start: midnight.addingTimeInterval(Double(start*60)),
                                          end: midnight.addingTimeInterval(Double(end*60)), allDay: false, color: color)
                }
                // An event across midnight has a chip on each day: together they're the event.
                if let earlier = events[chip.id] {
                    events[chip.id] = CalendarEvent(id: chip.id, title: earlier.title, start: min(earlier.start, event.start),
                                                    end: max(earlier.end, event.end), allDay: earlier.allDay && event.allDay,
                                                    color: earlier.color ?? event.color)
                } else { events[chip.id] = event; order.append(chip.id) }
            }
        }
        return order.compactMap { events[$0] }.sorted { ($0.allDay ? 0 : 1, $0.start, $1.end) < ($1.allDay ? 0 : 1, $1.start, $0.end) }
    }

    /// The event's own colour from its chip's. Calendar fills a chip with it and borders it the
    /// same; an event that has ended is washed 40% of the way to white inside a border washed
    /// halfway, and one not yet answered is white inside a border of its colour.
    static func color(fill: String?, border: String?) -> UInt32? {
        func rgb(_ css: String?) -> [Double]? {
            guard let css, let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
            let parts = css[css.index(after: open)..<close].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3, parts.count < 4 || parts[3] > 0.5 else { return nil }
            return Array(parts.prefix(3))
        }
        func hex(_ c: [Double]) -> UInt32 { c.reduce(0) { $0 << 8 | UInt32(max(0, min(255, $1.rounded()))) } }
        let border = rgb(border)
        guard let fill = rgb(fill), fill.min()! < 248 else { return border.map(hex) }
        guard let border, fill != border else { return hex(fill) }
        if zip(fill, border).allSatisfy({ abs($0 - ($1 + (255-$1)*0.4)) <= 6 }) { return hex(border.map { 2*$0 - 255 }) }
        return hex(fill)
    }

    /// The earliest time in the label after `start` and no later than `end`, in minutes of the
    /// day: "3:05pm", "15:05", "15.05" or "15h05". Bare numbers, which could be dates, don't count.
    static func labelledEnd(_ label: String, after start: Int, before end: Int) -> Int? {
        let pattern = #"(?<![\d:.])(\d{1,2})(?:\s?[:.h]\s?(\d{2}))?\s?([ap]\.?m\.?)?(?![\d])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let text = label as NSString
        var best: Int?
        for match in regex.matches(in: label, range: NSRange(location: 0, length: text.length)) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }
            guard let hour = group(1).flatMap(Int.init), group(2) != nil || group(3) != nil else { continue }
            let minute = group(2).flatMap(Int.init) ?? 0
            guard minute < 60, hour < 24 else { continue }
            var hours = [hour]
            if let suffix = group(3)?.lowercased() {
                guard hour >= 1, hour <= 12 else { continue }
                hours = [hour%12 + (suffix.hasPrefix("p") ? 12 : 0)]
            } else if hour <= 12 { hours = [hour, hour+12] }
            for hour in hours {
                let time = hour*60+minute
                if time > start, time <= end, time < best ?? .max { best = time }
            }
        }
        return best
    }

    /// "now" for an event that began in the last five minutes, else "in 17m" for one starting
    /// within the hour. All-day events have no time to count down to.
    static func badge(_ events: [CalendarEvent], now: Date = Date()) -> String? {
        let timed = events.filter { !$0.allDay && $0.end > now }
        if timed.contains(where: { $0.start <= now && now.timeIntervalSince($0.start) < 5*60 }) { return "now" }
        guard let next = timed.filter({ $0.start > now }).map(\.start).min() else { return nil }
        let minutes = Int((next.timeIntervalSince(now)/60).rounded(.up))
        if minutes > 60 { return nil }
        return minutes == 60 ? "in 1h" : "in \(max(1, minutes))m"
    }

    /// Side by side where they overlap, as Calendar lays them out: each event's column, and how
    /// many columns its group of overlapping events needs.
    static func columns(_ events: [CalendarEvent], minimumMinutes: Double = 0) -> [(event: CalendarEvent, column: Int, columns: Int)] {
        let sorted = events.filter { !$0.allDay }.sorted { ($0.start, $1.end) < ($1.start, $0.end) }
        func shownEnd(_ event: CalendarEvent) -> Date { max(event.end, event.start.addingTimeInterval(minimumMinutes*60)) }
        var result: [(event: CalendarEvent, column: Int, columns: Int)] = []
        var group: [(event: CalendarEvent, column: Int)] = [], ends: [Date] = [], groupEnd = Date.distantPast
        func close() {
            result += group.map { ($0.event, $0.column, ends.count) }
            group = []; ends = []
        }
        for event in sorted {
            if event.start >= groupEnd { close() }
            let column = ends.firstIndex { $0 <= event.start } ?? ends.count
            if column == ends.count { ends.append(shownEnd(event)) } else { ends[column] = shownEnd(event) }
            group.append((event, column)); groupEnd = max(groupEnd, shownEnd(event))
        }
        close()
        return result
    }
}

/// Today's and tomorrow's events of one account, held in memory only.
@MainActor final class CalendarAgenda {
    typealias Loader = (CalendarAccount) async throws -> [CalendarDay]
    private(set) var account: CalendarAccount?
    private(set) var events: [CalendarEvent] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt = Date.distantPast
    private var task: Task<Void, Never>?
    private var generation = 0
    var onChange: (() -> Void)?
    private let reader = CalendarPageReader()
    var load: Loader?
    /// Moves the tabs' countdowns on; the browser owns it.
    var clock: Timer?
    /// Whether events have been read since the account was chosen.
    var hasLoaded: Bool { loadedAt != .distantPast }

    func prepare(account: CalendarAccount, source: WebPage, host: NSView, refreshAfter: TimeInterval = 60) {
        reader.prepare(source: source, host: host)
        show(account, refreshAfter: refreshAfter)
    }
    /// A new account starts empty. The same one keeps its events and, once they're older than
    /// `refreshAfter`, reads them again behind them. A new day always reads again.
    func show(_ account: CalendarAccount, refreshAfter: TimeInterval = 60) {
        guard self.account == account else {
            cancel()
            self.account = account; events = []; error = nil; loadedAt = .distantPast
            onChange?(); refresh(); return
        }
        let stale = Date().timeIntervalSince(loadedAt) >= refreshAfter || !Calendar.current.isDate(loadedAt, inSameDayAs: Date())
        if isLoading || (error == nil && hasLoaded && !stale) { return }
        refresh()
    }
    func retry() { guard account != nil, !isLoading else { return }; refresh() }
    private func refresh() {
        guard let account else { return }
        cancel(); isLoading = true
        if !hasLoaded { error = nil }
        onChange?()
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let days = try await (load ?? reader.load)(account)
                guard !Task.isCancelled, token == generation, self.account == account else { return }
                events = CalendarSchedule.events(days); loadedAt = Date(); error = nil
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                // A failed refresh keeps the events already shown.
                if !hasLoaded { self.error = (error as? CalendarPageReader.Failure)?.message ?? CalendarPageReader.Failure.unavailable.message }
                reader.cancel()
            }
            isLoading = false; task = nil; onChange?()
        }
    }
    func cancel() { generation += 1; task?.cancel(); task = nil; isLoading = false; reader.cancel() }
    func tearDown() { cancel(); reader.tearDown(); events = []; account = nil; loadedAt = .distantPast; error = nil }
    deinit { task?.cancel(); clock?.invalidate() }
}

/// A companion Calendar page, of the tab's own engine, shares the tab's session. It reads the
/// day view's chips for today, then steps to tomorrow, without opening or changing an event.
@MainActor final class CalendarPageReader {
    enum Failure: Error {
        case signedOut, unavailable
        var message: String {
            switch self {
            case .signedOut: "Sign in to Google Calendar in this tab to see your events."
            case .unavailable: "Couldn’t load events. Try again."
            }
        }
    }
    private(set) var companion: WebPage?
    static let world = "Rise.Calendar"
    func prepare(source: WebPage, host: NSView) {
        guard companion == nil else { return }
        let web = BrowserTab.makePage()
        // Offscreen in a window, so Calendar lays its grid out; out of the accessibility tree.
        let container = HiddenAccessibilityView(frame: NSRect(x: -20000, y: 0, width: 1100, height: 800))
        web.view.frame = container.bounds
        container.addSubview(web.view)
        host.addSubview(container, positioned: .below, relativeTo: host.subviews.first)
        companion = web
    }
    private func run(_ script: String, in web: WebPage) async throws -> Any? {
        try await web.evaluate("return " + script, arguments: [:], in: nil, world: .named(Self.world))
    }
    func load(_ account: CalendarAccount) async throws -> [CalendarDay] {
        guard let web = companion else { throw Failure.unavailable }
        let calendar = Calendar.current
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        let tomorrow = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: 1, to: Date())!)
        // The page already open steps back to today in place; otherwise it opens on today.
        let open = web.url.map { CalendarAccount(url: $0) == account } == true && !web.isLoading
        if !(open ? (try? await run(Self.step(Self.todayButton), in: web)) as? Bool ?? false : false) {
            web.load(account.url(view: "day", day: today))
        }
        let first = try await read(CalendarDay.key(today), in: web, account: account)
        guard (try? await run(Self.step(Self.nextButton), in: web)) as? Bool == true else { return [first] }
        let second = try? await read(CalendarDay.key(tomorrow), in: web, account: account)
        return [first] + (second.map { [$0] } ?? [])
    }
    /// Waits for the day's column, then for its chips to stop changing as Calendar fills them in.
    private func read(_ key: Int, in web: WebPage, account: CalendarAccount) async throws -> CalendarDay {
        let deadline = Date().addingTimeInterval(25)
        var previous: CalendarDay?, since = Date()
        while Date() < deadline {
            try Task.checkCancellation()
            if let host = web.url?.host, host != "calendar.google.com" {
                if host == "accounts.google.com" || host.hasSuffix("workspace.google.com") || host == "www.google.com" { throw Failure.signedOut }
            }
            if !web.isLoading, CalendarAccount(url: web.url) == account,
               let raw = try? await run(Self.snapshot, in: web) as? [String: Any], raw["ready"] as? Bool == true,
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let day = try? JSONDecoder().decode(CalendarDay.self, from: data), day.key == key {
                if day != previous { previous = day; since = Date() }
                else if Date().timeIntervalSince(since) >= 0.6 { return day }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw Failure.unavailable
    }
    func cancel() { companion?.stopLoading() }
    func tearDown() {
        companion?.view.superview?.removeFromSuperview()
        (companion as? ChromiumPage)?.browserView.close()
        companion = nil
    }

    // Calendar's own names for its header's buttons, the same in every language.
    static let todayButton = "P6mm8", nextButton = "OCpkoe"
    static func step(_ button: String) -> String {
        """
        (() => {
          const button = [...document.querySelectorAll('header button[jsname="\(button)"]')].find(b => b.getClientRects().length);
          if (!button || button.disabled) return false;
          button.click(); return true;
        })();
        """
    }
    /// The day view's column and every chip on it. Timed chips are inside the column; all-day
    /// chips are in the row above it.
    static let snapshot = #"""
    (() => {
      const clean = text => (text || '').replace(/\s+/g, ' ').trim();
      const columns = [...document.querySelectorAll('[role="gridcell"][data-datekey]')]
        .filter(cell => cell.getClientRects().length && cell.getBoundingClientRect().height > 240);
      if (columns.length !== 1) return {ready: false};
      const column = columns[0], box = column.getBoundingClientRect();
      const key = Number(column.getAttribute('data-datekey'));
      if (!Number.isInteger(key)) return {ready: false};
      const chips = [];
      for (const chip of document.querySelectorAll('[data-eventchip][data-eventid]')) {
        if (!chip.getClientRects().length) continue;
        const id = chip.getAttribute('data-eventid') || '';
        // Working location ("Office", "Home") is a pill above the day, not an event.
        if (id.startsWith('_WL_') || chip.querySelector('[data-is-pill]')) continue;
        const label = clean(chip.querySelector('.XuJrye')?.textContent || chip.getAttribute('aria-label'));
        let title = clean(chip.querySelector('.I0UMhf, .WBi6vc')?.textContent);
        if (!title) title = clean(label.split(', ')[1]) || clean(chip.innerText.split('\n')[0]);
        const timed = column.contains(chip), rect = chip.getBoundingClientRect();
        // All-day chips are filled on their button and bordered around it.
        const painted = chip.matches('[role="button"]') ? chip : chip.querySelector('[role="button"]') || chip;
        chips.push({id, title: title || '(No title)', label, allDay: !timed,
                    top: timed ? rect.top - box.top : 0, height: timed ? rect.height : 0,
                    fill: getComputedStyle(painted).backgroundColor, border: getComputedStyle(chip).borderTopColor});
      }
      return {ready: true, key, height: box.height, chips: chips.filter(chip => chip.id)};
    })();
    """#
    /// Opens an event's details in Calendar's own page, as a click on its chip does.
    static func open(_ id: String) -> String {
        let id = id.filter { $0.isLetter || $0.isNumber || "_-=".contains($0) }
        return """
        (() => {
          const chip = [...document.querySelectorAll('[data-eventchip][data-eventid="\(id)"]')].find(c => c.getClientRects().length);
          if (!chip) return false;
          chip.scrollIntoView({block: 'center'});
          (chip.matches('[role="button"]') ? chip : chip.querySelector('[role="button"]') || chip).click();
          return true;
        })();
        """
    }
}
