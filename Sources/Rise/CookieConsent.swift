import AppKit
import RiseCore

/// Chromium transport for the same rules, policy and native bridge used by iOS.
@MainActor final class CookieConsent {
    static let world = ScriptWorld.named(CookieConsentRules.worldName)
    let policy: CookieConsentPolicy
    private let contexts = NSMapTable<AnyObject, Context>.weakToStrongObjects()
    private(set) var failure: Error?
    private static let loading: Task<CookieConsentRules, Error> = Task.detached(priority: .userInitiated) {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("CookieConsent") else { throw CookieConsentRules.Failure.resources }
        return try CookieConsentRules.load(from: directory)
    }
    init(preferences: UserDefaults) { policy = CookieConsentPolicy(preferences: preferences, defaultEnabled: false) }
    func isEnabled(for url: URL?) -> Bool { policy.isEnabled(for: url) }
    func install(on page: WebPage) {
        guard contexts.object(forKey: page) == nil else { return }
        let context = Context(page: page, policy: policy)
        contexts.setObject(context, forKey: page)
        Task { [weak self, weak page, weak context] in
            do {
                let rules = try await Self.loading.value
                guard let self, let page, let context else { return }
                context.rules = rules; context.session.enabled = true
                page.addMessageHandler("riseCookieConsent", world: Self.world) { [weak context] message in
                    context?.session.receive(message.body, in: message.frame, isMain: message.frame.isMain)
                }
                page.addMessageHandler("riseCookieConsentPolicy", world: Self.world, replying: { [weak context] message, reply in
                    reply(context?.policy.isEnabled(for: message.page?.url) == true, nil)
                })
                page.addUserScript(Self.bootstrap(rules), world: Self.world, mainFrameOnly: false,
                                   handlers: ["riseCookieConsent", "riseCookieConsentPolicy"])
                self.failure = nil
            } catch { self?.failure = error }
        }
    }
    func setEnabled(_ enabled: Bool, for url: URL) {
        policy.setEnabled(enabled, for: url)
        for context in contexts.objectEnumerator()?.allObjects.compactMap({ $0 as? Context }) ?? [] where CookieConsentPolicy.site(context.page?.url) == CookieConsentPolicy.site(url) {
            if enabled { context.session.resumeFrames() }
            else { context.session.stopFrames(forget: false) }
        }
    }
    func inspect(_ page: WebPage) async -> [[String: Any]] { await contexts.object(forKey: page)?.session.inspect() ?? [] }
    private static func bootstrap(_ rules: CookieConsentRules) -> String {
        """
        (() => {
          if (!/^https?:$/.test(location.protocol)) return;
          const start = async () => {
            try {
              if (!await riseHandlers.riseCookieConsentPolicy.postMessage(null)) return;
              if (window.__riseCookieConsent) return;
              \(rules.source)
            } catch (_) {}
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once:true});
          else start();
        })();
        """
    }
    @MainActor private final class Context {
        weak var page: WebPage?
        let policy: CookieConsentPolicy
        var rules: CookieConsentRules?
        lazy var session = CookieConsentSession<PageFrame>(rules: { [weak self] in self?.rules }, allowed: { [weak self] in
            guard let self else { return false }; return policy.isEnabled(for: page?.url)
        }, evaluate: { [weak self] body, arguments, frame, world in
            guard let page = self?.page else { return nil }
            return await withCheckedContinuation { continuation in
                let completion: (Result<Any?, Error>) -> Void = { continuation.resume(returning: try? $0.get()) }
                let world: ScriptWorld = world == .page ? .page : CookieConsent.world
                if let page = page as? ChromiumPage {
                    page.evaluate(body, arguments: arguments, in: frame, world: world, userGesture: false, completion: completion)
                } else { page.evaluate(body, arguments: arguments, in: frame, world: world, completion: completion) }
            }
        })
        init(page: WebPage, policy: CookieConsentPolicy) { self.page = page; self.policy = policy }
    }
}

@MainActor extension BrowserController {
    @objc func toggleCookieConsent() {
        guard let url = commandTab?.url, CookieConsentPolicy.site(url) != nil else { return }
        historySwipe.cancel(); linkPreloader.cancelAll()
        cookieConsent.setEnabled(!cookieConsent.isEnabled(for: url), for: url)
        // Switched in the site controls, they stay open through the reload it takes.
        if siteControlsPopover.isShown, let tab = commandTab { siteControlsReload = (tab.id, url, Date().addingTimeInterval(5)) }
        let visible = Set(visibleTabIDs)
        for tab in tabs + allPeekTabs where CookieConsentPolicy.site(tab.url) == CookieConsentPolicy.site(url) {
            if visible.contains(tab.id) || tab === peekTab { tab.page.reload(); tab.needsBlockingReload = false }
            else { tab.needsBlockingReload = true }
        }
        refreshSiteControls()
    }
}
