import AppKit

/// Someone whose day a card shows, signed in to Google as the page they were found on is.
struct CalendarPerson: Hashable {
    let email: String
    /// The Google account the page is signed in to, 1 for `/u/1/` in its address.
    let authUser: Int
    /// Calendar for that account, which keeps each person's events apart from the others'.
    var account: CalendarAccount { CalendarAccount(url: URL(string: "https://calendar.google.com/calendar/u/\(authUser)/"))! }
    /// `/u/1/` or `?authuser=1` in a Google page's address; 0 without either.
    static func authUser(of url: URL?) -> Int {
        guard let url else { return 0 }
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "authuser" })?.value,
           let index = Int(value) { return index }
        let path = url.path.split(separator: "/")
        if let u = path.firstIndex(where: { $0 == "u" || $0 == "b" }), u+1 < path.count, let index = Int(path[u+1]) { return index }
        return 0
    }
}

/// A day of someone's events, as Calendar's API gives them to the page: their titles, or for a
/// calendar shared only as free and busy times, "Busy", with the titles of events you're invited
/// to too. All in the colour Calendar's Meet with… shows the person in, unless an event has its own.
enum PersonCalendarEvents {
    /// Calendar's event colours, as its pages draw them, by the API's `colorId`.
    static let palette: [String: UInt32] = [
        "1": 0x7986CB, "2": 0x33B679, "3": 0x8E24AA, "4": 0xE67C73, "5": 0xF6BF26, "6": 0xF4511E,
        "7": 0x039BE5, "8": 0x616161, "9": 0x3F51B5, "10": 0x0B8043, "11": 0xD50000,
    ]
    /// The orange Calendar's Meet with… draws the person's events in.
    static let personColor: UInt32 = 0xF09300

