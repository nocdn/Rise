import Foundation

extension SelectionTimes {
    /// ISO/RFC 3339 and PostgreSQL timestamptz output. A missing zone is deliberately not UTC.
    struct Timestamp {
        let range: NSRange
        let time: SelectionTime?
        static let expression = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?:\d{8}[Tt]\d{6}[Zz]|\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}(?::\d{2}(?:[.,]\d{1,9})?)?(?:\h*(?:[Zz]|[+\-][\d:]+|UTC(?:\h*[+\-][\d:]+)?|GMT(?:\h*[+\-][\d:]+)?|[A-Z][A-Za-z_]+/[A-Za-z_+\-0-9]+(?:/[A-Za-z_+\-0-9]+)?))?)(?![\p{L}\p{N}_])"#)
        private static let components = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?\h*([Zz]|[+\-]\d{2}(?::?\d{2})?|UTC(?:\h*[+\-][\d:]+)?|GMT(?:\h*[+\-][\d:]+)?|[A-Z][A-Za-z_]+/[A-Za-z_+\-0-9]+(?:/[A-Za-z_+\-0-9]+)?)$"#)
        static func matches(in text: String) -> [Timestamp] {
            let source = text as NSString
            return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
                let written = source.substring(with: match.range)
                let canonical = written.replacingOccurrences(of: #"(?i)^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$"#, with: "$1-$2-$3T$4:$5:$6Z", options: .regularExpression)
                let value = canonical as NSString
                func read() -> SelectionTime? {
                    guard let m = components.firstMatch(in: canonical, range: NSRange(location: 0, length: value.length)) else { return nil }
                    func group(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : value.substring(with: m.range(at: i)) }
                    let numbers = (1...6).map { Int(group($0)) ?? 0 }
                    let token = group(8), digits = token.dropFirst().filter(\.isNumber)
                    let hours = Int(digits.prefix(2)) ?? 0, minutes = digits.count == 4 ? Int(digits.suffix(2)) ?? 0 : 0
                    let named = token.first?.isLetter == true
                    guard numbers[0] > 0, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]),
                          numbers[3] < 24, numbers[4] < 60, numbers[5] < 60,
                          named || minutes < 60 && hours*60+minutes <= 14*60,
                          let zone = named ? SelectionTimes.zone(at: token.uppercased() == "Z" ? "UTC" : token)
                            : TimeZone(secondsFromGMT: (token.first == "-" ? -1 : 1)*(hours*3600+minutes*60)) else { return nil }
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                    let parts = DateComponents(timeZone: zone, year: numbers[0], month: numbers[1], day: numbers[2],
                                               hour: numbers[3], minute: numbers[4], second: numbers[5])
                    guard let whole = calendar.date(from: parts) else { return nil }
                    let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
                    guard [actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second] == numbers.map(Optional.some) else { return nil }
                    let fraction = Double("0."+group(7)) ?? 0
                    return SelectionTime(start: whole.addingTimeInterval(fraction), end: nil, zone: zone, written: written)
                }
                return Timestamp(range: match.range, time: read())
            }
        }
    }

    /// Permanent page text includes its local zone and preserves a timestamp's explicit date.
    public static func onPage(_ time: SelectionTime, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) -> String {
        let dated = Clock.hasDate(time.written) || Timestamp.expression.firstMatch(in: time.written, range: NSRange(location: 0, length: time.written.utf16.count)) != nil
        let seconds = time.written.range(of: #"\d{1,2}:\d{2}:\d{2}|\d{8}[Tt]\d{6}[Zz]"#, options: .regularExpression) != nil
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = local
        let format = DateFormatter(); format.locale = locale; format.timeZone = local
        func text(_ date: Date) -> String {
            let includeDate = dated || !calendar.isDate(date, inSameDayAs: now)
            format.setLocalizedDateFormatFromTemplate((includeDate ? "dMMMy" : "") + (seconds ? "jmmss" : "jmm"))
            let value = format.string(from: date)
            let style: TimeZone.NameStyle = local.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard
            return value + " " + (local.localizedName(for: style, locale: locale) ?? local.abbreviation(for: date) ?? local.identifier)
        }
        return text(time.start) + (time.end.map { " – " + text($0) } ?? "")
    }
}

