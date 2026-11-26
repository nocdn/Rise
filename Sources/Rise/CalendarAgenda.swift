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
    /// Its description's first lines, from its details in Calendar.
    var description: String? = nil
    /// How you've answered its invitation; nil when it has none, or it isn't answered yet.
    var answer: CalendarAnswer? = nil
    /// Whether Calendar asks you Going? about it; nil until its details have been read.
    var invited: Bool? = nil

    /// Calendar's own id for the event and the calendar it's on, which its chip's id encodes:
    /// "3t6j…_20261030T001500Z bartek@example.com" for one meeting of a repeating series.
    static func decoded(_ id: String) -> (event: String, calendar: String)? {
        var base64 = id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
    /// The same for every meeting of a repeating series, which Calendar names as the series
    /// followed by when the meeting was first set for; nil for an event that doesn't repeat.
    var series: String? {
        guard let decoded = Self.decoded(id), let underscore = decoded.event.lastIndex(of: "_") else { return nil }
        let start = decoded.event[decoded.event.index(after: underscore)...]
        guard start.range(of: #"^\d{8}(T\d{6}Z?)?$"#, options: .regularExpression) != nil else { return nil }
        return "\(decoded.event[..<underscore]) \(decoded.calendar)"
    }
}

/// An answer to an invitation, as Calendar's Going? buttons give it.
enum CalendarAnswer: String, Decodable, CaseIterable {
    case yes, no, maybe
    var title: String { switch self { case .yes: "Yes"; case .no: "No"; case .maybe: "Maybe" } }
    /// Its button in an event's details in Calendar.
    var button: String { switch self { case .yes: "xRsvpYesBu"; case .no: "xRsvpNoBu"; case .maybe: "xRsvpMaybeBu" } }
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
        var description: String? = nil
        /// Calendar strikes through a declined event's title and stripes one answered Maybe.
        var declined: Bool? = nil
        var striped: Bool? = nil
        /// Whether its details ask Going?, once they've been read.
        var invited: Bool? = nil
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
                var event: CalendarEvent, color = Self.color(fill: chip.fill, border: chip.border)
                if chip.allDay {
                    let next = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight
                    event = CalendarEvent(id: chip.id, title: chip.title, start: midnight, end: next, allDay: true, color: color,
                                          description: chip.description)
                } else {
                    let start = max(0, min(1440, Int((chip.top/perMinute).rounded())))
                    var end = max(start+1, min(1440, Int(((chip.top+chip.height+chipGap)/perMinute).rounded())))
                    if end-start <= shortestChip, let labelled = labelledEnd(chip.label, after: start, before: end) { end = labelled }
                    event = CalendarEvent(id: chip.id, title: chip.title, start: midnight.addingTimeInterval(Double(start*60)),
                                          end: midnight.addingTimeInterval(Double(end*60)), allDay: false, color: color,
                                          description: chip.description)
                }
                event.answer = answer(chip); event.invited = chip.invited
                // An event across midnight has a chip on each day: together they're the event.
                if let earlier = events[chip.id] {
                    events[chip.id] = CalendarEvent(id: chip.id, title: earlier.title, start: min(earlier.start, event.start),
                                                    end: max(earlier.end, event.end), allDay: earlier.allDay && event.allDay,
                                                    color: earlier.color ?? event.color, description: earlier.description ?? event.description,
                                                    answer: earlier.answer ?? event.answer, invited: earlier.invited ?? event.invited)
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

    /// How the chip shows you've answered: struck through for No, striped for Maybe, white inside
    /// its border while unanswered, and filled for Yes. Only an invitation has an answer, and
    /// only its details tell a filled one from an event of your own.
    static func answer(_ chip: CalendarDay.Chip) -> CalendarAnswer? {
        guard chip.invited != false else { return nil }
        if chip.declined == true { return .no }
        if chip.striped == true { return .maybe }
        return chip.invited == true && color(fill: chip.fill, border: nil) != nil ? .yes : nil
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
    /// An event you've declined has nothing to count down to.
    static func badge(_ events: [CalendarEvent], now: Date = Date()) -> String? {
        let timed = events.filter { !$0.allDay && $0.end > now && $0.answer != .no }
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

/// Today's countdown and a bounded cache of browsed days, held in memory only.
@MainActor final class CalendarAgenda {
    typealias Loader = (CalendarAccount) async throws -> [CalendarDay]
    typealias DayLoader = (CalendarAccount, Date) async throws -> [CalendarDay]
    typealias Answerer = (CalendarAnswer, CalendarEvent, CalendarAccount) async throws -> Void
    private(set) var account: CalendarAccount?
    private(set) var events: [CalendarEvent] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt = Date.distantPast
    private var task: Task<Void, Never>?
    private var generation = 0
    private struct DaySnapshot { var events: [CalendarEvent]; let loadedAt: Date }
    private var days: [Date: DaySnapshot] = [:]
    private var prefetchDays: [Date] = []
    private var isPrefetching = false
    /// Today always uses the normal view, without a date navigation header.
    private(set) var browsingDay: Date?
    var displayedDay: Date { browsingDay ?? Calendar.current.startOfDay(for: Date()) }
    var displayedEvents: [CalendarEvent] { browsingDay.flatMap { days[$0]?.events } ?? events }
    var displayedHasLoaded: Bool { browsingDay.map { days[$0] != nil } ?? hasLoaded }
    private var displayedLoadedAt: Date { browsingDay.flatMap { days[$0]?.loadedAt } ?? (browsingDay == nil ? loadedAt : .distantPast) }
    var onChange: (() -> Void)?
    /// An answer Calendar didn't take; the event has its earlier answer back.
    var onAnswerFailed: ((CalendarEvent, Error) -> Void)?
    private let reader = CalendarPageReader()
    /// Answers take the companion one at a time, and refreshes wait for them.
    private var answering: Task<Void, Never>?, answersWaiting = 0
    var load: Loader?
    var loadDay: DayLoader?
    /// Reads a day's events itself, rather than from Calendar's page: someone else's, from Calendar's API.
    var readsEvents: ((Date) async throws -> [CalendarEvent])?
    var answerer: Answerer?
    /// Moves the tabs' countdowns on; the browser owns it.
    var clock: Timer?
    /// Whether events have been read since the account was chosen.
    var hasLoaded: Bool { loadedAt != .distantPast }

    /// With `background`, a page let go for going unused (`releasePage`) stays let go until a hover.
    func prepare(account: CalendarAccount, source: WebPage, host: NSView, refreshAfter: TimeInterval = 60, background: Bool = false) {
        if background, account == self.account, reader.companion == nil, hasLoaded { return }
        if !background || reader.companion == nil { usedAt = Date() }
        reader.prepare(source: source, host: host)
        show(account, refreshAfter: refreshAfter)
    }
    private(set) var usedAt = Date.distantPast
    /// Lets the hidden Calendar go, keeping the events read, which the card shows at once next time.
    func releasePage() {
        guard reader.companion != nil else { return }
        cancel(); reader.tearDown()
    }
    /// A new account starts empty. The same one keeps its events and, once they're older than
    /// `refreshAfter`, reads them again behind them. A new day always reads again.
    func show(_ account: CalendarAccount, refreshAfter: TimeInterval = 60) {
        guard self.account == account else {
            cancel()
            prefetchDays = []
            self.account = account; events = []; days = [:]; browsingDay = nil; error = nil; loadedAt = .distantPast
            onChange?(); refresh(); return
        }
        let stale = Date().timeIntervalSince(displayedLoadedAt) >= refreshAfter || !Calendar.current.isDate(displayedLoadedAt, inSameDayAs: Date())
        if isLoading || (error == nil && displayedHasLoaded && !stale) { return }
        refresh()
    }
    func selectDay(_ date: Date?) {
        let day = date.flatMap { Calendar.current.isDateInToday($0) ? nil : Calendar.current.startOfDay(for: $0) }
        guard day != browsingDay else { return }
        cancel(); browsingDay = day; error = nil
        onChange?()
        if !displayedHasLoaded || Date().timeIntervalSince(displayedLoadedAt) >= 60 { refresh() }
        else { prefetchNextDay() }
    }
    /// The same companion reads one day at a time. Foreground browsing and RSVP
    /// interrupt prefetching; the remaining dates resume once that work finishes.
    func beginBrowsing() {
        let today = Calendar.current.startOfDay(for: Date())
        prefetchDays = [1, -1, 2].compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        prefetchNextDay()
    }
    func endBrowsing() {
        prefetchDays = []
        if isPrefetching { cancel() }
    }
    func retry() { guard account != nil, !isLoading else { return }; refresh() }
    /// Reads the day shown again now, from Calendar's page opened afresh, whatever's kept of it.
    func reload() {
        guard account != nil else { return }
        reader.opensAfresh = true; refresh()
    }
    /// Shows the answer at once and gives it to Calendar; an answer it doesn't take is undone.
    func respond(_ answer: CalendarAnswer, to event: CalendarEvent) {
        guard let account, let shown = knownEvent(event.id), shown.answer != answer else { return }
        let earlierAnswer = shown.answer
        applyAnswer(answer, id: event.id); onChange?()
        answersWaiting += 1
        let before = answering
        answering = Task { [weak self] in
            await before?.value
            guard let self, !Task.isCancelled else { return }
            // A refresh would move the companion away from the event.
            cancel()
            var failure: Error?
            // Shown while it answers, as for a read: resting, Chrome may have frozen it.
            do {
                try await HiddenAccessibilityView.reading(reader.companion) { try await (self.answerer ?? self.reader.respond)(answer, shown, account) }
            } catch { failure = error }
            guard !Task.isCancelled else { return }
            answersWaiting -= 1
            if let failure, self.account == account {
                if knownEvent(shown.id)?.answer == answer { applyAnswer(earlierAnswer, id: shown.id) }
                onChange?(); onAnswerFailed?(shown, failure)
            }
            if answersWaiting == 0 { answering = nil; if self.account == account { refresh() } }
        }
    }
    private func knownEvent(_ id: String) -> CalendarEvent? {
        (displayedEvents+events).first { $0.id == id } ?? days.values.lazy.flatMap(\.events).first { $0.id == id }
    }
    private func applyAnswer(_ answer: CalendarAnswer?, id: String) {
        for index in events.indices where events[index].id == id { events[index].answer = answer }
        for day in Array(days.keys) {
            guard var snapshot = days[day] else { continue }
            for index in snapshot.events.indices where snapshot.events[index].id == id { snapshot.events[index].answer = answer }
            days[day] = snapshot
        }
    }
    private func refresh() {
        guard let account, answersWaiting == 0 else { return }
        cancel(); isLoading = true
        if !displayedHasLoaded { error = nil }
        onChange?()
        let token = generation, requestedDay = browsingDay
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let read = try await self.read(account, day: requestedDay)
                guard !Task.isCancelled, token == generation, self.account == account else { return }
                if let requestedDay, !read.days.contains(where: { Calendar.current.isDate($0, inSameDayAs: requestedDay) }) {
                    throw CalendarPageReader.Failure.unavailable
                }
                cache(read, baseline: requestedDay == nil)
                error = nil
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                // A failed refresh keeps the events already shown.
                if !displayedHasLoaded { self.error = (error as? CalendarPageReader.Failure)?.message ?? CalendarPageReader.Failure.unavailable.message }
                reader.cancel()
            }
            isLoading = false; task = nil; onChange?()
            prefetchNextDay()
        }
    }
    /// The days read, at their midnights, and every event on them.
    private struct Read { let days: [Date]; let events: [CalendarEvent] }
    /// Today, or `day`: from Calendar's page, which reads tomorrow with today, or from `readsEvents`.
    private func read(_ account: CalendarAccount, day: Date?) async throws -> Read {
        if let readsEvents {
            let date = Calendar.current.startOfDay(for: day ?? Date())
            return Read(days: [date], events: try await readsEvents(date))
        }
        let read = try await HiddenAccessibilityView.reading(reader.companion) {
            if let day { return try await (self.loadDay ?? self.reader.loadDay)(account, day) }
            return try await (self.load ?? self.reader.load)(account)
        }
        return Read(days: read.compactMap { Calendar.current.date(from: $0.date).map(Calendar.current.startOfDay) },
                    events: CalendarSchedule.events(read))
    }
    private func cache(_ read: Read, baseline: Bool = false) {
        let readEvents = read.events, now = Date()
        if baseline { events = readEvents; loadedAt = now }
        for day in read.days { days[day] = DaySnapshot(events: readEvents, loadedAt: now) }
        // Keep the baseline countdown and selected day during long swipe sessions.
        let today = Calendar.current.startOfDay(for: now), tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)
        for date in days.keys.sorted(by: { days[$0]!.loadedAt < days[$1]!.loadedAt }) where days.count > 14 && date != today && date != tomorrow && date != browsingDay {
            days[date] = nil
        }
    }
    private func prefetchNextDay() {
        guard task == nil, answersWaiting == 0, hasLoaded, let account else { return }
        while let day = prefetchDays.first, let cached = days[day], Date().timeIntervalSince(cached.loadedAt) < 60 {
            prefetchDays.removeFirst()
        }
        guard let day = prefetchDays.first else { return }
        let token = generation
        isPrefetching = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let read = try await self.read(account, day: day)
                guard !Task.isCancelled, token == generation, self.account == account else { return }
                if read.days.contains(where: { Calendar.current.isDate($0, inSameDayAs: day) }) { cache(read) }
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                // A background miss never replaces the current day's content or error.
                reader.cancel()
            }
            prefetchDays.removeAll { $0 == day }
            isPrefetching = false; task = nil
            prefetchNextDay()
        }
    }
    func cancel() { generation += 1; task?.cancel(); task = nil; isLoading = false; isPrefetching = false; reader.cancel() }
    func tearDown() {
        answering?.cancel(); answering = nil; answersWaiting = 0
        cancel(); prefetchDays = []; reader.tearDown(); events = []; days = [:]; browsingDay = nil; account = nil; loadedAt = .distantPast; error = nil
    }
    deinit { task?.cancel(); answering?.cancel(); clock?.invalidate() }
}

