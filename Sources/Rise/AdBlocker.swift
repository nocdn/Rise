import Foundation
import RiseChromium

/// Ads and trackers, blocked by the engine from Engine/adblock's filter lists; pages get a script
/// that hides the slots the lists say to.
@MainActor final class AdBlocker {
    static let preferenceKey = "Rise.AdBlocking"
    private let preferences: UserDefaults
    private(set) var enabled: Bool
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = preferences.object(forKey: Self.preferenceKey) == nil || preferences.bool(forKey: Self.preferenceKey)
        RCAdBlock.enabled = enabled
    }
    /// Pages with the script that hides ad slots, asking the engine which.
    private let scriptedPages = NSHashTable<AnyObject>.weakObjects()
    func install(on page: WebPage) {
        guard RCAdBlock.available, !scriptedPages.contains(page) else { return }
        if scriptedPages.count == 0 { RCAdBlock.load() }
        scriptedPages.add(page)
        page.addMessageHandler("riseAdBlock", world: .named(Self.world)) { message, reply in
            guard let body = message.body as? [String: Any], let url = (body["url"] as? String).flatMap(URL.init(string:)) else {
                reply([String](), nil); return
            }
            reply(RCAdBlock.hiddenSelectors(for: url, classes: body["classes"] as? [String], ids: body["ids"] as? [String]), nil)
        }
        page.addUserScript(Self.hidingScript, world: .named(Self.world), mainFrameOnly: false, handlers: ["riseAdBlock"])
    }
    static let world = "Rise.AdBlocking"
    /// Hides what the filter lists say to, as WebKit's `css-display-none` rules do: the page's
    /// own selectors at once, then the general ones for the classes and ids it uses as they appear.
    static let hidingScript = """
    (() => {
      if (globalThis.riseAdBlock) return;
      globalThis.riseAdBlock = true;
      const handler = riseHandlers.riseAdBlock, url = location.href;
      if (!/^https?:/.test(url)) return;
      const sheet = new CSSStyleSheet(), hidden = new Set(), classes = new Set(), ids = new Set();
      const adopt = () => {
        if (!document.adoptedStyleSheets.includes(sheet)) document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      };
      const hide = selectors => {
        for (const selector of selectors || []) {
          if (hidden.has(selector)) continue;
          hidden.add(selector);
          // One selector this engine can't read mustn't take the others with it.
          try { sheet.insertRule(`${selector}{display:none !important}`, sheet.cssRules.length); } catch {}
        }
        if (sheet.cssRules.length) adopt();
      };
      handler.postMessage({url}).then(hide, () => {});
      let pending = [], timer = 0;
      const look = () => {
        timer = 0;
        const fresh = {classes: [], ids: []};
        const note = element => {
          for (const name of element.classList || []) if (!classes.has(name)) { classes.add(name); fresh.classes.push(name); }
          if (element.id && !ids.has(element.id)) { ids.add(element.id); fresh.ids.push(element.id); }
        };
        for (const root of pending) {
          if (root.nodeType !== 1) continue;
          note(root);
          root.querySelectorAll('[class],[id]').forEach(note);
        }
        pending = [];
        if (fresh.classes.length || fresh.ids.length) handler.postMessage({url, ...fresh}).then(hide, () => {});
        // A page may set its own sheets over Rise's.
        if (sheet.cssRules.length) adopt();
      };
      const soon = root => { pending.push(root); if (!timer) timer = setTimeout(look, pending.length > 1 ? 100 : 0); };
      new MutationObserver(records => {
        for (const record of records) {
          if (record.type === 'attributes') soon(record.target);
          else record.addedNodes.forEach(soon);
        }
      }).observe(document, {childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'id']});
      if (document.documentElement) soon(document.documentElement);
    })();
    """
    /// Turns blocking on or off; the task ends once the engine has it.
    func setEnabled(_ value: Bool) -> Task<Void, Error> {
        enabled = value; preferences.set(value, forKey: Self.preferenceKey)
        RCAdBlock.enabled = value
        return Task {}
    }
}
