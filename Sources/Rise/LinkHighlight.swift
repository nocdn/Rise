import AppKit

/// How a lit link's grey pulses while its card is on the way: points through one loop, each with
/// the fill's strength and the ring around it (its strength and width, in points), played over
/// `duration` and repeated, back and forth when `alternates`. Strengths are black's on a light
/// page; a dark page takes white, a little stronger.
struct LinkPulse: Equatable {
    struct Key: Equatable { let at: Double, fill: Double, ring: Double, width: Double }
    let name: String, summary: String
    let keys: [Key]
    let duration: Double
    let easing: String
    var alternates = false

    static func key(_ at: Double, _ fill: Double, ring: Double? = nil, width: Double = 3) -> Key { Key(at: at, fill: fill, ring: ring ?? fill, width: width) }
    /// Between two strengths, eased each way.
    static func breathe(_ name: String, _ summary: String, from high: Double, to low: Double, each: Double, easing: String = "ease-in-out") -> LinkPulse {
        LinkPulse(name: name, summary: summary, keys: [key(0, high), key(1, low)], duration: each, easing: easing, alternates: true)
    }
    /// The fill and ring once its card shows: where Breathe peaks.
    static let steady = key(1, 0.07)
    /// How much further than the ring the grey reaches at a link's sides, for each point of its
    /// text's size: 5 at 30, under 3 at 16.
    static let sidePerSize = 1/6.0

    /// Picked in Develop ▸ Link Pulse Tester; the first is where it started.
    static let presets: [LinkPulse] = [
        breathe("Breathe", "0.07 ↔ 0.045, 0.65 s each way", from: 0.07, to: 0.045, each: 0.65),
        breathe("Slow breath", "0.10 ↔ 0.04, 1.2 s each way", from: 0.10, to: 0.04, each: 1.2),
        breathe("Quick breath", "0.10 ↔ 0.05, 0.4 s each way", from: 0.10, to: 0.05, each: 0.4),
        breathe("Deep breath", "0.14 ↔ 0.02, 0.9 s each way", from: 0.14, to: 0.02, each: 0.9),
        breathe("Gentle", "0.085 ↔ 0.06, 0.8 s each way", from: 0.085, to: 0.06, each: 0.8),
        breathe("Tide", "0.11 ↔ 0.03, 2 s each way", from: 0.11, to: 0.03, each: 2),
        breathe("Beacon", "0.11 ↔ nothing, 0.9 s each way", from: 0.11, to: 0, each: 0.9),
        breathe("Flutter", "0.09 ↔ 0.065, 0.25 s each way", from: 0.09, to: 0.065, each: 0.25),
        LinkPulse(name: "Heartbeat", summary: "Two quick beats, then a rest, 1.4 s",
                  keys: [key(0, 0.05), key(0.12, 0.13), key(0.24, 0.06), key(0.36, 0.12), key(0.6, 0.05), key(1, 0.05)], duration: 1.4, easing: "ease-in-out"),
        LinkPulse(name: "Hold", summary: "In, held, out, rested, 1.8 s",
                  keys: [key(0, 0.04), key(0.35, 0.11), key(0.55, 0.11), key(0.9, 0.04), key(1, 0.04)], duration: 1.8, easing: "ease-in-out"),
        LinkPulse(name: "Strike", summary: "Up at once, fading slowly, 1.2 s",
                  keys: [key(0, 0.04), key(0.12, 0.13), key(1, 0.04)], duration: 1.2, easing: "ease-out"),
        LinkPulse(name: "Gather", summary: "Building slowly, dropping at once, 1.2 s",
                  keys: [key(0, 0.04), key(0.85, 0.12), key(1, 0.04)], duration: 1.2, easing: "ease-in"),
        LinkPulse(name: "Double breath", summary: "Two breaths, then a pause, 2 s",
                  keys: [key(0, 0.05), key(0.15, 0.1), key(0.3, 0.05), key(0.45, 0.1), key(0.6, 0.05), key(1, 0.05)], duration: 2, easing: "ease-in-out"),
        LinkPulse(name: "Ember", summary: "Uneven, like a glow, 2.4 s",
                  keys: [key(0, 0.07), key(0.2, 0.105), key(0.45, 0.06), key(0.7, 0.115), key(1, 0.07)], duration: 2.4, easing: "ease-in-out"),
        LinkPulse(name: "Swell", summary: "Steady grey, its edge 2 ↔ 5 pt out, 0.8 s each way",
                  keys: [key(0, 0.08, width: 2), key(1, 0.08, width: 5)], duration: 0.8, easing: "ease-in-out", alternates: true),
        LinkPulse(name: "Bloom", summary: "Brighter and tight, opening out as it fades, 1.1 s",
                  keys: [key(0, 0.12, width: 2), key(1, 0.05, width: 6)], duration: 1.1, easing: "ease-out"),
        LinkPulse(name: "Ripple", summary: "Soft fill, a ring running out to 8 pt and gone, 1.2 s",
                  keys: [key(0, 0.06, ring: 0.12, width: 1), key(1, 0.06, ring: 0, width: 8)], duration: 1.2, easing: "ease-out"),
        LinkPulse(name: "Halo", summary: "Steady fill, a ring out to 6 pt fading in and out, 1 s each way",
                  keys: [key(0, 0.08, ring: 0.08, width: 3), key(1, 0.08, ring: 0, width: 6)], duration: 1, easing: "ease-in-out", alternates: true),
        LinkPulse(name: "Glow", summary: "Steady fill, its 4 pt edge brightening, 0.9 s each way",
                  keys: [key(0, 0.07, ring: 0.02, width: 4), key(1, 0.07, ring: 0.12, width: 4)], duration: 0.9, easing: "ease-in-out", alternates: true),
        LinkPulse(name: "Pop", summary: "A quick swell, brighter and wider, then back, 0.5 s",
                  keys: [key(0, 0.09, width: 3), key(0.3, 0.12, width: 5), key(1, 0.09, width: 3)], duration: 0.5, easing: "ease-out"),
    ]
    static let preferenceKey = "LinkPulse"
    static var selected: LinkPulse {
        let name = UserDefaults.standard.string(forKey: preferenceKey)
        return presets.first { $0.name == name } ?? presets[0]
    }
    static func select(_ pulse: LinkPulse) { UserDefaults.standard.set(pulse.name, forKey: preferenceKey) }