/// A companion Calendar page, of the tab's own engine, shares the tab's session. It reads the
/// day view's chips for today, then steps to tomorrow, without opening or changing an event.
@MainActor final class CalendarPageReader {
    enum Failure: Error {
        case signedOut, unavailable
        /// Someone else's calendar: one not shared with you, and the page signed out of Google.
        case notShared, personSignedOut
        var message: String {
            switch self {
            case .signedOut: "Sign in to Google Calendar in this tab to see your events."
            case .unavailable: "Couldn’t load events. Try again."
            case .notShared: "Their calendar isn’t shared with you."
            case .personSignedOut: "Sign in to Google to see their calendar."
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
        container.restsBetweenReads()
        companion = web
    }
    private func run(_ script: String, in web: WebPage) async throws -> Any? {
        try await web.evaluate("return " + script, arguments: [:], in: nil, world: .named(Self.world))
    }
    /// The next read opens Calendar's page again, rather than reading the one open, and reads
    /// events' details again too.
    var opensAfresh = false
    private func takeAfresh() -> Bool {
        let afresh = opensAfresh; opensAfresh = false
        if afresh { descriptions = [:]; invitations = [:] }
        return afresh
    }
    func load(_ account: CalendarAccount) async throws -> [CalendarDay] {
        guard let web = companion else { throw Failure.unavailable }
        let afresh = takeAfresh()
        let calendar = Calendar.current
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        let tomorrow = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: 1, to: Date())!)
        // The page already open steps back to today in place; otherwise it opens on today.
        let open = !afresh && web.url.map { CalendarAccount(url: $0) == account } == true && !web.isLoading
        if !(open ? (try? await run(Self.step(Self.todayButton), in: web)) as? Bool ?? false : false) {
            web.load(account.url(view: "day", day: today))
        }
        if !calendar.isDate(describedOn, inSameDayAs: Date()) { descriptions = [:]; invitations = [:]; describedOn = Date() }
        let first = try await describe(read(CalendarDay.key(today), in: web, account: account), in: web)
        guard (try? await run(Self.step(Self.nextButton), in: web)) as? Bool == true else { return [first] }
        var second = try? await read(CalendarDay.key(tomorrow), in: web, account: account)
        if let day = second { second = try await describe(day, in: web) }
        return [first] + (second.map { [$0] } ?? [])
    }
    /// Browsing uses the same signed-in companion and never changes the user's real Calendar tab.
    func loadDay(_ account: CalendarAccount, _ date: Date) async throws -> [CalendarDay] {
        guard let web = companion else { throw Failure.unavailable }
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let target = account.url(view: "day", day: day)
        if takeAfresh() || web.url != target || web.isLoading { web.load(target) }
        let read = try await read(CalendarDay.key(day), in: web, account: account)
        return [try await describe(read, in: web)]
    }
    /// Each event's description, read once a day from its details, which open and close
    /// again in the companion as a click on its chip opens them. "" for none.
    private var descriptions: [String: String] = [:], invitations: [String: Bool] = [:], describedOn = Date.distantPast
    static let descriptionLines = 6
    private func describe(_ day: CalendarDay, in web: WebPage) async throws -> CalendarDay {
        for chip in day.chips where descriptions[chip.id] == nil {
            try Task.checkCancellation()
            // A click while the last event's details are still closing doesn't open the next's.
            for _ in 0..<15 {
                guard (try? await run(Self.closeDetails, in: web)) as? Bool == true else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard (try? await run(Self.open(chip.id), in: web)) as? Bool == true else { continue }
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                if let shown = try? await run(Self.details, in: web) as? [String: Any], let text = shown["text"] as? String {
                    descriptions[chip.id] = text; invitations[chip.id] = shown["invited"] as? Bool; break
                }
            }
            _ = try? await run(Self.closeDetails, in: web)
        }
        let chips = day.chips.map { chip -> CalendarDay.Chip in
            var chip = chip
            chip.description = descriptions[chip.id].flatMap { Self.firstLines($0, Self.descriptionLines) }
            chip.invited = invitations[chip.id]
            return chip
        }
        return CalendarDay(key: day.key, height: day.height, chips: chips)
    }
    /// Its first `count` non-empty lines, ending in "…" when there's more; nil for none.
    nonisolated static func firstLines(_ text: String, _ count: Int) -> String? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.prefix(count).joined(separator: "\n")+(lines.count > count ? "…" : "")
    }
    /// The open details' description, "" without one, and whether they ask Going?; nil until
    /// they show. The description's first part is a heading for screen readers.
    static let details = #"""
    (() => {
      const dialog = document.getElementById('xDetDlg');
      if (!dialog || !dialog.getClientRects().length) return null;
      const invited = !!dialog.querySelector('#xRsvpYesBu');
      const description = document.getElementById('xDetDlgDesc');
      if (!description) return {text: '', invited};
      return {text: [...description.children].filter(e => !e.classList.contains('XuJrye')).map(e => e.innerText).join('\n').trim(), invited};
    })();
    """#
    static let closeDetails = """
    (() => {
      const dialog = document.getElementById('xDetDlg');
      if (!dialog || !dialog.getClientRects().length) return false;
      const close = dialog.querySelector('button[jsname="LgbsSe"]');
      if (close) close.click();
      else document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', keyCode: 27, bubbles: true}));
      return true;
    })();
    """
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
    /// Why an answer didn't go through.
    enum AnswerFailure: Error, Equatable {
        /// The event isn't on its day in Calendar any more.
        case missing
        /// Calendar has no Going? for it, as for an event with no guests.
        case unavailable
        /// Calendar didn't show the answer taken.
        case unconfirmed
    }
    /// Answers the event's invitation in the companion, as its details' Going? buttons do. Yes is
    /// Calendar's own Yes, joining as it chooses from your working location. A meeting of a
    /// repeating series is answered on its own, as "This event".
    func respond(_ answer: CalendarAnswer, to event: CalendarEvent, account: CalendarAccount) async throws {
        guard let web = companion else { throw Failure.unavailable }
        guard let decoded = CalendarEvent.decoded(event.id) else { throw AnswerFailure.missing }
        func shows() async -> Bool {
            (try? await web.evaluate(Self.showsChip, arguments: ["id": event.id], in: nil, world: .named(Self.world))) as? Bool == true
        }
        if !(await shows()) {
            web.load(account.url(view: "day", day: Calendar.current.dateComponents([.year, .month, .day], from: event.start)))
            let deadline = Date().addingTimeInterval(20)
            while true {
                try Task.checkCancellation()
                if let host = web.url?.host, host == "accounts.google.com" || host.hasSuffix("workspace.google.com") { throw Failure.signedOut }
                if !web.isLoading, CalendarAccount(url: web.url) == account, await shows() { break }
                guard Date() < deadline else { throw AnswerFailure.missing }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        try Task.checkCancellation()
        let result = try await web.evaluate(Self.answer, arguments: ["id": event.id, "event": decoded.event, "button": answer.button],
                                            in: nil, world: .named(Self.world)) as? String
        switch result {
        case "answered", "already": return
        case "unavailable": throw AnswerFailure.unavailable
        case "missing", "mismatch": throw AnswerFailure.missing
        default: throw AnswerFailure.unconfirmed
        }
    }
    static let showsChip = """
    return [...document.querySelectorAll('[data-eventchip][data-eventid]')].some(c => c.getClientRects().length && c.getAttribute('data-eventid') === id);
    """
    /// With `id`, the chip's id, `event`, Calendar's id for the event, and `button`, the Going?
    /// button's id: opens the event's details, checks they're its, and presses the button.
    /// A repeating event's question of which meetings to answer gets "This event" (`Woal0c`).
    /// The answer has taken once the button shows it chosen or the chip's label changes.
    static let answer = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const visible = e => !!e && e.getClientRects().length > 0;
    const details = () => { const d = document.getElementById('xDetDlg'); return visible(d) ? d : null; };
    const close = () => { const d = details(); if (d) (d.querySelector('#xDetDlgCloseBu') || d.querySelector('button[jsname="LgbsSe"]'))?.click(); };
    const scope = () => [...document.querySelectorAll('[role="dialog"]')].find(d => visible(d) && d.querySelector('input[type="radio"][value="Woal0c"]'));
    const chipNow = () => [...document.querySelectorAll('[data-eventchip][data-eventid]')].find(c => visible(c) && c.getAttribute('data-eventid') === id);
    const label = c => c ? (c.getAttribute('aria-label') || '') + '|' + (c.querySelector('.XuJrye')?.textContent || '') : '';
    const chosen = b => !!b && [b, b.parentElement, b.closest('.XsYse')].some(e => e && e.classList.contains('KKjvXb'));
    return (async () => {
      scope()?.querySelector('button[data-mdc-dialog-action="cancel"]')?.click();
      for (let i = 0; i < 20 && details(); i++) { close(); await sleep(100); }
      const chip = chipNow();
      if (!chip) return 'missing';
      chip.scrollIntoView({block: 'center'});
      (chip.matches('[role="button"]') ? chip : chip.querySelector('[role="button"]') || chip).click();
      let target = null, opened = false;
      for (let i = 0; i < 40 && !target; i++) {
        await sleep(100);
        const d = details();
        opened = opened || !!d;
        target = d?.querySelector('#' + button) || null;
        if (target && !d.outerHTML.includes(event)) { close(); return 'mismatch'; }
      }
      if (!target) { close(); return opened ? 'unavailable' : 'missing'; }
      if (chosen(target)) { close(); return 'already'; }
      const before = label(chip);
      let asked = false;
      target.click();
      for (let i = 0; i < 80; i++) {
        await sleep(100);
        const question = scope();
        if (question) {
          if (!asked) {
            asked = true;
            const only = question.querySelector('input[type="radio"][value="Woal0c"]');
            if (!only.checked) only.click();
            question.querySelector('button[data-mdc-dialog-action="ok"]')?.click();
          }
          continue;
        }
        if (chosen(details()?.querySelector('#' + button)) || label(chipNow()) !== before && chipNow()) { close(); return 'answered'; }
      }
      close();
      return 'unconfirmed';
    })();
    """#
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
        // A declined event's title is struck through; one answered Maybe is striped.
        let declined = false;
        for (let e = chip.querySelector('.I0UMhf, .WBi6vc'); e && e !== chip.parentElement; e = e.parentElement) {
          if (getComputedStyle(e).textDecorationLine.includes('line-through')) { declined = true; break; }
        }
        const striped = [chip, painted].some(e => getComputedStyle(e).backgroundImage.includes('gradient'));
        chips.push({id, title: title || '(No title)', label, allDay: !timed,
                    top: timed ? rect.top - box.top : 0, height: timed ? rect.height : 0,
                    fill: getComputedStyle(painted).backgroundColor, border: getComputedStyle(chip).borderTopColor, declined, striped});
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
