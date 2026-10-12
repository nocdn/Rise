import WebKit

/// Find on page, run inside the page so every match can be highlighted (CSS Custom
/// Highlights), counted and stepped through like a browser's own find. `WKWebView.find`
/// only selects one match at a time and can't count, so it remains just a fallback for
/// WebKit builds without `Highlight`. The model's passage highlights use the same styling.
@MainActor enum PageFind {
    /// `refresh` repaints the current search without stepping or scrolling, unless the page changed.
    enum Direction: String { case restart, next, previous, refresh }
    /// `index` is zero-based; `count` is nil when only the fallback could search.
    struct Matches: Equatable { let count: Int?, index: Int }

    /// An isolated world keeps the page's own scripts from seeing or breaking the finder.
    static let world = WKContentWorld.world(name: "RiseFind")
    static let worldName = "RiseFind"
    /// Pages where the native fallback ran; WebKit marks its matches, and only a search that
    /// matches nothing clears them (an empty one doesn't).
    private static let nativelyMarked = NSHashTable<WKWebView>.weakObjects()

    static func find(_ query: String, direction: Direction, in page: WebPage) async -> Matches {
        switch await call("return __riseFind.find(query, direction)", ["query": query, "direction": direction.rawValue], in: page) {
        case .success(let result as [String: Any]):
            if let count = result["count"] as? Int, let index = result["index"] as? Int { return Matches(count: count, index: index) }
            return Matches(count: nil, index: -1)
        case .success:
            // Only a page that can't draw highlights at all searches natively.
            return await findNatively(query, backwards: direction == .previous, in: page)
        case .failure:
            // A page mid-navigation can reject the call. Falling back here would leave native
            // marks the in-page finder knows nothing about, so report the count as unknown instead.
            return Matches(count: nil, index: -1)
        }
    }
    /// Use the finder's own text extraction for model context so verbatim snippets map to
    /// the same DOM nodes, including around inline links and hidden accessibility labels.
    static func visibleText(in page: WebPage) async -> String? {
        if case .success(let text as String) = await call("return __riseFind.sourceText()", [:], in: page) { return text }
        return nil
    }
    /// Removes the find highlights and, on closing, selects the current match as browsers do.
    static func clear(_ page: WebPage, selectingCurrent: Bool) async {
        await clearNativeMarks(page)
        _ = await call("return __riseFind.clear(select)", ["select": selectingCurrent], in: page)
    }
    /// Highlights the first occurrence of `quote` and scrolls to it; false when it isn't on the page.
    static func highlightPassage(_ quote: String, in page: WebPage) async -> Bool {
        switch await call("return __riseFind.passage(quote)", ["quote": quote], in: page) {
        case .success(let found as Bool): return found
        case .success: return await findNatively(quote, backwards: false, in: page).index >= 0
        case .failure: return false
        }
    }
    static func clearPassage(_ page: WebPage) async {
        await clearNativeMarks(page)
        _ = await call("return __riseFind.passage('')", [:], in: page)
    }

    /// Only WebKit lacks highlights in some builds; Chromium always has them.
    private static func findNatively(_ query: String, backwards: Bool, in page: WebPage) async -> Matches {
        guard let webView = (page as? WebKitPage)?.webView else { return Matches(count: nil, index: -1) }
        guard !query.isEmpty else { await clearNativeMarks(page); return Matches(count: 0, index: -1) }
        nativelyMarked.add(webView)
        let configuration = WKFindConfiguration(); configuration.backwards = backwards; configuration.wraps = true
        let found = (try? await webView.find(query, configuration: configuration))?.matchFound ?? false
        return Matches(count: found ? nil : 0, index: found ? 0 : -1)
    }
    private static func clearNativeMarks(_ page: WebPage) async {
        guard let webView = (page as? WebKitPage)?.webView, nativelyMarked.contains(webView) else { return }
        nativelyMarked.remove(webView)
        let configuration = WKFindConfiguration(); configuration.wraps = true
        _ = try? await webView.find("\u{1}\u{2}\u{1}", configuration: configuration)
    }
    private static func call(_ body: String, _ arguments: [String: Any], in page: WebPage) async -> Result<Any?, Error> {
        do { return .success(try await page.evaluate(script+"\n"+body, arguments: arguments, in: nil, world: .named(worldName))) }
        catch { return .failure(error) }
    }