    /// As the page script takes it.
    var script: [String: Any] {
        ["keys": keys.map { [$0.at, $0.fill, $0.ring, $0.width] }, "duration": duration*1000, "easing": easing, "alternates": alternates]
    }
}

/// The link a card is for, lit in the page: a rounded light grey over it, one block across the
/// lines it wraps onto, pulsing while its card is on the way and steady once it shows.
@MainActor extension BrowserController {
    enum LinkHighlight: String { case pulsing = "pulse", steady, off }

    /// Lights the link under the pointer in `web` (`pulsing`), or changes or ends the one that's
    /// lit. `again` plays the pulse over on the lit link, wherever the pointer is.
    func setLinkHighlight(_ state: LinkHighlight, in web: NSView?, again: Bool = false) {
        let links = linkPullRequests
        if state != .off, let lit = links.highlightedWeb, lit !== web { setLinkHighlight(.off, in: lit) }
        guard let web, let page = page(showing: web) else { return }
        if state == .off { guard links.highlightedWeb === web else { return }; links.highlightedWeb = nil }
        else { links.highlightedWeb = web }
        // While the tester is on, it pulses on with its card open, to be watched.
        let state = state == .steady && LinkPulseTester.shared.isOn ? .pulsing : state
        var arguments: [String: Any] = ["state": state.rawValue, "x": NSNull(), "y": NSNull(), "pulse": LinkPulse.selected.script,
                                        "steady": [LinkPulse.steady.fill, LinkPulse.steady.width], "sidePerSize": LinkPulse.sidePerSize]
        // Pulsing starts on whatever link is under the pointer now.
        if state == .pulsing, !again, let window = web.window {
            let zoom = max(0.01, page.zoom)
            var point = web.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if !web.isFlipped { point.y = web.bounds.height-point.y }
            arguments["x"] = point.x/zoom; arguments["y"] = point.y/zoom
        }
        Task { _ = await page.evaluate(Self.linkHighlightScript, arguments: arguments, world: Self.linkHighlightWorld) }
    }
    static let linkHighlightWorld = "Rise.LinkHighlight"

