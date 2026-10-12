import AppKit
import WebKit
import os

/// Passes the fullscreen script's notes to the system log, while simulated fullscreen is new.
private final class PageFullscreenLogBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        PageFullscreen.log.notice("\(String(text.prefix(600)), privacy: .public)")
    }
}

@MainActor private final class PageFullscreenStateBridge: NSObject, WKScriptMessageHandler {
    weak var owner: PageFullscreen?
    init(_ owner: PageFullscreen) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let web = message.webView, let active = message.body as? Bool else { return }
        owner?.setActive(active, in: web)
    }
}

/// A page's fullscreen request, either WebKit's own (a separate Space with the macOS
/// animation) or simulated: the element is lifted over the page in the window, the way
/// players without the Fullscreen API cover the viewport themselves. Simulated
/// fullscreen falls back to WebKit's whenever the element can't be shown that way.
@MainActor final class PageFullscreen {
    nonisolated static let log = Logger(subsystem: "Rise", category: "Fullscreen")
    static let simulatedKey = "Rise.SimulatedFullScreen"
    static let logHandler = "riseFullscreenLog"
    static let stateHandler = "riseFullscreenState"
    private let preferences: UserDefaults
    private var controllers = NSHashTable<WKUserContentController>.weakObjects()
    /// Pages, as their views, whose element is simulated full screen.
    private let activeWebViews = NSHashTable<NSView>.weakObjects()
    /// Chromium pages, whose script is swapped when the mode changes.
    private let scriptedPages = NSHashTable<AnyObject>.weakObjects()
    private(set) var isSimulated: Bool
    var onChange: (() -> Void)?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        isSimulated = preferences.bool(forKey: Self.simulatedKey)
    }

    func install(on page: WebPage) {
        guard let web = (page as? WebKitPage)?.webView else {
            scriptedPages.add(page)
            page.addMessageHandler(Self.logHandler, world: .page) { message in
                if let text = message.body as? String { Self.log.notice("\(String(text.prefix(600)), privacy: .public)") }
            }
            page.addMessageHandler(Self.stateHandler, world: .page) { [weak self] message in
                guard message.frame.isMain, let active = message.body as? Bool, let view = message.page?.view else { return }
                self?.setActive(active, in: view)
            }
            installScript(on: page)
            return
        }
        install(on: web)
    }
    private func installScript(on page: WebPage) {
        page.addUserScript(Self.script(simulated: isSimulated), world: .page, mainFrameOnly: false, handlers: [Self.logHandler, Self.stateHandler])
    }
    func install(on web: WKWebView) {
        let content = web.configuration.userContentController
        guard !controllers.contains(content) else { return }
        controllers.add(content)
        content.add(PageFullscreenLogBridge(), contentWorld: .page, name: Self.logHandler)
        content.add(PageFullscreenStateBridge(self), contentWorld: .page, name: Self.stateHandler)
        content.addUserScript(Self.userScript(simulated: isSimulated))
    }

    func isActive(in web: NSView) -> Bool { activeWebViews.contains(web) }

    func setActive(_ active: Bool, in web: NSView) {
        let active = active && isSimulated
        guard active != isActive(in: web) else { return }
        if active { activeWebViews.add(web) } else { activeWebViews.remove(web) }
        onChange?()
    }

    /// Saves the choice, loads later pages with it and switches pages already open,
    /// including one that is fullscreen right now.
    func setSimulated(_ value: Bool, in pages: [WebPage]) {
        isSimulated = value
        preferences.set(value, forKey: Self.simulatedKey)
        if !value { activeWebViews.removeAllObjects() }
        onChange?()
        Self.log.notice("Simulated fullscreen \(value ? "on" : "off", privacy: .public)")
        for content in controllers.allObjects {
            let others = content.userScripts.filter { !$0.source.hasPrefix(Self.marker) }
            content.removeAllUserScripts()
            others.forEach(content.addUserScript)
            content.addUserScript(Self.userScript(simulated: value))
        }
        #if RISE_CHROMIUM
        for case let page as ChromiumPage in scriptedPages.allObjects {
            page.browserView.removeUserScripts(withPrefix: Self.marker)
            installScript(on: page)
        }
        #endif
        for page in pages {
            page.evaluate("window.__riseFullscreen?.setMode(mode)", arguments: ["mode": value], in: nil, world: .page) { _ in }
        }
    }

    static func userScript(simulated: Bool) -> WKUserScript {
        WKUserScript(source: script(simulated: simulated), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }
    static func script(simulated: Bool) -> String {
        marker + "\n" + source.replacingOccurrences(of: "__RISE_SIMULATED__", with: simulated ? "true" : "false")
    }
    private static let marker = "// Rise page fullscreen"

    /// Overrides the Fullscreen API in every frame. A simulated request puts the element in
    /// the top layer as a manual popover, so no ancestor's transform, clip or z-index can
    /// hold it back, and styles it as the UA styles `:fullscreen`. The page's own
    /// `:fullscreen` rules are copied to an attribute selector, since only real fullscreen
    /// matches the pseudo-class. A frame asks its parent to lift the frame element too.
    /// Anything that goes wrong while the user's click still counts falls back to WebKit.
    static let source = #"""
    (() => {
      const KEY = '__riseFullscreen', MSG = '__riseFullscreen';
      if (Object.prototype.hasOwnProperty.call(window, KEY)) return;
      let simulated = __RISE_SIMULATED__;
      const isTop = window === window.top;
      // Rise's handlers: WebKit's own, or those Chromium's pages get from Rise's script wrapper.
      const handlers = typeof riseHandlers !== 'undefined' ? riseHandlers : window.webkit?.messageHandlers;
      const handler = handlers?.riseFullscreenLog;
      const log = (...parts) => {
        try { handler?.postMessage(`[${isTop ? 'top' : 'frame'} ${location.host || location.protocol}] ` + parts.map(String).join(' ')); } catch {}
      };
      const E = Element.prototype, D = Document.prototype, H = HTMLElement.prototype;
      const S = window.ShadowRoot?.prototype, V = window.HTMLVideoElement?.prototype;
      const getter = (proto, name) => proto ? Object.getOwnPropertyDescriptor(proto, name)?.get : undefined;
      const native = {
        request: E.requestFullscreen, webkitRequest: E.webkitRequestFullscreen, webkitRequestOld: E.webkitRequestFullScreen,
        exit: D.exitFullscreen, webkitExit: D.webkitExitFullscreen, webkitCancel: D.webkitCancelFullScreen,
        element: getter(D, 'fullscreenElement'), webkitElement: getter(D, 'webkitFullscreenElement'),
        webkitCurrent: getter(D, 'webkitCurrentFullScreenElement'), fullscreen: getter(D, 'fullscreen'),
        webkitIsFullScreen: getter(D, 'webkitIsFullScreen'), enabled: getter(D, 'fullscreenEnabled'),
        shadowElement: getter(S, 'fullscreenElement'),
        videoEnter: V?.webkitEnterFullscreen, videoExit: V?.webkitExitFullscreen,
        videoDisplaying: getter(V, 'webkitDisplayingFullscreen'),
        showPopover: H.showPopover, hidePopover: H.hidePopover,
      };
      const call = (fn, self, args) => fn ? fn.apply(self, args) : undefined;
      const nativeElement = () => { try { return native.element ? native.element.call(document) : null; } catch { return null; } };
      const describe = el => {
        if (!el || !el.tagName) return String(el);
        const cls = typeof el.className === 'string' && el.className.trim() ? '.' + el.className.trim().split(/\s+/).slice(0, 3).join('.') : '';
        return el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + cls;
      };
      const isFrame = el => el instanceof HTMLIFrameElement || el?.tagName === 'FRAME';

      // State: the element this document shows fullscreen, its own or the frame of a child that asked.
      let active = null;
      // Only the top document reports state: it also lifts embedded fullscreen players.
      // Coalesce element replacements so the sidebar doesn't reopen between them.
      let stateReportPending = false;
      const reportState = () => {
        if (!isTop || stateReportPending) return;
        stateReportPending = true;
        queueMicrotask(() => {
          stateReportPending = false;
          try { handlers?.riseFullscreenState?.postMessage(!!active); } catch {}
        });
      };
      const setActive = state => { active = state; reportState(); };
      // A child frame's element shown through WebKit's fullscreen of the frame, after switching modes.
      let nativeChild = null;
      // An element leaving WebKit's fullscreen, to show simulated once it has.
      let pendingSimulated = null;
      let sawUnprefixedRequest = false;

      const frameAfter = fn => {
        let done = false;
        const run = () => { if (!done) { done = true; fn(); } };
        requestAnimationFrame(run); setTimeout(run, 60);
      };
      const fire = (target, type, bubbles = true) => {
        try { target.dispatchEvent(new Event(type, { bubbles, composed: bubbles })); } catch (error) { log('event failed', type, error); }
      };
      const announce = (state, target) => {
        const at = target && target.isConnected ? target : document;
        fire(at, 'fullscreenchange');
        if (state.prefixed) fire(at, 'webkitfullscreenchange');
        if (state.video) fire(state.el, state.entered ? 'webkitbeginfullscreen' : 'webkitendfullscreen', false);
        // Players size a lifted element to the window on resize. The whole page keeps its size, so nothing needs to.
        if (state.el !== document.documentElement) try { window.dispatchEvent(new Event('resize')); } catch {}
      };

      // MARK: Styles

      const PIN = '[data-rise-fullscreen]:not(#rise-fs-a):not(#rise-fs-b)';
      const BASE = `
        ${PIN} {
          position: fixed !important; inset: 0 !important; margin: 0 !important; box-sizing: border-box !important;
          min-width: 0 !important; max-width: none !important; min-height: 0 !important; max-height: none !important;
          width: 100% !important; height: 100% !important; transform: none !important; object-fit: contain;
          translate: none !important; scale: none !important; rotate: none !important;
        }
        iframe${PIN} { border: none !important; padding: 0 !important; }
        :where([data-rise-fullscreen][popover]) {
          border: none; padding: 0; color: inherit; background-color: transparent; overflow: visible; inset: 0;
        }
        :where(video[data-rise-fullscreen]) { background-color: black; }
        :where([data-rise-fullscreen])::backdrop { background: black; }
        :root[data-rise-fullscreen-document]:not([data-rise-fullscreen]) { overflow: hidden !important; }
      `;
      const FULLSCREEN = /:(?:fullscreen|-webkit-full-screen)(?![\w-])/;
      const translate = text => text
        .replace(/:-webkit-full-screen-ancestor(?![\w-])/g, '[data-rise-fullscreen-ancestor]')
        .replace(/:-webkit-full-screen-document(?![\w-])/g, '[data-rise-fullscreen-document]')
        .replace(/:-webkit-full-screen-controls-hidden(?![\w-])/g, '[data-rise-fullscreen-controls-hidden]')
        .replace(/:-webkit-full-screen(?![\w-])/g, '[data-rise-fullscreen]')
        .replace(/:fullscreen(?![\w-])/g, '[data-rise-fullscreen]');
      const copyRules = (rules, out) => {
        for (const rule of rules) {
          try {
            if (rule instanceof CSSStyleRule) {
              const nested = rule.cssRules && rule.cssRules.length;
              if (FULLSCREEN.test(nested ? rule.cssText : rule.selectorText)) out.push(translate(rule.cssText));
            } else if (rule.cssRules && !(rule instanceof CSSImportRule)) {
              const inner = []; copyRules(rule.cssRules, inner);
              if (inner.length) {
                const header = rule instanceof CSSLayerBlockRule ? `@layer ${rule.name}` : rule.cssText.slice(0, rule.cssText.indexOf('{'));
                out.push(`${header} {\n${inner.join('\n')}\n}`);
              }
            } else if (rule instanceof CSSImportRule && rule.styleSheet) {
              copySheet(rule.styleSheet, out);
            }
          } catch {}
        }
      };
      let unreadableSheets = 0;
      const copySheet = (sheet, out) => {
        let rules;
        try { rules = sheet.cssRules; } catch { unreadableSheets++; return; }
        if (rules) copyRules(rules, out);
      };
      const fullscreenRules = root => {
        const out = [];
        for (const sheet of root.styleSheets || []) copySheet(sheet, out);
        for (const sheet of root.adoptedStyleSheets || []) copySheet(sheet, out);
        return out.join('\n');
      };
      const adopt = (root, text) => {
        try {
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(text);
          root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
          return () => { try { root.adoptedStyleSheets = root.adoptedStyleSheets.filter(s => s !== sheet); } catch {} };
        } catch {
          const style = document.createElement('style');
          style.textContent = text;
          (root === document ? document.documentElement : root).appendChild(style);
          return () => style.remove();
        }
      };

      // MARK: Pinning

      const parentAcross = node => node.parentElement || (node.parentNode instanceof ShadowRoot ? node.parentNode.host : null);
      const roots = el => {
        const list = [];
        let root = el.getRootNode();
        while (root instanceof ShadowRoot) { list.push(root); root = root.host.getRootNode(); }
        list.push(document);
        return list;
      };
      const retarget = (el, root) => {
        let node = el;
        while (node) {
          const own = node.getRootNode();
          if (own === root) return node;
          node = own.host || null;
        }
        return null;
      };
      const viewportCovered = el => {
        if (el === document.documentElement) return { ok: true };
        const style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') return { ok: false, why: `display ${style.display}, visibility ${style.visibility}` };
        const r = el.getBoundingClientRect();
        const near = (a, b) => Math.abs(a - b) <= 2;
        const width = [innerWidth, document.documentElement.clientWidth], height = [innerHeight, document.documentElement.clientHeight];
        const ok = near(r.left, 0) && near(r.top, 0) && width.some(w => near(r.width, w)) && height.some(h => near(r.height, h));
        return { ok, why: `rect ${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}x${Math.round(r.height)} in ${innerWidth}x${innerHeight}` };
      };
      // Lifts `el` over the page. Returns the state, or the reason it can't be shown this way.
      const pin = (el, options) => {
        if (!(el instanceof Element)) return 'not an element';
        if (el.ownerDocument !== document) return 'element from another document';
        if (!el.isConnected) return 'element not in the document';
        const html = document.documentElement;
        const state = { el, ...options, ancestors: [], removers: [], topLayer: false, addedPopover: false, addedControls: false, misses: 0, entered: true };
        const undo = () => unpin(state);
        try {
          el.setAttribute('data-rise-fullscreen', '');
          html.setAttribute('data-rise-fullscreen-document', '');
          for (let node = parentAcross(el); node; node = parentAcross(node)) {
            node.setAttribute('data-rise-fullscreen-ancestor', ''); state.ancestors.push(node);
          }
          unreadableSheets = 0;
          const elementRoots = roots(el);
          const started = performance.now();
          elementRoots.forEach((root, index) => {
            const rules = fullscreenRules(root);
            state.removers.push(adopt(root, (index === 0 ? BASE : '') + '\n' + rules));
          });
          if (elementRoots[0] !== document) state.removers.push(adopt(document, BASE));
          log('copied :fullscreen rules in', Math.round(performance.now() - started), 'ms', unreadableSheets ? `(${unreadableSheets} cross-origin sheets unreadable)` : '');
          if (state.video && !el.controls) { el.controls = true; state.addedControls = true; }
          if (el !== html && el instanceof HTMLElement && native.showPopover) {
            if (el.hasAttribute('popover')) log('element is already a popover; pinning without the top layer');
            else {
              try {
                el.setAttribute('popover', 'manual'); state.addedPopover = true;
                native.showPopover.call(el); state.topLayer = el.matches(':popover-open');
              } catch (error) {
                log('top layer refused:', error && error.name);
                el.removeAttribute('popover'); state.addedPopover = false;
              }
            }
          }
          const cover = viewportCovered(el);
          if (!cover.ok) { undo(); return 'does not cover the window: ' + cover.why; }
          return state;
        } catch (error) {
          undo();
          return 'pinning failed: ' + (error && error.message);
        }
      };
      function unpin(state) {
        clearInterval(state.watchdog);
        const { el } = state;
        try { if (state.topLayer && el.matches(':popover-open')) native.hidePopover.call(el); } catch {}
        if (state.addedPopover) el.removeAttribute('popover');
        if (state.addedControls) el.controls = false;
        el.removeAttribute('data-rise-fullscreen');
        state.ancestors.forEach(node => node.removeAttribute('data-rise-fullscreen-ancestor'));
        document.documentElement.removeAttribute('data-rise-fullscreen-document');
        state.removers.forEach(remove => remove());
        state.removers = []; state.ancestors = [];
      }

      // MARK: Frames

      const pending = new Map();
      const askParent = (type, extra = {}) => new Promise(resolve => {
        const id = Math.random().toString(36).slice(2);
        pending.set(id, resolve);
        try { window.parent.postMessage({ [MSG]: type, id, ...extra }, '*'); } catch { pending.delete(id); resolve('unreachable'); return; }
        setTimeout(() => { if (pending.delete(id)) resolve('timeout'); }, 600);
      });
      const tellParent = type => { if (!isTop) try { window.parent.postMessage({ [MSG]: type }, '*'); } catch {} };
      const findFrame = source => {
        const search = root => {
          for (const frame of root.querySelectorAll('iframe, frame')) if (frame.contentWindow === source) return frame;
          for (const host of root.querySelectorAll('*')) if (host.shadowRoot) { const found = search(host.shadowRoot); if (found) return found; }
          return null;
        };
        return search(document);
      };
      const allowsFullscreen = frame => frame.hasAttribute('allowfullscreen') || frame.hasAttribute('webkitallowfullscreen')
        || /(^|;)\s*fullscreen(?!\s+'none')/.test(frame.getAttribute('allow') || '');

      // MARK: Entering and leaving

      const nativeRequest = (el, options) => {
        log('using native fullscreen for', describe(el));
        try { return Promise.resolve(call(options.nativeCall, el, options.args)); } catch (error) { return Promise.reject(error); }
      };
      const start = (state, done) => frameAfter(() => {
        if (active !== state) { done(); return; }
        announce(state, state.el);
        done();
        // Check again once the page has laid itself out for fullscreen, while the click still counts.
        frameAfter(() => frameAfter(() => verify(state, true)));
        state.watchdog = setInterval(() => verify(state, false), 500);
      });
      const simulate = (el, options) => {
        if (native.enabled && !native.enabled.call(document)) return nativeRequest(el, options);
        // Like WebKit's, only right after a click or key press; WebKit refuses the rest itself.
        if (!options.trusted && navigator.userActivation && !navigator.userActivation.isActive) {
          log('request without a user gesture for', describe(el));
          return nativeRequest(el, options);
        }
        if (active && active.el === el) return Promise.resolve();
        if (nativeElement()) return nativeRequest(el, options);
        if (active) leave(active, { announce: false });
        const state = pin(el, { ...options, kind: 'own' });
        if (typeof state === 'string') { log('simulated fullscreen refused for', describe(el) + ':', state); return nativeRequest(el, options); }
        setActive(state);
        log('simulated fullscreen for', describe(el), state.topLayer ? '(top layer)' : '(fixed)');
        if (isTop) return new Promise(resolve => start(state, resolve));
        return askParent('request').then(reply => {
          if (active !== state) return;
          if (reply === 'ok') return new Promise(resolve => start(state, resolve));
          unpin(state); setActive(null);
          if (reply === 'denied') {
            log('parent frame does not allow fullscreen');
            fire(el, 'fullscreenerror');
            throw new TypeError('Fullscreen is not allowed in this frame');
          }
          log('parent frame could not show this frame:', reply);
          return nativeRequest(el, options);
        });
      };
      // The site or the user took it out of fullscreen.
      // `immediate` tells the page at once, for Escape, where no page code is waiting on the call.
      const leave = (state, { announce: notify = true, fromParent = false, fromChild = false, immediate = false } = {}) => {
        if (active === state) setActive(null);
        unpin(state);
        state.entered = false;
        if (state.kind === 'own' && !isTop && !fromParent) tellParent('exited');
        if (state.kind === 'child' && !fromChild) try { state.child.postMessage({ [MSG]: 'exit' }, '*'); } catch {}
        log('left simulated fullscreen for', describe(state.el));
        if (!notify) return Promise.resolve();
        if (immediate) { announce(state, state.el); return Promise.resolve(); }
        return new Promise(resolve => frameAfter(() => { announce(state, state.el); resolve(); }));
      };
      // The element stopped covering the window: show it with WebKit instead, or leave.
      const fallBack = state => {
        if (active !== state) return;
        const el = state.el;
        log('falling back from simulated fullscreen for', describe(el));
        setActive(null); unpin(state);
        if (state.kind === 'child') {
          try { state.child.postMessage({ [MSG]: 'native' }, '*'); } catch {}
          tellParent('release');
          return;
        }
        tellParent('release');
        nativeRequest(el, state).catch(error => {
          log('native fallback failed:', error && error.name, '- leaving fullscreen');
          state.entered = false; announce(state, el);
        });
      };
      const verify = (state, early) => {
        if (active !== state) return;
        if (!state.el.isConnected) { log('fullscreen element left the document'); leave(state); return; }
        if (state.topLayer && !state.el.matches(':popover-open')) {
          log('element dropped out of the top layer; lifting it again');
          try { if (!state.el.hasAttribute('popover')) state.el.setAttribute('popover', 'manual'); native.showPopover.call(state.el); } catch {}
        }
        if (!state.el.hasAttribute('data-rise-fullscreen')) state.el.setAttribute('data-rise-fullscreen', '');
        const cover = viewportCovered(state.el);
        if (cover.ok) { state.misses = 0; return; }
        state.misses += 1;
        log('fullscreen element is not covering the window:', cover.why);
        if (early || state.misses >= 2) fallBack(state);
      };

      // MARK: Messages

      window.addEventListener('message', event => {
        const data = event.data;
        if (!data || typeof data !== 'object' || !(MSG in data)) return;
        event.stopImmediatePropagation();
        const source = event.source, fromParent = !isTop && source === window.parent;
        const reply = result => { try { source.postMessage({ [MSG]: 'reply', id: data.id, result }, '*'); } catch {} };
        switch (data[MSG]) {
          case 'reply': { const resolve = pending.get(data.id); if (fromParent && resolve) { pending.delete(data.id); resolve(data.result); } break; }
          case 'request': {
            const frame = source && findFrame(source);
            if (!frame) { reply('unknown frame'); break; }
            if (!allowsFullscreen(frame)) { reply('denied'); break; }
            if (!simulated) { reply('native mode'); break; }
            if (active && active.el === frame) { reply('ok'); break; }
            if (nativeElement()) { reply('native fullscreen showing'); break; }
            if (active) leave(active, { announce: false });
            const state = pin(frame, { kind: 'child', child: source, prefixed: false });
            if (typeof state === 'string') { log('could not lift frame:', state); reply(state); break; }
            setActive(state);
            log('lifted frame', describe(frame), 'for its fullscreen element');
            if (isTop) { start(state, () => {}); reply('ok'); break; }
            askParent('request').then(result => {
              if (active !== state) { reply('left'); return; }
              if (result === 'ok') { start(state, () => {}); reply('ok'); return; }
              unpin(state); setActive(null); reply(result);
            });
            break;
          }
          case 'exited': if (active?.kind === 'child' && active.child === source) leave(active, { fromChild: true }); break;
          case 'release': if (active?.kind === 'child' && active.child === source) { const state = active; setActive(null); unpin(state); tellParent('release'); } break;
          case 'exit': if (fromParent && active?.kind === 'own') leave(active, { fromParent: true, immediate: true }); break;
          case 'native': if (fromParent && active) { const state = active; setActive(null); unpin(state); nativeRequest(state.el, state).catch(() => { state.entered = false; announce(state, state.el); }); } break;
          case 'mode': if (fromParent) setMode(!!data.simulated); break;
        }
      }, true);
      window.addEventListener('pagehide', () => {
        if (active) leave(active, { announce: false });
      }, true);

      // Escape leaves simulated fullscreen, as it does WebKit's, without reaching the page.
      const swallowEscape = event => {
        if (event.key !== 'Escape' || !active || event.isComposing) return;
        event.preventDefault(); event.stopImmediatePropagation();
        if (event.type === 'keydown') { log('Escape'); leave(active, { immediate: true }); }
      };
      window.addEventListener('keydown', swallowEscape, true);

      // WebKit's own fullscreen ending, for an element waiting to be simulated or a child shown through its frame.
      document.addEventListener('fullscreenchange', () => {
        if (nativeElement()) return;
        if (nativeChild) { try { nativeChild.postMessage({ [MSG]: 'exit' }, '*'); } catch {} nativeChild = null; }
        if (pendingSimulated) {
          const el = pendingSimulated; pendingSimulated = null;
          simulate(el, { prefixed: !sawUnprefixedRequest, nativeCall: native.request, args: [], trusted: true }).catch(() => {});
        }
      }, true);

      // MARK: Modes

      const setMode = value => {
        if (simulated !== value) log('mode', value ? 'simulated' : 'native');
        simulated = value;
        for (let i = 0; i < window.frames.length; i++) try { window.frames[i].postMessage({ [MSG]: 'mode', simulated: value }, '*'); } catch {}
        if (!value && active) {
          const state = active;
          if (state.kind === 'own' && !isTop) return;
          setActive(null); unpin(state);
          if (state.kind === 'child') nativeChild = state.child;
          // WebKit takes over the same element, so the page sees it stay fullscreen.
          nativeRequest(state.el, { nativeCall: native.request, args: [] }).catch(error => {
            log('switching to native fullscreen failed:', error && error.name);
            nativeChild = null;
            if (state.kind === 'child') try { state.child.postMessage({ [MSG]: 'exit' }, '*'); } catch {}
            state.entered = false; announce(state, state.el);
          });
        } else if (value) {
          const el = nativeElement();
          if (el && !isFrame(el)) { pendingSimulated = el; call(native.exit, document, []); }
        }
      };

      // MARK: The API

      const install = (proto, name, value) => {
        if (!proto || !(name in proto)) return;
        const descriptor = Object.getOwnPropertyDescriptor(proto, name) || { configurable: true, enumerable: true, writable: true };
        Object.defineProperty(proto, name, { ...descriptor, value });
      };
      const installGetter = (proto, name, get) => {
        const descriptor = proto && Object.getOwnPropertyDescriptor(proto, name);
        if (descriptor?.get) Object.defineProperty(proto, name, { ...descriptor, get });
      };
      install(E, 'requestFullscreen', function requestFullscreen(options) {
        sawUnprefixedRequest = true;
        if (!simulated) return call(native.request, this, arguments);
        return simulate(this, { prefixed: false, nativeCall: native.request, args: [...arguments] });
      });
      for (const name of ['webkitRequestFullscreen', 'webkitRequestFullScreen']) {
        const original = E[name];
        install(E, name, function () {
          if (!simulated) return call(original, this, arguments);
          simulate(this, { prefixed: true, nativeCall: original, args: [...arguments] }).catch(() => {});
        });
      }
      install(D, 'exitFullscreen', function exitFullscreen() {
        if (this === document && active) return leave(active);
        return call(native.exit, this, arguments);
      });
      for (const name of ['webkitExitFullscreen', 'webkitCancelFullScreen']) {
        const original = D[name];
        install(D, name, function () {
          if (this === document && active) { leave(active); return; }
          return call(original, this, arguments);
        });
      }
      const current = (doc, original, self) => (doc === document && active) ? retarget(active.el, document) : (original ? original.call(self) : null);
      installGetter(D, 'fullscreenElement', function () { return current(this, native.element, this); });
      installGetter(D, 'webkitFullscreenElement', function () { return current(this, native.webkitElement, this); });
      installGetter(D, 'webkitCurrentFullScreenElement', function () { return current(this, native.webkitCurrent, this); });
      installGetter(D, 'fullscreen', function () { return (this === document && active) ? true : !!native.fullscreen?.call(this); });
      installGetter(D, 'webkitIsFullScreen', function () { return (this === document && active) ? true : !!native.webkitIsFullScreen?.call(this); });
      installGetter(S, 'fullscreenElement', function () {
        if (active && this.ownerDocument === document) return retarget(active.el, this);
        return native.shadowElement ? native.shadowElement.call(this) : null;
      });
      if (V) {
        for (const name of ['webkitEnterFullscreen', 'webkitEnterFullScreen']) {
          const original = V[name];
          install(V, name, function () {
            if (!simulated) return call(original, this, arguments);
            simulate(this, { prefixed: true, video: true, nativeCall: original, args: [] }).catch(() => {});
          });
        }
        for (const name of ['webkitExitFullscreen', 'webkitExitFullScreen']) {
          const original = V[name];
          install(V, name, function () {
            if (active && active.el === this) { leave(active); return; }
            return call(original, this, arguments);
          });
        }
        installGetter(V, 'webkitDisplayingFullscreen', function () {
          return (active && active.el === this) ? true : !!native.videoDisplaying?.call(this);
        });
      }

      Object.defineProperty(window, KEY, { value: Object.freeze({
        setMode,
        exit: () => active ? leave(active) : Promise.resolve(),
        get state() { return active ? { element: describe(active.el), kind: active.kind, topLayer: active.topLayer } : null; },
        get simulated() { return simulated; },
      }) });
    })();
    """#
}
