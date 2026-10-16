import CryptoKit
import Foundation
import WebKit

/// Consent automation runs in an isolated world. Only bundled, named CMP functions may
/// cross into the page world; neither a website nor a bridge message supplies executable code.
@MainActor final class MobileCookieBannerBlocker {
    nonisolated static let scriptMarker = "// Rise.CookieConsent\n"
    static let world = WKContentWorld.world(name: "Rise.CookieConsent")
    private static let preferenceKey = "Rise.iOS.CookieBanners.DisabledSites"
    private let preferences: UserDefaults
    private static let contexts = NSMapTable<WKWebView, Context>.weakToStrongObjects()
    private static let versions = NSMapTable<WKWebView, NSNumber>.weakToStrongObjects()
    private static var generation = 0
    private static var catalog: Catalog?
    private struct Catalog { let script: WKUserScript; let evals: [String: String] }
    private struct Inputs: Sendable { let source: String; let evals: [String: String] }
    private struct Manifest: Decodable, Sendable {
        struct Asset: Decodable, Sendable { let file: String; let sha256: String }
        let assets: [Asset]
    }
    private static let loading: Task<Catalog, Error> = Task { @MainActor in
        let inputs = try await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: "cookie-consent-manifest", withExtension: "json") else { throw Failure.resources }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            var assets: [String: Data] = [:]
            for asset in manifest.assets {
                guard let url = Bundle.main.url(forResource: asset.file, withExtension: nil) else { throw Failure.resources }
                let data = try Data(contentsOf: url)
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw Failure.resources }
                assets[asset.file] = data
            }
            guard let source = assets["cookie-consent.js"].flatMap({ String(data: $0, encoding: .utf8) }),
                  let evals = assets["cookie-consent-evals.json"] else { throw Failure.resources }
            return Inputs(source: source, evals: try JSONDecoder().decode([String: String].self, from: evals))
        }.value
        let value = Catalog(script: WKUserScript(source: scriptMarker+inputs.source, injectionTime: .atDocumentEnd,
            forMainFrameOnly: false, in: world), evals: inputs.evals)
        catalog = value
        return value
    }

    init(preferences: UserDefaults = .standard) { self.preferences = preferences; _ = Self.loading }

    private static func site(_ url: URL?) -> String? {
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? ""), var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
    func isEnabled(for url: URL?) -> Bool {
        guard let site = Self.site(url) else { return false }
        return !(preferences.stringArray(forKey: Self.preferenceKey) ?? []).contains(site)
    }
    func setEnabled(_ enabled: Bool, for url: URL) {
        guard let site = Self.site(url) else { return }
        var disabled = Set(preferences.stringArray(forKey: Self.preferenceKey) ?? [])
        if enabled { disabled.remove(site) } else { disabled.insert(site) }
        preferences.set(disabled.sorted(), forKey: Self.preferenceKey)
        if !enabled {
            // Stop delayed acceptance in other tabs and preview renderers on this host,
            // too. A different audit/profile's independent preferences stay independent.
            for page in Self.contexts.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
                guard let context = Self.contexts.object(forKey:page), context.owner?.preferences === preferences,
                      Self.site(context.url) == site else { continue }
                apply(to:page,url:context.url)
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
        if !enabled || Self.site(context.appliedURL) != Self.site(url) { context.stopFrames() }
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
        var values: [[String: Any]] = []
        for (token, frame) in context.frames {
            if let result = try? await page.callAsyncJavaScript("return window.__riseCookieConsent?.inspect();", arguments: [:], in: frame, contentWorld: Self.world) as? [String: Any], result["token"] as? String == token {
                var value = result; value["main"] = frame.isMainFrame
                value["apiActions"] = context.apiActions[token] ?? 0
                values.append(value)
            }
        }
        return values
    }

    private final class Context: NSObject, WKScriptMessageHandler {
        weak var page: WKWebView?
        weak var owner: MobileCookieBannerBlocker?
        var url: URL?, appliedURL: URL?
        var enabled: Bool?
        var frames: [String: WKFrameInfo] = [:]
        var evaluations: [String: Int] = [:]
        var apiActions: [String: Int] = [:]
        init(page: WKWebView) { self.page = page }
        func stopFrames() {
            guard let page else { return }
            for (token, frame) in frames {
                page.callAsyncJavaScript("if (window.__riseCookieConsent?.token === token) window.__riseCookieConsent.stop();", arguments: ["token":token], in: frame, in: MobileCookieBannerBlocker.world, completionHandler: nil)
            }
            frames.removeAll(); evaluations.removeAll(); apiActions.removeAll()
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let page,
                  let body = message.body as? [String: Any], let token = body["token"] as? String, token.count < 100 else { return }
            let allowed = enabled == true && owner?.isEnabled(for:url) == true
            if body["type"] as? String == "ready", !allowed {
                // ready can be delivered after the switch changed, before the frame was
                // entered into the ledger. Stop that document instead of losing it.
                page.callAsyncJavaScript("if (window.__riseCookieConsent?.token === token) window.__riseCookieConsent.stop();",
                    arguments:["token":token],in:message.frameInfo,in:MobileCookieBannerBlocker.world,completionHandler:nil)
                return
            }
            guard allowed else { return }
            if body["type"] as? String == "ready" {
                if message.frameInfo.isMainFrame { frames.removeAll(); evaluations.removeAll(); apiActions.removeAll() }
                if frames.count < 64 { frames[token] = message.frameInfo }
                return
            }
            if body["type"] as? String == "resume", let script = MobileCookieBannerBlocker.catalog?.script.source {
                page.callAsyncJavaScript("if (window.__riseCookieConsent?.token === token && window.__riseCookieConsent.shouldResume()) { window.__riseCookieConsent.dispose(); delete window.__riseCookieConsent;\n"+script+"\n}",
                    arguments: ["token":token], in: message.frameInfo, in: MobileCookieBannerBlocker.world, completionHandler: nil)
                return
            }
            guard body["type"] as? String == "eval", let id = body["id"] as? String, id.count < 200,
                  let snippetID = body["snippetId"] as? String,
                  let code = MobileCookieBannerBlocker.catalog?.evals[snippetID],
                  evaluations[token, default: 0] < 250 else { return }
            if frames[token] == nil, frames.count < 64 { frames[token] = message.frameInfo }
            guard frames[token] != nil else { return }
            evaluations[token, default: 0] += 1
            let frame = message.frameInfo
            Task { [weak self, weak page] in
                guard let self, let page, enabled == true, frames[token] != nil else { return }
                // Check the document token before invoking a page API: an async request may
                // outlive a navigation even though its WKFrameInfo still names the main frame.
                let current = try? await page.callAsyncJavaScript("const c=window.__riseCookieConsent; return c?.canAct() ? c.token : null;", arguments: [:], in: frame, contentWorld: MobileCookieBannerBlocker.world)
                guard current as? String == token, enabled == true, owner?.isEnabled(for: url) == true else { return }
                let result = (try? await page.callAsyncJavaScript("let timer; try { return Boolean(await Promise.race([Promise.resolve(\(code)), new Promise(resolve => { timer=setTimeout(() => resolve(false), 5000); })])); } catch (_) { return false; } finally { clearTimeout(timer); }", arguments: [:], in: frame, contentWorld: .page)) as? Bool ?? false
                if result && snippetID.hasPrefix("RISE_") { apiActions[token, default: 0] += 1 }
                if id.hasPrefix("rise-") { return }
                guard enabled == true else { return }
                _ = try? await page.callAsyncJavaScript("window.__riseCookieConsent?.respond(id, result, token);", arguments: ["id": id, "result": result, "token": token], in: frame, contentWorld: MobileCookieBannerBlocker.world)
            }
        }
    }
    private enum Failure: LocalizedError {
        case resources
        var errorDescription: String? { "The bundled cookie-banner rules couldn't be loaded or verified." }
    }
}