    /// Settings ▸ Appearance: whether a link's grey breathes while its card comes, for a summary
    /// (⌥) and for a pull or merge request, each on its own.
    static let highlightsSummaryLinksKey = "Rise.HighlightSummaryLinks", highlightsPullRequestLinksKey = "Rise.HighlightPullRequestLinks"
    var highlightsSummaryLinks: Bool { preferences.object(forKey: Self.highlightsSummaryLinksKey) as? Bool ?? true }
    var highlightsPullRequestLinks: Bool { preferences.object(forKey: Self.highlightsPullRequestLinksKey) as? Bool ?? true }
    func setHighlightsSummaryLinks(_ value: Bool) { preferences.set(value, forKey: Self.highlightsSummaryLinksKey) }
    func setHighlightsPullRequestLinks(_ value: Bool) { preferences.set(value, forKey: Self.highlightsPullRequestLinksKey) }
    /// Settings ▸ Appearance: GitHub shows its own card for its pull requests' links, so Rise's
    /// can wait for Option there. Off unless chosen.
    static let gitHubLinkCardsNeedOptionKey = "Rise.GitHubLinkCardsNeedOption"
    var gitHubLinkCardsNeedOption: Bool { preferences.bool(forKey: Self.gitHubLinkCardsNeedOptionKey) }
    func setGitHubLinkCardsNeedOption(_ value: Bool) { preferences.set(value, forKey: Self.gitHubLinkCardsNeedOptionKey) }
    func highlightsLink(for subject: LinkPullRequestCards.Subject) -> Bool {
        subject.pullRequest == nil ? highlightsSummaryLinks : highlightsPullRequestLinks
    }
    /// Lights the link a card is for, unless that kind of link is set not to be; then whatever's lit goes.
    func lightLink(_ state: LinkHighlight, for subject: LinkPullRequestCards.Subject, in web: NSView) {
        guard highlightsLink(for: subject) else { setLinkHighlight(.off, in: linkPullRequests.highlightedWeb); return }
        setLinkHighlight(state, in: web)
    }

