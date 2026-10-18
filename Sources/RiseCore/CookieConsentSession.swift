import Foundation

public enum CookieConsentWorld { case automation, page }

/// The same bounded, document-token-checked native bridge in both browsers. Frame and
/// evaluation transport belong to the WebKit/Chromium adapters; consent decisions do not.
@MainActor public final class CookieConsentSession<Frame> {
    public typealias Evaluate = @MainActor (String, [String: Any], Frame, CookieConsentWorld) async -> Any?
    private let evaluate: Evaluate
    private let rules: () -> CookieConsentRules?
    private let allowed: () -> Bool
    public var enabled = false
    private var frames: [String: (frame: Frame, main: Bool)] = [:]
    private var evaluations: [String: Int] = [:]
    private var apiActions: [String: Int] = [:]
    private var retainsPausedFrames = false

    public init(rules: @escaping () -> CookieConsentRules?, allowed: @escaping () -> Bool, evaluate: @escaping Evaluate) {
        self.rules = rules; self.allowed = allowed; self.evaluate = evaluate
    }
    public func stopFrames(forget: Bool = true) {
        retainsPausedFrames = !forget
        for (token, record) in frames { stop(token, in: record.frame) }
        if forget { frames.removeAll() }
        evaluations.removeAll(); apiActions.removeAll()
    }
    private func stop(_ token: String, in frame: Frame) {
        Task { _ = await evaluate("if (window.__riseCookieConsent?.token === token) window.__riseCookieConsent.stop();", ["token": token], frame, .automation) }
    }
    private func register(_ token: String, in frame: Frame, isMain: Bool) {
        if isMain { frames.removeAll(); evaluations.removeAll(); apiActions.removeAll() }
        if frames.count < 64 { frames[token] = (frame, isMain) }
    }
    /// Held pages stay alive offscreen; re-enabling must wake them as well as reloaded tabs.
    public func resumeFrames() { for (token, record) in frames { resume(token, in: record.frame) } }
    private func resume(_ token: String, in frame: Frame) {
        guard let source = rules()?.source else { return }
        Task {
            guard enabled && allowed() else { return }
            _ = await evaluate("if (window.__riseCookieConsent?.token === token && window.__riseCookieConsent.shouldResume()) { window.__riseCookieConsent.dispose(); delete window.__riseCookieConsent;\n"+source+"\n}", ["token": token], frame, .automation)
        }
    }
    public func receive(_ message: Any, in frame: Frame, isMain: Bool) {
        guard let body = message as? [String: Any], let token = body["token"] as? String, token.count < 100 else { return }
        guard enabled && allowed() else {
            if body["type"] as? String == "ready" {
                if retainsPausedFrames { register(token, in: frame, isMain: isMain) }
                stop(token, in: frame)
            }
            return
        }
        switch body["type"] as? String {
        case "ready":
            register(token, in: frame, isMain: isMain)
        case "resume":
            resume(token, in: frame)
        case "eval":
            guard let id = body["id"] as? String, id.count < 200,
                  let snippetID = body["snippetId"] as? String, let code = rules()?.evaluations[snippetID],
                  evaluations[token, default: 0] < 250 else { return }
            if frames[token] == nil, frames.count < 64 { frames[token] = (frame, isMain) }
            guard frames[token] != nil else { return }
            evaluations[token, default: 0] += 1
            Task {
                guard enabled && allowed(), frames[token] != nil else { return }
                let current = await evaluate("const c=window.__riseCookieConsent; return c?.canAct() ? {token:c.token, documentTime:performance.timeOrigin} : null;", [:], frame, .automation) as? [String: Any]
                guard current?["token"] as? String == token, let documentTime = current?["documentTime"] as? Double,
                      documentTime.isFinite, enabled && allowed(), frames[token] != nil else { return }
                // A frame handle can survive a same-site navigation between these two IPCs.
                // Check the document again atomically in the page-world evaluation itself.
                let result = await evaluate("if (performance.timeOrigin !== documentTime) return false; let timer; try { return Boolean(await Promise.race([Promise.resolve(\(code)), new Promise(resolve => { timer=setTimeout(() => resolve(false), 5000); })])); } catch (_) { return false; } finally { clearTimeout(timer); }", ["documentTime": documentTime], frame, .page) as? Bool ?? false
                if result && snippetID.hasPrefix("RISE_") { apiActions[token, default: 0] += 1 }
                guard !id.hasPrefix("rise-"), enabled && allowed(), frames[token] != nil else { return }
                _ = await evaluate("window.__riseCookieConsent?.respond(id, result, token);", ["id": id, "result": result, "token": token], frame, .automation)
            }
        default: break
        }
    }
    public func inspect() async -> [[String: Any]] {
        var values: [[String: Any]] = []
        for (token, record) in frames {
            if var value = await evaluate("return window.__riseCookieConsent?.inspect();", [:], record.frame, .automation) as? [String: Any], value["token"] as? String == token {
                value["main"] = record.main; value["apiActions"] = apiActions[token] ?? 0; values.append(value)
            }
        }
        return values
    }
}
