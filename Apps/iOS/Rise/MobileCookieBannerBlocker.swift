import Foundation
import WebKit

/// Consent automation runs in an isolated world. Only bundled, named CMP functions may
/// cross into the page world; neither a website nor a bridge message supplies executable code.
@MainActor final class MobileCookieBannerBlocker {
    nonisolated static let scriptMarker = CookieConsentRules.scriptMarker
    static let world = WKContentWorld.world(name: CookieConsentRules.worldName)
    private let policy: CookieConsentPolicy
    private static let contexts = NSMapTable<WKWebView, Context>.weakToStrongObjects()
    private static let versions = NSMapTable<WKWebView, NSNumber>.weakToStrongObjects()
    private static var generation = 0
    private static var catalog: Catalog?
    private struct Catalog { let script: WKUserScript; let rules: CookieConsentRules }
    private static let loading: Task<Catalog, Error> = Task { @MainActor in
        guard let directory = Bundle.main.resourceURL else { throw CookieConsentRules.Failure.resources }
        let rules = try await Task.detached(priority: .userInitiated) { try CookieConsentRules.load(from: directory) }.value
        let value = Catalog(script: WKUserScript(source: rules.source, injectionTime: .atDocumentEnd,
            forMainFrameOnly: false, in: world), rules: rules)
        catalog = value
        return value
    }

    init(preferences: UserDefaults? = .standard) { policy = CookieConsentPolicy(preferences: preferences); _ = Self.loading }

    func isEnabled(for url: URL?) -> Bool { policy.isEnabled(for: url) }
    func setEnabled(_ enabled: Bool, for url: URL) {
        policy.setEnabled(enabled, for: url)
        if !enabled {
            for page in Self.contexts.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
                guard let context = Self.contexts.object(forKey: page),
                      context.owner?.policy.sharesStore(with: policy) == true,
                      CookieConsentPolicy.site(context.url) == CookieConsentPolicy.site(url) else { continue }
                apply(to: page, url: context.url)
            }
        }
    }
    func prepareIfReady(_ page: WKWebView, for url: URL?) -> Bool {
        _ = beginPreparation(page)
        guard !isEnabled(for: url) || Self.catalog != nil else { return false }
        apply(to: page, url: url); return true
    }
    func prepare(_ page: WKWebView, for url: URL?) async throws {
        let version = beginPreparation(page)
        if isEnabled(for: url) { _ = try await Self.loading.value }
        try Task.checkCancellation()
        guard Self.versions.object(forKey: page)?.intValue == version else { throw CancellationError() }
        apply(to: page, url: url)
    }
    private func beginPreparation(_ page: WKWebView) -> Int {
        Self.generation += 1
        Self.versions.setObject(NSNumber(value: Self.generation),forKey:page)
        return Self.generation
    }

    private func apply(to page: WKWebView, url: URL?) {
        let controller = page.configuration.userContentController
        let context: Context
        if let existing = Self.contexts.object(forKey: page) { context = existing }
        else {
            context = Context(page: page)
            Self.contexts.setObject(context, forKey: page)
            controller.add(context, contentWorld: Self.world, name: "riseCookieConsent")
        }
        let enabled = isEnabled(for: url)
        context.owner = self; context.url = url
        if !enabled || CookieConsentPolicy.site(context.appliedURL) != CookieConsentPolicy.site(url) { context.stopFrames() }
        context.appliedURL = url
        guard context.enabled != enabled else { return }
        context.enabled = enabled
        let others = controller.userScripts.filter { !$0.source.hasPrefix(Self.scriptMarker) }
        controller.removeAllUserScripts(); others.forEach(controller.addUserScript)
        if enabled, let catalog = Self.catalog { controller.addUserScript(catalog.script) }
    }

    /// A bounded inspection surface for native audits and deciding when a preview is ready.
    func inspect(_ page: WKWebView) async -> [[String: Any]] {
        guard let context = Self.contexts.object(forKey: page) else { return [] }
        return await context.session.inspect()
    }

    @MainActor private final class Context: NSObject, WKScriptMessageHandler {
        weak var page: WKWebView?
        weak var owner: MobileCookieBannerBlocker?
        var url: URL?, appliedURL: URL?
        var enabled: Bool? { didSet { session.enabled = enabled == true } }
        lazy var session = CookieConsentSession<WKFrameInfo>(rules: { MobileCookieBannerBlocker.catalog?.rules }, allowed: { [weak self] in
            guard let self else { return false }
            return owner?.isEnabled(for: url) == true
        }, evaluate: { [weak self] body, arguments, frame, world in
            guard let page = self?.page else { return nil }
            return try? await page.callAsyncJavaScript(body, arguments: arguments, in: frame,
                contentWorld: world == .page ? .page : MobileCookieBannerBlocker.world)
        })
        init(page: WKWebView) { self.page = page }
        func stopFrames() { session.stopFrames() }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard page != nil else { return }
            session.receive(message.body, in: message.frameInfo, isMain: message.frameInfo.isMainFrame)
        }
    }
}
