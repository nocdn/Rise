import Foundation
import WebKit
import CryptoKit
#if RISE_CHROMIUM
import RiseChromium
#endif

/// Immutable native rules, compiled once per process and cached on disk by
/// WebKit. Network and cosmetic blocking use the engine, not fetch overrides.
@MainActor enum AdBlockRules {
    struct Manifest: Decodable {
        struct List: Decodable { let file: String; let sha256: String; let rules: Int }
        let lists: [List]
    }
    static let compilation: Task<[WKContentRuleList], Error> = Task {
        let inputs = try await Task.detached(priority: .userInitiated) { () -> [(String, String)] in
            guard let manifestURL = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Blocking") else {
                throw NSError(domain: "Rise.AdBlocker", code: 3, userInfo: [NSLocalizedDescriptionKey: "The bundled blocking rules are missing."])
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            return try manifest.lists.map { list in
                let data = try Data(contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(list.file))
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == list.sha256, let json = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "Rise.AdBlocker", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled blocking rules failed validation."])
                }
                return ("Rise.Blocking.\(hash)", json)
            }
        }.value
        var compiled: [WKContentRuleList] = []
        for (identifier, json) in inputs {
            guard let store = WKContentRuleListStore.default() else {
                throw NSError(domain: "Rise.AdBlocker", code: 4, userInfo: [NSLocalizedDescriptionKey: "WebKit’s blocking rule store is unavailable."])
            }
            if let cached = try? await store.contentRuleList(forIdentifier: identifier) { compiled.append(cached) }
            else {
                guard let rule = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
                    throw NSError(domain: "Rise.AdBlocker", code: 2, userInfo: [NSLocalizedDescriptionKey: "WebKit couldn’t compile the blocking rules."])
                }
                compiled.append(rule)
            }
        }
        return compiled
    }
}

@MainActor final class AdBlocker {
    static let preferenceKey = "Rise.AdBlocking"
    private let preferences: UserDefaults
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let blockedControllers = NSHashTable<WKUserContentController>.weakObjects()
    private var rules: [WKContentRuleList] = []
    private var changeGeneration = 0
    private(set) var enabled: Bool
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = preferences.object(forKey: Self.preferenceKey) == nil || preferences.bool(forKey: Self.preferenceKey)
        #if RISE_CHROMIUM
        RCAdBlock.enabled = enabled
        #endif
    }
    /// Chromium pages, which the engine blocks for; the page only gets the script that hides
    /// ad slots, asking the engine which.
    private let scriptedPages = NSHashTable<AnyObject>.weakObjects()
    func install(on page: WebPage) {
        guard let webView = (page as? WebKitPage)?.webView else { installHiding(on: page); return }
        install(on: webView)
    }
    private func installHiding(on page: WebPage) {
        #if RISE_CHROMIUM
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
        #endif
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
    func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if !controllers.contains(controller) { controllers.add(controller); apply(to: controller) }
    }
    /// WebKit's content rules; a Chromium page is blocked in the engine instead.
    func prepare(_ page: WebPage) async throws {
        guard let webView = (page as? WebKitPage)?.webView else { return }
        install(on: webView)
        guard enabled else { return }
        rules = try await AdBlockRules.compilation.value
        // Recheck the preference after compilation; a toggle may have happened.
        for controller in controllers.allObjects { apply(to: controller) }
    }
    func setEnabled(_ value: Bool) -> Task<Void, Error> {
        changeGeneration += 1; let generation = changeGeneration
        enabled = value; preferences.set(value, forKey: Self.preferenceKey)
        #if RISE_CHROMIUM
        RCAdBlock.enabled = value
        #endif
        return Task {
            if value { rules = try await AdBlockRules.compilation.value }
            guard changeGeneration == generation else { return }
            for controller in controllers.allObjects { apply(to: controller) }
        }
    }
    private func apply(to controller: WKUserContentController) {
        if enabled {
            guard !rules.isEmpty, !blockedControllers.contains(controller) else { return }
            for rule in rules { controller.add(rule) }
            blockedControllers.add(controller)
        } else if blockedControllers.contains(controller) {
            for rule in rules { controller.remove(rule) }
            blockedControllers.remove(controller)
        }
    }
}