    /// `items` as the script below trims them, with `own`, your own events' titles by id.
    static func events(_ items: [[String: Any]], own: [String: String], email: String, calendar: Calendar = .current) -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        for item in items {
            let type = item["eventType"] as? String
            // Working location ("Office", "Home") isn't an event, as on your own card.
            guard item["status"] as? String != "cancelled", type != "workingLocation", let id = item["id"] as? String,
                  let start = time(item["start"], calendar), let end = time(item["end"], calendar) else { continue }
            let summary = (item["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = summary.flatMap { $0.isEmpty ? nil : $0 } ?? own[id]
                ?? (type == "outOfOffice" ? "Out of office" : type == "focusTime" ? "Focus time" : "Busy")
            var event = CalendarEvent(id: chipID(id, email: email), title: title, start: start.date, end: max(end.date, start.date.addingTimeInterval(60)),
                                      allDay: start.allDay, color: (item["colorId"] as? String).flatMap { palette[$0] } ?? personColor,
                                      description: (item["description"] as? String).flatMap { CalendarPageReader.firstLines(text(fromHTML: $0), CalendarPageReader.descriptionLines) })
            // Their own answer, drawn as yours are on your card.
            switch item["answer"] as? String {
            case "accepted": event.answer = .yes; event.invited = true
            case "declined": event.answer = .no; event.invited = true
            case "tentative": event.answer = .maybe; event.invited = true
            case "needsAction": event.invited = true
            default: event.invited = false
            }
            events.append(event)
        }
        return events.sorted { ($0.allDay ? 0 : 1, $0.start, $1.end) < ($1.allDay ? 0 : 1, $1.start, $0.end) }
    }
    /// The id Calendar's own chips have: its event id and the calendar's, base64url.
    static func chipID(_ id: String, email: String) -> String {
        Data("\(id) \(email)".utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static let instant: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    /// `{dateTime}` for a time, or `{date}` for a whole day, from its midnight here.
    private static func time(_ value: Any?, _ calendar: Calendar) -> (date: Date, allDay: Bool)? {
        guard let value = value as? [String: Any] else { return nil }
        if let text = value["dateTime"] as? String, let date = instant.date(from: text) ?? fractional.date(from: text) { return (date, false) }
        guard let text = value["date"] as? String else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return (date, true)
    }
    /// A description's text: Calendar keeps descriptions as HTML.
    static func text(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>|</(p|div|li|h\d)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }
}

/// The page's scripts: one in Google's profile card, which tells of Schedule 1:1 under the
/// pointer, and one that reads a day of someone's calendar from Calendar's API.
enum PersonCalendarScript {
    static let world = "Rise.PersonCalendar", handler = "risePersonCalendar"
    /// The key Calendar's public embeds read its API with; signed in as the page is, it reads
    /// whatever of the calendar is shared with you.
    static let key = "AIzaSyBNlYH01_9Hc5S1J9vuFmu2nUqBZJNAXxs"
    /// In every frame, it does nothing but in the profile card's (contacts.google.com's hover
    /// card, in Chat, Gmail and Google's other apps). There it posts `enter`, with the person's
    /// email, and `leave` as the pointer goes on and off Schedule 1:1, which Google names the same
    /// in every language. `place()` gives the box of the button under the pointer in the frame,
    /// the frame's size and where the pointer last was; `quiet(on)` hides the button's own tooltip
    /// under Rise's card.
    static let hover = #"""
    (() => {
      if (location.hostname !== 'contacts.google.com' || !location.pathname.startsWith('/widget/hovercard')) return;
      const post = body => { try { riseHandlers.risePersonCalendar.postMessage(body); } catch {} };
      const scheduling = node => node?.closest?.('button[jsname="LyTtqb"], button[jslog^="133090;"]') ?? null;
      const person = () => (document.querySelector('[data-email*="@"]')?.getAttribute('data-email')
        || document.querySelector('[data-to-copy*="@"]')?.getAttribute('data-to-copy')
        || document.querySelector('a[href^="mailto:"]')?.getAttribute('href')?.slice(7) || '').trim().toLowerCase();
      let over = null, pointer = null, quieted = null;
      addEventListener('pointermove', event => { pointer = [event.clientX, event.clientY]; }, {capture: true, passive: true});
      addEventListener('pointerover', event => {
        pointer = [event.clientX, event.clientY];
        const button = scheduling(event.target);
        if (button === over) return;
        if (over) post({kind: 'leave'});
        over = button;
        const email = button ? person() : '';
        if (email) post({kind: 'enter', email}); else over = null;
      }, true);
      addEventListener('pointerout', event => {
        if (!over || over.contains(event.relatedTarget)) return;
        over = null; post({kind: 'leave'});
      }, true);
      addEventListener('pagehide', () => { if (over) { over = null; post({kind: 'leave'}); } });
      globalThis.risePersonCalendar = {
        place() {
          if (!over?.getClientRects().length) return null;
          const box = over.getBoundingClientRect();
          return {button: [box.left, box.top, box.width, box.height], width: innerWidth, height: innerHeight, pointer, email: person()};
        },
        quiet(on) {
          quieted?.remove(); quieted = null;
          const id = (over ?? document.querySelector('button[jsname="LyTtqb"]'))?.getAttribute('data-tooltip-id');
          if (!on || !id) return;
          quieted = document.createElement('style');
          quieted.textContent = `[id="${CSS.escape(id)}"] { visibility: hidden !important; }`;
          document.documentElement.append(quieted);
        },
      };
    })();
    """#
    /// The profile card's frame in the page (`width` by `height`), from the top left of the page's
    /// view: the one of Google's profile card frames that size, when the page holds it itself.
    static let locate = """
    const frames = [...document.querySelectorAll('iframe')].filter(f => (f.src || '').startsWith('https://contacts.google.com/widget/hovercard') && f.getClientRects().length);
    let best = null, off = 3;
    for (const frame of frames) {
      const miss = Math.abs(frame.clientWidth - width) + Math.abs(frame.clientHeight - height);
      if (miss >= off) continue;
      const box = frame.getBoundingClientRect();
      off = miss; best = [box.left + frame.clientLeft, box.top + frame.clientTop];
    }
    return best;
    """
    /// With `email`, `authUser`, `timeMin`, `timeMax` and `key`: the person's events in that time,
    /// trimmed to what the card shows, and `own`, your own events' titles by id, for those you're
    /// invited to on a calendar showing only when they're busy. `status` is the API's.
    static let read = """
    const cookie = name => document.cookie.split('; ').find(c => c.startsWith(name + '='))?.slice(name.length + 1);
    const session = cookie('SAPISID') || cookie('__Secure-3PAPISID');
    if (!session) return {status: 401};
    const now = Math.floor(Date.now() / 1000);
    const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(`${now} ${session} ${location.origin}`));
    const hash = [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
    const headers = {Authorization: `SAPISIDHASH ${now}_${hash}`, 'X-Goog-AuthUser': String(authUser)};
    const list = async calendar => {
      const query = new URLSearchParams({singleEvents: 'true', orderBy: 'startTime', timeMin, timeMax, maxResults: '250', key});
      const response = await fetch(`https://clients6.google.com/calendar/v3/calendars/${encodeURIComponent(calendar)}/events?${query}`,
                                   {credentials: 'include', headers});
      return {status: response.status, body: response.ok ? await response.json() : null};
    };
    const theirs = await list(email);
    if (!theirs.body) return {status: theirs.status};
    const items = (theirs.body.items || []).map(e => ({
      id: e.id, summary: e.summary, start: e.start, end: e.end, status: e.status, eventType: e.eventType, colorId: e.colorId,
      description: e.description?.slice(0, 2000), answer: e.attendees?.find(a => (a.email || '').toLowerCase() === email)?.responseStatus,
    }));
    const own = {};
    if (items.some(e => !e.summary && e.eventType !== 'workingLocation')) {
      for (const e of (await list('primary')).body?.items || []) if (e.summary) own[e.id] = e.summary;
    }
    return {status: 200, items, own};
    """
}

/// Someone's day, as the Calendar card shows yours, on resting on Schedule 1:1 in their Google
/// profile card. It comes out of the button's bottom-right corner as a pinned tab's card comes
/// out of its tile, and stays while the pointer crosses into it.
@MainActor final class PersonCalendarCards {
    let card = CalendarTooltip()
    /// Each person's days, kept while they're among the last few looked at.
    private(set) var agendas: [CalendarPerson: CalendarAgenda] = [:]
    private var recent: [CalendarPerson] = []
    static let kept = 6
    fileprivate var timer: Timer?
    /// The person whose Schedule 1:1 the pointer is on, the profile card's frame and its page.
    fileprivate var hovered: (person: CalendarPerson, frame: PageFrame)?
    fileprivate(set) weak var hoveredPage: WebPage?
    fileprivate(set) var shown: CalendarPerson?
    /// The page the card's person was found on, which reads their days, and its profile card.
    fileprivate(set) weak var shownPage: WebPage?
    fileprivate(set) var shownFrame: PageFrame?
    /// Schedule 1:1, in the root view, as the card was placed.
    fileprivate(set) var buttonFrame = NSRect.zero
    /// Where the pointer left the card, heading back to the button, and was last on the button.
    fileprivate var safeOrigin: NSPoint?, lastOnButton: NSPoint?
    fileprivate var insideCard = false
    fileprivate var lookups = 0
    fileprivate var pointerArea: NSTrackingArea?
    private let pages = NSHashTable<AnyObject>.weakObjects()

    func installs(on page: WebPage) -> Bool {
        guard !pages.contains(page) else { return false }
        pages.add(page); return true
    }
    func agenda(for person: CalendarPerson, make: () -> CalendarAgenda) -> CalendarAgenda {
        recent.removeAll { $0 == person }; recent.append(person)
        if let agenda = agendas[person] { return agenda }
        let agenda = make(); agendas[person] = agenda
        while recent.count > Self.kept { agendas.removeValue(forKey: recent.removeFirst())?.tearDown() }
        return agenda
    }
    func tearDown() {
        timer?.invalidate(); timer = nil
        agendas.values.forEach { $0.tearDown() }; agendas = [:]; recent = []
    }
}

@MainActor extension BrowserController {
    func installPersonCalendar(on page: WebPage) {
        guard personCalendars.installs(on: page) else { return }
        page.addMessageHandler(PersonCalendarScript.handler, world: .named(PersonCalendarScript.world)) { [weak self] message in
            self?.personCalendarMessage(message)
        }
        page.addUserScript(PersonCalendarScript.hover, world: .named(PersonCalendarScript.world), mainFrameOnly: false,
                           handlers: [PersonCalendarScript.handler])
    }
    private func personCalendarMessage(_ message: PageMessage) {
        let cards = personCalendars
        guard let body = message.body as? [String: Any], let page = message.page else { return }
        switch body["kind"] as? String {
        case "enter":
            guard showsHoverCard(.personCalendar), let email = body["email"] as? String, email.contains("@"),
                  page.view.window === window, shownPages.contains(where: { $0 === page }) else { return }
            let person = CalendarPerson(email: email.lowercased(), authUser: CalendarPerson.authUser(of: page.url))
            cards.timer?.invalidate()
            cards.hovered = (person, message.frame); cards.hoveredPage = page
            if cards.shown == person, cards.shownPage === page { cards.safeOrigin = nil; return }
            // Read while the pointer rests, so the card opens with the day.
            personAgenda(person, page: page, frame: message.frame).show(person.account)
            cards.timer = Timer.scheduledTimer(withTimeInterval: CardMotion.hoverDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showPersonCalendar() }
            }
        case "leave":
            cards.timer?.invalidate(); cards.timer = nil
            cards.hovered = nil; cards.hoveredPage = nil
            if cards.shown != nil { closePersonCalendarIfAbandoned() }
        default: break
        }
    }
    /// The person's days, read in the page they were found on while it's the card's.
    private func personAgenda(_ person: CalendarPerson, page: WebPage, frame: PageFrame) -> CalendarAgenda {
        let cards = personCalendars
        let agenda = cards.agenda(for: person) {
            let agenda = CalendarAgenda()
            agenda.onChange = { [weak self, weak agenda] in
                guard let self, let agenda, self.personCalendars.shown == person else { return }
                self.personCalendars.card.update(agenda)
            }
            return agenda
        }
        agenda.readsEvents = { [weak page] day in
            guard let page else { throw CalendarPageReader.Failure.unavailable }
            return try await Self.readPersonCalendar(person, day: day, in: page, frame: frame)
        }
        return agenda
    }
    /// A day of the person's events, read by the page: from its own frame when that's Google's,
    /// else from the profile card's.
    static func readPersonCalendar(_ person: CalendarPerson, day: Date, in page: WebPage, frame: PageFrame) async throws -> [CalendarEvent] {
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { throw CalendarPageReader.Failure.unavailable }
        let format = ISO8601DateFormatter()
        let host = page.url?.host?.lowercased() ?? ""
        let result = try await page.evaluate(PersonCalendarScript.read, arguments: [
            "email": person.email, "authUser": person.authUser, "key": PersonCalendarScript.key,
            "timeMin": format.string(from: start), "timeMax": format.string(from: end),
        ], in: host.hasSuffix(".google.com") ? nil : frame, world: .named(PersonCalendarScript.world)) as? [String: Any]
        switch (result?["status"] as? NSNumber)?.intValue {
        case 200:
            let items = result?["items"] as? [[String: Any]] ?? [], own = result?["own"] as? [String: String] ?? [:]
            return PersonCalendarEvents.events(items, own: own, email: person.email)
        case 401, 403: throw CalendarPageReader.Failure.personSignedOut
        case 404: throw CalendarPageReader.Failure.notShared
        default: throw CalendarPageReader.Failure.unavailable
        }
    }
    private func showPersonCalendar() {
        let cards = personCalendars
        guard let hovered = cards.hovered, let page = cards.hoveredPage, showsHoverCard(.personCalendar),
              window?.isVisible == true, page.view.window === window, !page.isMagnified, !page.view.isHiddenOrHasHiddenAncestor,
              shownPages.contains(where: { $0 === page }) else { return }
        cards.lookups += 1
        let lookup = cards.lookups
        Task {
            guard let button = await personCalendarButton(in: page, frame: hovered.frame), cards.lookups == lookup,
                  cards.hovered?.person == hovered.person, cards.hoveredPage === page, page.view.window === window else { return }
            presentPersonCalendar(hovered.person, button: button, page: page, frame: hovered.frame)
        }
    }
    /// Schedule 1:1 in the root view: its box in the profile card's frame, moved by where the page
    /// holds that frame, or else by how far the pointer is from where the frame last saw it.
    private func personCalendarButton(in page: WebPage, frame: PageFrame) async -> NSRect? {
        let world = ScriptWorld.named(PersonCalendarScript.world), web = page.view
        guard let place = try? await page.evaluate("return globalThis.risePersonCalendar?.place() ?? null", arguments: [:], in: frame, world: world) as? [String: Any],
              let box = (place["button"] as? [NSNumber])?.map(\.doubleValue), box.count == 4, box[2] > 0, box[3] > 0 else { return nil }
        let zoom = max(0.01, page.zoom)
        var origin: CGPoint?
        if let found = try? await page.evaluate(PersonCalendarScript.locate, arguments: ["width": place["width"] ?? 0, "height": place["height"] ?? 0],
                                                in: nil, world: world) as? [NSNumber], found.count == 2 {
            origin = CGPoint(x: found[0].doubleValue, y: found[1].doubleValue)
        } else if let seen = (place["pointer"] as? [NSNumber])?.map(\.doubleValue), seen.count == 2, let window = web.window {
            var pointer = web.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if !web.isFlipped { pointer.y = web.bounds.height-pointer.y }
            origin = CGPoint(x: pointer.x/zoom-seen[0], y: pointer.y/zoom-seen[1])
        }
        guard let origin else { return nil }
        var rect = NSRect(x: (origin.x+box[0])*zoom, y: (origin.y+box[1])*zoom, width: box[2]*zoom, height: box[3]*zoom)
        if !web.isFlipped { rect.origin.y = web.bounds.height-rect.maxY }
        return web.convert(rect, to: root)
    }
    private func presentPersonCalendar(_ person: CalendarPerson, button: NSRect, page: WebPage, frame: PageFrame) {
        let cards = personCalendars, card = cards.card
        let agenda = personAgenda(person, page: page, frame: frame)
        agenda.show(person.account)
        hideTabHoverCard(); hideLinkCard()
        if card.superview !== root {
            card.onPointer = { [weak self] inside in self?.personCalendarPointerChanged(inside) }
            card.onRetry = { [weak self] in
                guard let self, let shown = self.personCalendars.shown else { return }
                self.personCalendars.agendas[shown]?.retry()
            }
        }
        raiseHoverCard(card)
        if cards.shown != person || cards.shownPage !== page { quietPersonCalendarButton(false) }
        cards.shown = person; cards.shownPage = page; cards.shownFrame = frame
        cards.buttonFrame = button; cards.safeOrigin = nil; cards.insideCard = false
        cards.lastOnButton = NSPoint(x: button.midX, y: button.midY)
        trackPersonCalendarPointer(true)
        quietPersonCalendarButton(true)
        // Out of the button's bottom-right corner, or its bottom-left where there's no room right.
        let bounds = page.view.convert(page.view.bounds, to: root).insetBy(dx: 8, dy: 8)
        let width = CalendarTooltip.width, diagonal = 0.5.squareRoot()
        var left = button.maxX, corner = NSPoint(x: button.midX+button.width/2*diagonal, y: button.midY+button.height/2*diagonal)
        if left+width > bounds.maxX, button.minX-width >= bounds.minX {
            left = button.minX-width; corner.x = button.midX-button.width/2*diagonal
        }
        card.present(key: "person:\(person.authUser):\(person.email)", agenda: agenda,
                     left: max(bounds.minX, min(left, bounds.maxX-width)), anchorTop: button.maxY, maxBottom: bounds.maxY,
                     theme: theme, growsFrom: corner, topLimit: bounds.minY)
    }
    /// The button's own tooltip would show through under the card, half covered.
    private func quietPersonCalendarButton(_ on: Bool) {
        let cards = personCalendars
        guard let page = cards.shownPage, let frame = cards.shownFrame else { return }
        page.evaluate("globalThis.risePersonCalendar?.quiet(on)", arguments: ["on": on], in: frame,
                      world: .named(PersonCalendarScript.world)) { _ in }
    }
    func hidePersonCalendar(fades: Bool = true) {
        let cards = personCalendars
        cards.timer?.invalidate(); cards.timer = nil; cards.lookups += 1
        cards.hovered = nil; cards.hoveredPage = nil
        guard cards.shown != nil else { return }
        quietPersonCalendarButton(false)
        cards.shown = nil; cards.shownPage = nil; cards.shownFrame = nil; cards.safeOrigin = nil; cards.lastOnButton = nil
        if cards.insideCard { cards.insideCard = false; updatePeekCovers() }
        trackPersonCalendarPointer(false)
        cards.card.dismiss(animated: fades)
    }
    private func personCalendarPointerChanged(_ inside: Bool) {
        let cards = personCalendars
        guard cards.shown != nil else { return }
        cards.insideCard = inside
        // The page under the card would take its pointer for its own, and the profile card stays
        // open behind it, as the page last saw the pointer in it.
        if inside { for tab in tabs { setCovered(true, tab) }; if let peekTab { setCovered(true, peekTab) }; cards.safeOrigin = nil; return }
        updatePeekCovers()
        cards.safeOrigin = pointerInRoot
        DispatchQueue.main.async { [weak self] in self?.closePersonCalendarIfAbandoned() }
    }
    /// While the card shows, every move of the pointer, for the way between it and the button.
    private func trackPersonCalendarPointer(_ tracks: Bool) {
        let cards = personCalendars
        if tracks, cards.pointerArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: PointerMovesSink.shared, userInfo: nil)
            root.addTrackingArea(area); cards.pointerArea = area
        } else if !tracks, let area = cards.pointerArea {
            root.removeTrackingArea(area); cards.pointerArea = nil
        }
    }
    func personCalendarPointerMoved() {
        guard personCalendars.shown != nil else { return }
        closePersonCalendarIfAbandoned()
    }
    /// Over the card or the button, or on the way from one to the other, the card stays. Where the
    /// pointer is decides, not what the profile card last said, which a profile card closed or
    /// taken away doesn't take back.
    private func closePersonCalendarIfAbandoned() {
        let cards = personCalendars
        guard cards.shown != nil, !cards.insideCard, let point = pointerInRoot else { return }
        let card = cards.card.frame, button = cards.buttonFrame
        if card.contains(point) { return }
        if button.contains(point) { cards.lastOnButton = point; cards.safeOrigin = nil; return }
        if let origin = cards.safeOrigin ?? cards.lastOnButton, hypot(point.x-origin.x, point.y-origin.y) < 2
            || Self.isOnTheWay(point, from: origin, to: card) || Self.isOnTheWay(point, from: origin, to: button) { return }
        hidePersonCalendar()
    }
    /// A press on the page, outside the card, as on Schedule 1:1 itself.
    func personCalendarPagePressed(_ event: NSEvent) {
        let cards = personCalendars
        guard cards.shown != nil || cards.timer != nil else { return }
        if cards.shown != nil, cards.card.frame.contains(root.convert(event.locationInWindow, from: nil)) { return }
        hidePersonCalendar()
    }
    /// The card's page went out of sight, or another took its place.
    func refreshPersonCalendar() {
        let cards = personCalendars
        guard cards.shown != nil || cards.timer != nil else { return }
        let page = cards.shownPage ?? cards.hoveredPage
        if page == nil || page?.view.window !== window || page?.view.isHiddenOrHasHiddenAncestor == true || !shownPages.contains(where: { $0 === page }) {
            hidePersonCalendar()
        }
    }
}