    /// Defines `__riseFind` once per page in the find world. Text nodes are flattened into one
    /// lowercased string with whitespace collapsed, a space between blocks (as `innerText`
    /// has, so quotes copied from it still match), and curly quotes and dashes folded, with a
    /// map back to each node and offset so matches become DOM ranges.
    static let script = #"""
    if (!globalThis.__riseFind) globalThis.__riseFind = (() => {
      const MAX = 1000, SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'IFRAME', 'OBJECT', 'SELECT', 'TEXTAREA', 'INPUT']);
      const supported = typeof Highlight === 'function' && globalThis.CSS && CSS.highlights;
      let state = { query: null, ranges: [], index: -1 };
      const fold = c => c === '‘' || c === '’' ? "'" : c === '“' || c === '”' ? '"'
        : c === '–' || c === '—' ? '-' : c.toLowerCase()[0];
      // UTF-16 units, like the node map in collect().
      const normalize = s => { let out = ''; for (let i = 0; i < s.length; i++) { const c = s[i]; if (/\s/.test(c)) { if (!out.endsWith(' ')) out += ' ' } else out += fold(c) } return out };
      // WebKit doesn't repaint text that a highlight stops covering when a Highlight is replaced
      // or deleted, so old matches stayed painted (until a selection happened to redraw them).
      // Each kind keeps one Highlight that is edited in place, and every change restyles the
      // rules by one color unit, which forces the highlighted text to repaint.
      let flip = false;
      const rules = () => {
        const find = flip ? '#FFE55D' : '#FFE55C', current = flip ? '#FF9633' : '#FF9632';
        return `::highlight(rise-find){background-color:${find};color:#000}`
          + `::highlight(rise-find-current){background-color:${current};color:#000}`
          + `::highlight(rise-passage){background-color:${find};color:#000}`;
      };
      function style() {
        if (globalThis.__riseFindSheet) return;
        // A constructed sheet isn't subject to the page's style-src policy, unlike a <style> element.
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(rules());
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        globalThis.__riseFindSheet = sheet;
      }
      function repaint() { style(); flip = !flip; globalThis.__riseFindSheet.replaceSync(rules()) }
      const marks = {};
      function mark(name) {
        let highlight = marks[name];
        if (!highlight || CSS.highlights.get(name) !== highlight) { highlight = new Highlight(); marks[name] = highlight; CSS.highlights.set(name, highlight) }
        return highlight;
      }
      function collect() {
        const nodes = [], at = [], offsets = [], blocks = new Map();
        // `context` is `source` plus text the find can't highlight, for the page assistant.
        let text = '', source = '', context = '', lastBlock = null;
        const blockOf = element => {
          for (let e = element; e && e !== document.body; e = e.parentElement) {
            let block = blocks.get(e);
            if (block === undefined) { const display = getComputedStyle(e).display; block = !(display.startsWith('inline') || display === 'contents'); blocks.set(e, block) }
            if (block) return e;
          }
          return document.body;
        };
        const space = () => { if (nodes.length && text.length && !text.endsWith(' ')) { text += ' '; source += ' '; context += ' '; at.push(nodes.length-1); offsets.push(nodes[nodes.length-1].length) } };
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            if (node.nodeType === Node.TEXT_NODE) return NodeFilter.FILTER_ACCEPT;
            // GitHub's file view draws each code line from an attribute, so the lines hold no
            // text; the whole file is in a transparent read-only text area over them.
            if (node.tagName === 'TEXTAREA' && (node.readOnly || node.getAttribute('aria-readonly') === 'true') && node.value.trim()
                && (!node.checkVisibility || node.checkVisibility({ visibilityProperty: true }))) context += '\n'+node.value+'\n';
            if (SKIP.has(node.tagName)) return NodeFilter.FILTER_REJECT;
            // Clipped screen-reader labels are in innerText but aren't visible passages.
            const style = getComputedStyle(node);
            if (style.clip.replace(/\s/g, '') === 'rect(0px,0px,0px,0px)' || style.clipPath === 'inset(50%)') return NodeFilter.FILTER_REJECT;
            if (node.tagName === 'BR') return NodeFilter.FILTER_ACCEPT;
            // A display: contents wrapper has no box, so checkVisibility calls it hidden; its children are checked themselves.
            if (style.display === 'contents') return NodeFilter.FILTER_SKIP;
            if (node.checkVisibility && !node.checkVisibility({ visibilityProperty: true })) return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_SKIP;
          }
        });
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (node.nodeType !== Node.TEXT_NODE) { space(); continue }
          const parent = node.parentElement;
          const block = blockOf(parent);
          if (block !== lastBlock) { space(); lastBlock = block }
          const value = node.data;
          if (!value) continue;
          nodes.push(node);
          for (let i = 0; i < value.length; i++) {
            const c = value[i];
            if (/\s/.test(c)) { if (text.length && !text.endsWith(' ')) { text += ' '; source += ' '; context += ' '; at.push(nodes.length-1); offsets.push(i) } }
            else { text += fold(c); source += c; context += c; at.push(nodes.length-1); offsets.push(i) }
          }
        }
        return { text, source, context, range(start, end) {
          const range = document.createRange();
          const first = nodes[at[start]], last = nodes[at[end-1]];
          range.setStart(first, Math.min(offsets[start], first.length));
          range.setEnd(last, Math.min(offsets[end-1]+1, last.length));
          return range;
        } };
      }
      function reveal(range, smooth) {
        const rect = range.getBoundingClientRect(), margin = 60;
        if (rect.top >= margin && rect.bottom <= innerHeight-margin && rect.left >= 0 && rect.right <= innerWidth) return;
        const element = range.startContainer.parentElement;
        if (element) element.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
        const after = range.getBoundingClientRect();
        scrollBy({ top: after.top+after.height/2-innerHeight/2, behavior: smooth ? 'smooth' : 'instant' });
      }
      function paint() {
        const { ranges, index } = state, others = mark('rise-find'), current = mark('rise-find-current');
        others.clear(); current.clear();
        ranges.forEach((range, i) => (i === index ? current : others).add(range));
        current.priority = 1;
        repaint();
      }
      function search(query) {
        state = { query, ranges: [], index: -1 };
        const needle = normalize(query);
        if (!needle.trim()) return;
        const { text, range } = collect();
        for (let from = 0; state.ranges.length < MAX;) {
          const i = text.indexOf(needle, from);
          if (i < 0) break;
          state.ranges.push(range(i, i+needle.length)); from = i+needle.length;
        }
        // Start from the first match on screen or below it, like typing into a browser's find.
        state.index = state.ranges.length ? Math.max(0, state.ranges.findIndex(r => r.getBoundingClientRect().bottom >= 0)) : -1;
      }
      const stale = () => state.ranges.some(r => !r.startContainer.isConnected || !r.endContainer.isConnected);
      return {
        sourceText() { return collect().context },
        find(query, direction) {
          if (!supported) return null;
          style();
          const reveals = direction !== 'refresh';
          if (direction === 'restart' || query !== state.query || stale()) {
            search(query);
          } else if (state.ranges.length && direction !== 'refresh') {
            const count = state.ranges.length;
            state.index = (state.index+(direction === 'previous' ? -1 : 1)+count) % count;
          }
          paint();
          if (state.index >= 0 && reveals) reveal(state.ranges[state.index], false);
          return { count: state.ranges.length, index: state.index };
        },
        clear(select) {
          if (!supported) return null;
          const current = state.ranges[state.index];
          if (select && current && current.startContainer.isConnected) { const selection = getSelection(); selection.removeAllRanges(); selection.addRange(current) }
          mark('rise-find').clear(); mark('rise-find-current').clear(); repaint();
          state = { query: null, ranges: [], index: -1 };
          return true;
        },
        passage(quote) {
          if (!supported) return null;
          const passage = mark('rise-passage');
          passage.clear(); repaint();
          // Models often add or drop surrounding quotes and closing punctuation.
          const trimmed = normalize(quote).trim(), loose = trimmed.replace(/^["']+/, '').replace(/["'.,;:!?…]+$/, '');
          if (!loose) return false;
          const { text, range } = collect();
          let start = text.indexOf(trimmed), length = trimmed.length;
          if (start < 0) { start = text.indexOf(loose); length = loose.length }
          if (start < 0) return false;
          const found = range(start, start+length);
          passage.add(found); repaint();
          reveal(found, true);
          return true;
        }
      };
    })();
    """#
}