/// One native parser and one DOM writer on both platforms. Only changed text nodes are written;
/// exact originals, inline markup, live page changes and independent currency edits are retained.
@MainActor public final class TimePageConversion {
    public typealias Evaluate = @MainActor (String, [String: Any]) async throws -> Any?
    public private(set) var isActive = false
    public private(set) var count = 0
    public var onChange: (() -> Void)?
    private let evaluate: Evaluate
    private var session = ""
    private var polling: Task<Void, Never>?
    private var reference = Date()
    private var local = TimeZone.current
    private var locale = Locale.current
    private var cache: [String: [Edit]] = [:]
    private var preparing = false
    private var ready: [CheckedContinuation<Void, Never>] = []
    public init(evaluate: @escaping Evaluate) { self.evaluate = evaluate }
    deinit { polling?.cancel() }
    public func waitUntilReady() async {
        if preparing { await withCheckedContinuation { ready.append($0) } }
    }

    public struct Edit: Sendable {
        public let start: Int, end: Int, text: String
        var object: [String: Any] { ["start": start, "end": end, "text": text] }
    }
    public nonisolated static func edits(in text: String, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) -> [Edit] {
        guard text.range(of: #"(?i)\d:\d{2}|\d\h*[ap]\.?m\b|noon|midnight|\b\d{4}\h+(?:UTC|GMT|[A-Z]{2,5})\b|\d{8}t\d{6}z"#, options: .regularExpression) != nil else { return [] }
        return SelectionTimes.matches(in: text, now: now, local: local).compactMap { match in
            guard !match.time.isZoneOnly else { return nil }
            let replacement = SelectionTimes.onPage(match.time, now: now, local: local, locale: locale)
            guard replacement != (text as NSString).substring(with: match.range) else { return nil }
            return Edit(start: match.range.location, end: NSMaxRange(match.range), text: replacement)
        }
    }

    @discardableResult public func set(_ on: Bool, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) async throws -> Int {
        polling?.cancel(); polling = nil
        let previous = session
        session = UUID().uuidString
        let token = session
        preparing = on
        defer {
            if session == token {
                preparing = false
                let waiting = ready; ready.removeAll(); waiting.forEach { $0.resume() }
            }
        }
        if !on {
            isActive = false; count = 0; cache.removeAll(); onChange?()
            _ = try await evaluate(Self.script + "\nreturn globalThis.riseTimes.restore(session);", ["session": previous])
            return 0
        }
        self.reference = now; self.local = local; self.locale = locale; cache.removeAll(); count = 0
        isActive = true; onChange?()
        do {
            _ = try await evaluate(Self.script + "\nreturn globalThis.riseTimes.begin(session);", ["session": token])
            guard session == token else { return 0 }
            try await refresh(token)
        } catch {
            if session == token { _ = try? await set(false) }
            throw error
        }
        guard session == token, isActive else { return 0 }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard let self, self.session == token, self.isActive else { return }
                do { try await self.refresh(token) } catch { /* A navigating/sleeping page will be checked again. */ }
            }
        }
        return count
    }

    private func refresh(_ token: String) async throws {
        guard session == token else { return }
        let response = try await evaluate("return globalThis.riseTimes?.take(session) ?? null;", ["session": token]) as? [String: Any]
        guard session == token else { return }
        guard let response, response["active"] as? Bool == true else {
            isActive = false; count = 0; polling?.cancel(); polling = nil; onChange?(); return
        }
        let passages = response["passages"] as? [[String: Any]] ?? []
        guard !passages.isEmpty else { return }
        let texts = Set(passages.compactMap { $0["text"] as? String }).filter { cache[$0] == nil }
        let now = reference, zone = local, language = locale
        let computed = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: texts.map { ($0, Self.edits(in: $0, now: now, local: zone, locale: language)) })
        }.value
        guard session == token else { return }
        cache.merge(computed) { _, new in new }
        if cache.count > 2000 { cache = computed }
        let plans: [[String: Any]] = passages.compactMap { passage in
            guard let id = passage["id"] as? Int, let text = passage["text"] as? String, let edits = cache[text] else { return nil }
            return ["id": id, "text": text, "edits": edits.map(\.object)]
        }
        let value = try await evaluate("return globalThis.riseTimes?.write(session, plans) ?? 0;", ["session": token, "plans": plans]) as? NSNumber
        guard session == token else { return }
        count += value?.intValue ?? 0
    }

    public static let noticeDuration: TimeInterval = 1.25
    public static let restoredMessage = "Original times restored"
    public static func message(_ count: Int) -> String {
        count == 0 ? "No other times to replace" : "Replaced \(count) \(count == 1 ? "time" : "times") with local time"
    }

    public static let script = PageTextEdits.script + #"""
    (() => {
      if (globalThis.riseTimes) return;
      const SKIP = 'script,style,noscript,textarea,input,select,option,code,pre,template,svg,math,[contenteditable]:not([contenteditable="false"]),[hidden],[aria-hidden="true"]';
      let state = null;
      const accepts = node => node.parentElement && !node.parentElement.closest(SKIP);
      function texts(root, limit = 32000) {
        const nodes = [], walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let length = 0;
        for (let n = root.nodeType === 3 ? root : walker.nextNode(); n; n = root.nodeType === 3 ? null : walker.nextNode()) {
          if (!accepts(n)) return null;
          length += n.data.length;
          if (length > limit || nodes.length > 80) return null;
          nodes.push(n);
        }
        return nodes;
      }
      function take(session) {
        if (!state || state.session !== session) return {active: false};
        const passages = [], used = new Set();
        const roots = [...state.pending]; state.pending.clear();
        for (const root of roots) {
          if (!root.isConnected) continue;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          for (let n = root.nodeType === 3 ? root : walker.nextNode(); n; n = root.nodeType === 3 ? null : walker.nextNode()) {
            if (used.has(n) || !accepts(n) || !/\d|noon|midnight/i.test(n.data)) continue;
            const record = state.records.get(n);
            if (record?.written === n.data) continue;
            let nodes = [n];
            // Include an inline-split clock and its zone, but never combine separate block rows.
            for (let e = n.parentElement, depth = 0; e && depth < 3; e = e.parentElement, depth++) {
              if (e.matches('body,article,section,main,ul,ol,table,tbody,tr') || e.querySelector('div,p,li,td,th,h1,h2,h3,h4,h5,h6,br')) break;
              const group = texts(e, 400);
              if (!group || group.some(x => used.has(x) || state.records.get(x)?.written === x.data)) break;
              nodes = group;
            }
            if (nodes.reduce((sum, n) => sum+n.data.length, 0) > 32000) continue;
            nodes.forEach(n => used.add(n));
            const text = nodes.map(n => n.data).join(''), id = ++state.next;
            state.plans.set(id, {nodes: nodes.map(n => new WeakRef(n)), text});
            passages.push({id, text});
          }
        }
        return {active: true, passages};
      }
      function write(session, plans) {
        if (!state || state.session !== session) return 0;
        let count = 0;
        for (const plan of plans) {
          const saved = state.plans.get(plan.id); state.plans.delete(plan.id);
          if (!saved) continue;
          const nodes = saved.nodes.map(r => r.deref());
          if (nodes.some(n => !n?.isConnected || !accepts(n)) || nodes.map(n => n.data).join('') !== plan.text) {
            nodes.filter(n => n?.isConnected).forEach(n => state.pending.add(n)); continue;
          }
          const pieces = riseTextEdits.distribute(plan.text, nodes.map(n => n.data.length), plan.edits);
          for (const [i, node] of nodes.entries()) {
            const piece = pieces[i];
            if (node.data === piece.written) continue;
            const old = state.records.get(node);
            if ((old?.changes ?? 0) >= 20) continue;
            if (!old) state.nodes.push(new WeakRef(node));
            state.records.set(node, riseTextEdits.record(old, piece));
            node.data = piece.written;
          }
          count += plan.edits.length;
        }
        return count;
      }
      function restore(session) {
        if (!state || session && state.session !== session) return false;
        state.observer.disconnect();
        for (const ref of state.nodes) {
          const node = ref.deref(), record = node && state.records.get(node);
          if (record) node.data = riseTextEdits.restore(record, node.data);
        }
        state = null; return true;
      }
      function begin(session) {
        restore();
        const root = document.body || document.documentElement;
        state = {session, pending: new Set([root]), records: new WeakMap(), nodes: [], plans: new Map(), next: 0};
        state.observer = new MutationObserver(changes => {
          for (const change of changes) {
            if (change.type === 'characterData') {
              if (state.records.get(change.target)?.written !== change.target.data) state.pending.add(change.target.parentElement || change.target);
            } else if (change.type === 'attributes') state.pending.add(change.target);
            else for (const node of change.addedNodes) if (node.nodeType === 1 || node.nodeType === 3) state.pending.add(node.parentElement || node);
          }
        });
        state.observer.observe(root, {subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['contenteditable']});
        return true;
      }
      addEventListener('pagehide', () => restore());
      globalThis.riseTimes = {begin, take, write, restore, get active() {return !!state;}};
    })();
    """#
}