    /// Drawn over the page in a layer of Rise's own, which follows the link every frame: a rounded
    /// grey around each line, reaching further at its sides with the size of its text, and a ring
    /// round that. Lines that share some width meet halfway across the space between them, one
    /// block with rounded outer corners. The page itself is never changed.
    static let linkHighlightScript = """
    const key = '__riseLinkHighlight', current = window[key], svg = 'http://www.w3.org/2000/svg', radius = 5;
    const shown = (h) => { const fill = getComputedStyle(h.fill), ring = getComputedStyle(h.ring);
      return { fill: fill.fill, stroke: ring.stroke, strokeWidth: ring.strokeWidth }; };
    const stop = (h) => { for (const anim of h.anims) anim.cancel(); h.anims = []; };
    const end = (h) => {
      const from = shown(h);
      stop(h);
      const timing = { duration: 180, easing: 'ease-out', fill: 'forwards' };
      const out = h.fill.animate([{ fill: from.fill }, { fill: h.color(0) }], timing);
      h.anims = [out, h.ring.animate([{ stroke: from.stroke }, { stroke: h.color(0) }], timing)];
      out.onfinish = () => { cancelAnimationFrame(h.frame); h.host.remove(); };
    };
    if (state === 'off') { if (current) { end(current); window[key] = null; } return true; }
    let node = null;
    if (x !== null) {
      node = document.elementFromPoint(x, y);
      while (node?.shadowRoot) {
        const inner = node.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === node) break;
        node = inner;
      }
      while (node && !node.matches?.('a[href], area[href]')) node = node.parentElement ?? node.getRootNode?.()?.host ?? null;
    } else node = current?.el ?? null;
    if (!node) { if (current) { end(current); window[key] = null; } return false; }
    if (current && current.el !== node) { end(current); window[key] = null; }

    // The link's lines, each line's pieces as one, wider at the sides, top to bottom, grouped
    // where they share some width and lie close, a group's lines meeting halfway between.
    const groups = (h) => {
      const lines = [];
      for (const r of h.el.getClientRects()) {
        if (r.width < 0.5 || r.height < 0.5) continue;
        const line = lines.find(l => r.top < l.bottom - 1 && r.bottom > l.top + 1);
        if (line) Object.assign(line, { left: Math.min(line.left, r.left), right: Math.max(line.right, r.right),
                                        top: Math.min(line.top, r.top), bottom: Math.max(line.bottom, r.bottom) });
        else lines.push({ left: r.left, right: r.right, top: r.top, bottom: r.bottom });
      }
      lines.sort((a, b) => a.top - b.top);
      const found = [];
      for (const line of lines) {
        line.left -= h.side; line.right += h.side;
        const group = found.at(-1), last = group?.at(-1);
        if (last && line.left < last.right && line.right > last.left && line.top - last.bottom < h.join) {
          last.bottom = line.top = (last.bottom + line.top) / 2; group.push(line);
        } else found.push([line]);
      }
      return found;
    };
    // Round a group: down its right side, back up its left, without repeated points or ones
    // along a straight edge.
    const corners = (group) => {
      let points = [];
      for (const l of group) points.push([l.right, l.top], [l.right, l.bottom]);
      for (const l of [...group].reverse()) points.push([l.left, l.bottom], [l.left, l.top]);
      const same = (a, b) => Math.abs(a - b) < 0.01;
      for (let changed = true; changed && points.length > 3;) {
        changed = false;
        for (let i = 0; i < points.length; i++) {
          const a = points[(i + points.length - 1) % points.length], b = points[i], c = points[(i + 1) % points.length];
          if ((same(a[0], b[0]) && same(a[1], b[1])) || (same(a[0], b[0]) && same(b[0], c[0])) || (same(a[1], b[1]) && same(b[1], c[1]))) {
            points.splice(i, 1); changed = true; break;
          }
        }
      }
      return points;
    };
    // Its outline with each corner rounded, an inner one too, as far as its edges allow.
    const outline = (points, ox, oy) => {
      let d = '';
      points.forEach((v, i) => {
        const p = points[(i + points.length - 1) % points.length], q = points[(i + 1) % points.length];
        const d1 = Math.hypot(p[0] - v[0], p[1] - v[1]), d2 = Math.hypot(q[0] - v[0], q[1] - v[1]);
        const r = Math.min(radius, d1 / 2, d2 / 2), k = 0.5523;
        const a = [v[0] + (p[0] - v[0]) / d1 * r, v[1] + (p[1] - v[1]) / d1 * r], b = [v[0] + (q[0] - v[0]) / d2 * r, v[1] + (q[1] - v[1]) / d2 * r];
        const at = (point) => `${(point[0] - ox).toFixed(2)} ${(point[1] - oy).toFixed(2)}`;
        d += `${i ? 'L' : 'M'}${at(a)}C${at([a[0] + (v[0] - a[0]) * k, a[1] + (v[1] - a[1]) * k])} ${at([b[0] + (v[0] - b[0]) * k, b[1] + (v[1] - b[1]) * k])} ${at(b)}`;
      });
      return d + 'Z';
    };
    // Each frame, where the link is now, as it scrolls or the page moves it.
    const place = (h) => {
      if (!h.el.isConnected) { if (window[key] === h) window[key] = null; end(h); return; }
      const origin = h.host.getBoundingClientRect();
      const d = groups(h).map(group => outline(corners(group), origin.left, origin.top)).join('');
      if (d !== h.d) { h.d = d; for (const path of [h.fill, h.ring, h.hole]) path.setAttribute('d', d); }
      h.frame = requestAnimationFrame(() => place(h));
    };

    let h = window[key];
    if (!h) {
      // The colour behind the link, from the nearest box that paints one, or the page's canvas.
      let behind = null;
      for (let at = node; at && !behind; at = at.parentElement ?? at.getRootNode?.()?.host ?? null) {
        const parts = (getComputedStyle(at).backgroundColor.match(/[\\d.]+/g) || []).map(Number);
        if (parts.length >= 3 && (parts.length < 4 || parts[3] > 0.5)) behind = parts;
      }
      if (!behind) behind = matchMedia('(prefers-color-scheme: dark)').matches && /dark/.test(getComputedStyle(document.documentElement).colorScheme) ? [18, 18, 18] : [255, 255, 255];
      const dark = (0.2126 * behind[0] + 0.7152 * behind[1] + 0.0722 * behind[2]) / 255 < 0.45;
      // Its sides reach further with the size of its text, the largest in it, as a heading's in its link.
      const px = (value) => parseFloat(value) || 0;
      let size = 0;
      const texts = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
      for (let text, count = 0; (text = texts.nextNode()) && count < 60; count++) {
        if (text.data.trim() && text.parentElement) size = Math.max(size, px(getComputedStyle(text.parentElement).fontSize));
      }
      size = size || px(getComputedStyle(node).fontSize) || 16;
      // A layer of its own over the page, which the page's styles and pointer never reach.
      const host = document.createElement('rise-link-highlight');
      host.style.cssText = 'all: initial !important; display: block !important; position: fixed !important; inset: 0 !important; z-index: 2147483647 !important; pointer-events: none !important; contain: strict !important';
      const draw = document.createElementNS(svg, 'svg');
      draw.setAttribute('style', 'position: absolute; inset: 0; width: 100%; height: 100%; overflow: visible; pointer-events: none');
      const make = (name, attributes) => { const element = document.createElementNS(svg, name); for (const [n, v] of Object.entries(attributes)) element.setAttribute(n, v); return element; };
      // The ring shows only outside the fill, so where they meet isn't doubled.
      const id = `rise-link-highlight-${Math.random().toString(36).slice(2)}`;
      const mask = make('mask', { id, maskUnits: 'userSpaceOnUse', x: -20000, y: -20000, width: 40000, height: 40000 });
      const hole = make('path', { fill: 'black' });
      mask.append(make('rect', { x: -20000, y: -20000, width: 40000, height: 40000, fill: 'white' }), hole);
      const ring = make('path', { mask: `url(#${id})`, style: 'fill: none; stroke: rgba(0, 0, 0, 0); stroke-width: 6px; stroke-linejoin: round' });
      const fill = make('path', { style: 'fill: rgba(0, 0, 0, 0); stroke: none' });
      draw.append(mask, ring, fill);
      host.attachShadow({ mode: 'closed' }).append(draw);
      document.documentElement.append(host);
      h = { el: node, host, fill, ring, hole, anims: [], side: Math.round(size * sidePerSize * 10) / 10, join: Math.max(8, size * 0.6),
            // A light tint on a dark page, a little stronger; a grey one elsewhere.
            color: (alpha) => dark ? `rgba(255, 255, 255, ${Math.min(1, alpha * 1.4)})` : `rgba(0, 0, 0, ${alpha})` };
      window[key] = h;
      place(h);
    }
    // From wherever it shows now: in to the loop's start, then round it, or settling.
    const now = shown(h);
    stop(h);
    const into = (fill, ring, width, duration) => {
      const timing = { duration, easing: 'ease-out', fill: 'forwards' };
      h.anims.push(h.fill.animate([{ fill: now.fill }, { fill: h.color(fill) }], timing),
                   h.ring.animate([{ stroke: now.stroke, strokeWidth: now.strokeWidth }, { stroke: h.color(ring), strokeWidth: `${width * 2}px` }], timing));
    };
    if (state === 'pulse') {
      const [, fill, ring, width] = pulse.keys[0];
      into(fill, ring, width, 200);
      const timing = { duration: pulse.duration, delay: 200, easing: pulse.easing, iterations: Infinity, direction: pulse.alternates ? 'alternate' : 'normal' };
      h.anims.push(h.fill.animate(pulse.keys.map(([offset, fill]) => ({ offset, fill: h.color(fill) })), timing),
                   h.ring.animate(pulse.keys.map(([offset, , ring, width]) => ({ offset, stroke: h.color(ring), strokeWidth: `${width * 2}px` })), timing));
    } else {
      into(steady[0], steady[0], steady[1], 220);
    }
    return true;
    """
}

/// Develop ▸ Link Pulse Tester: a label at the bottom of the window names the pulse in use, and
/// ← and → flick through them, playing the lit link's pulse over. While it's on, a link pulses on
/// with its card open, to be watched.
@MainActor final class LinkPulseTester {
    static let shared = LinkPulseTester()
    private weak var browser: BrowserController?
    private var monitor: Any?
    let label = CardMotionLabel()
    var isOn: Bool { monitor != nil }

    func toggle(in browser: BrowserController) {
        if isOn { stop(); return }
        self.browser = browser
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handles(event) else { return event }
            self.step(event.keyCode == 123 ? -1 : 1)
            return nil
        }
        browser.root.addSubview(label, positioned: .below, relativeTo: browser.dismissArea)
        refresh()
        replay()
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; label.removeFromSuperview()
        // A card that's open has its link steady again.
        if let browser, browser.linkPullRequests.shown != nil { browser.setLinkHighlight(.steady, in: browser.linkPullRequests.highlightedWeb) }
    }
    /// ← and → on their own, in the tester's window, whatever has the keyboard there.
    func handles(_ event: NSEvent) -> Bool {
        guard isOn, event.keyCode == 123 || event.keyCode == 124, event.window === browser?.window else { return false }
        return event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
    func step(_ delta: Int) {
        let presets = LinkPulse.presets, index = presets.firstIndex(of: LinkPulse.selected) ?? 0
        LinkPulse.select(presets[(index+delta+presets.count)%presets.count])
        refresh(); replay()
    }
    private func replay() {
        guard let browser, let web = browser.linkPullRequests.highlightedWeb else { return }
        browser.setLinkHighlight(.pulsing, in: web, again: true)
    }
    private func refresh() {
        guard let browser else { return }
        let presets = LinkPulse.presets, pulse = LinkPulse.selected
        label.show(title: "←  \((presets.firstIndex(of: pulse) ?? 0)+1) of \(presets.count) · \(pulse.name)  →", detail: pulse.summary,
                   footer: "Hold ⌥ on a link, or rest on a pull request's", theme: browser.theme)
        let size = label.fittingSize, bounds = browser.root.bounds
        label.frame = NSRect(x: round(bounds.midX-size.width/2), y: bounds.maxY-size.height-16, width: size.width, height: size.height)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
    }
}

@MainActor extension BrowserController {
    @objc func toggleLinkPulseTester() { LinkPulseTester.shared.toggle(in: self) }
}
