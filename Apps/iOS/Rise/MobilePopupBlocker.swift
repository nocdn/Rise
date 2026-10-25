import Foundation
import WebKit

/// Independent of ad/tracker filtering. A new window needs a recent, trusted
/// activation in its own frame and may not contradict the link the user tapped.
@MainActor final class MobilePopupBlocker {
    private static let preferenceKey = "Rise.iOS.Popups.DisabledSites"
    private let preferences: UserDefaults?
    private var privateDisabledSites = Set<String>()
    private static let contexts = NSMapTable<WKWebView, Context>.weakToStrongObjects()
    private let rules: PopupDestinationRules
    let diagnostics: PopupDiagnostics

    init(preferences: UserDefaults? = .standard, rules: PopupDestinationRules = .bundled, diagnostics: PopupDiagnostics? = nil) {
        self.preferences = preferences; self.rules = rules
        self.diagnostics = diagnostics ?? PopupDiagnostics(isPrivate: preferences == nil)
    }
    private static func site(_ url: URL?) -> String? { CookieConsentPolicy.site(url) }
    func isEnabled(for url: URL?) -> Bool {
        guard let site = Self.site(url) else { return false }
        return !(preferences?.stringArray(forKey: Self.preferenceKey).map(Set.init) ?? privateDisabledSites).contains(site)
    }
    func setEnabled(_ enabled: Bool, for url: URL) {
        guard let site = Self.site(url) else { return }
        let previous = isEnabled(for: url)
        var disabled = preferences?.stringArray(forKey: Self.preferenceKey).map(Set.init) ?? privateDisabledSites
        if enabled { disabled.remove(site) } else { disabled.insert(site) }
        if let preferences { preferences.set(disabled.sorted(), forKey: Self.preferenceKey) }
        else { privateDisabledSites = disabled }
        diagnostics.record("setting.changed", source: url, details: ["enabled": String(enabled), "previouslyEnabled": String(previous), "site": site])
        for page in Self.contexts.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
            guard let context = Self.contexts.object(forKey: page), let owner = context.owner,
                  owner === self || (preferences != nil && preferences === owner.preferences),
                  (Self.site(page.url ?? context.url) ?? Self.site(context.inheritedSource)) == site else { continue }
            context.intents.removeAll(); context.popupUntil = 0
            page.configuration.preferences.javaScriptCanOpenWindowsAutomatically = !enabled
        }
    }
    func prepare(_ page: WKWebView, for url: URL?) {
        let controller = page.configuration.userContentController
        let context: Context
        if let existing = Self.contexts.object(forKey: page) { context = existing }
        else {
            context = Context()
            Self.contexts.setObject(context, forKey: page)
            controller.add(context, contentWorld: PopupIntentScript.world, name: "risePopupIntent")
            controller.add(context, contentWorld: .page, name: "risePopupObserver")
        }
        context.owner = self; context.url = url
        if !controller.userScripts.contains(where: { $0.source.hasPrefix(PopupIntentScript.marker) }) {
            controller.addUserScript(PopupIntentScript.userScript)
        }
        if !controller.userScripts.contains(where: { $0.source.hasPrefix(PopupOpenObserver.marker) }) {
            controller.addUserScript(PopupOpenObserver.userScript)
        }
        let effectiveURL = Self.site(url) != nil ? url : context.inheritedSource
        let enabled = isEnabled(for: effectiveURL)
        page.configuration.preferences.javaScriptCanOpenWindowsAutomatically = !enabled
        let prepared = (Self.site(effectiveURL) ?? "none")+"|"+String(enabled)
        if context.preparedPolicy != prepared {
            context.preparedPolicy = prepared
            log("policy.prepared", in: page, source: effectiveURL, details: ["enabled": String(enabled), "nativeAutomaticWindowsAllowed": String(!enabled), "catalogID": rules.catalogID, "rules": String(rules.count)])
        }
    }
    func didCommit(_ page: WKWebView) {
        Self.contexts.object(forKey: page)?.documentID = UUID().uuidString
        Self.contexts.object(forKey: page)?.intents.removeAll()
        Self.contexts.object(forKey: page)?.observations.removeAll()
        Self.contexts.object(forKey: page)?.observationIDs.removeAll()
        Self.contexts.object(forKey: page)?.popupUntil = 0
        noteNavigation("navigation.committed", in: page)
    }
    func protectPopup(_ page: WKWebView, openedFrom source: URL?, opener: WKWebView? = nil) {
        Self.contexts.object(forKey: page)?.popupSource = source
        Self.contexts.object(forKey: page)?.inheritedSource = source
        let parent = opener.flatMap { Self.contexts.object(forKey: $0) }
        let child = Self.contexts.object(forKey: page)
        child?.chainID = parent?.lastRequestID ?? UUID().uuidString
        page.configuration.preferences.javaScriptCanOpenWindowsAutomatically = !isEnabled(for: source)
        log("window.created", in: page, requestID: parent?.lastRequestID, source: source,
            details: ["parentPageID": parent?.pageID ?? "unknown", "persistentDataStore": String(page.configuration.websiteDataStore.isPersistent)])
    }
    func blocksPopupNavigation(to url: URL, in page: WKWebView, stage: String = "action") -> Bool {
        guard let source = Self.contexts.object(forKey: page)?.popupSource else { return false }
        let evaluation = rules.evaluate(url, from: source), blocked = isEnabled(for: source) && evaluation.blocked
        log("popup.navigation", in: page, source: source, destination: url,
            details: ["stage": stage, "allowed": String(!blocked), "reason": blocked ? "filter" : "redirect_allowed", "enabled": String(isEnabled(for: source)), "pageURL": PopupLogURL.describe(page.url) ?? "unknown"], evaluation: evaluation)
        return blocked
    }
    func allows(_ action: WKNavigationAction, in page: WKWebView) -> Bool {
        let context = Self.contexts.object(forKey: page), requestID = UUID().uuidString
        context?.lastRequestID = requestID
        let candidate = page.url ?? action.sourceFrame.request.url
        let source = Self.site(candidate) != nil ? candidate : Self.contexts.object(forKey: page)?.inheritedSource
        let now = ProcessInfo.processInfo.systemUptime
        let intent = context?.intents[Context.key(action.sourceFrame)]
        var details = requestDetails(action, in: page)
        if let intent {
            details["gestureID"] = intent.nativeID; details["gestureKind"] = intent.kind
            details["gestureAgeMs"] = String(format: "%.1f", (now-intent.time)*1000)
            details["gestureConsumed"] = String(intent.consumed)
            details["gestureDestination"] = PopupLogURL.describe(intent.href)
            details["gestureDestinationFingerprint"] = PopupLogURL.fingerprint(intent.href)
            details["gestureMethod"] = intent.method
        }
        if let observation = context?.observations[Context.key(action.sourceFrame)], now-observation.time < 2 {
            details["observationID"] = observation.id // Correlation only; never permission.
        }
        func finish(_ allowed: Bool, _ reason: String, evaluation: PopupDestinationRules.Evaluation? = nil) -> Bool {
            details["allowed"] = String(allowed); details["reason"] = reason
            log("window.decision", in: page, requestID: requestID, source: source, destination: action.request.url,
                frame: action.sourceFrame.request.url, details: details, evaluation: evaluation)
            return allowed
        }
        guard action.targetFrame == nil, let destination = action.request.url else { return finish(false, "invalid_new_window_request") }
        guard isEnabled(for: source) else { return finish(true, "protection_disabled") }
        guard let context else { return finish(false, "missing_page_context") }
        context.popupUntil = now+1.5
        let evaluation = rules.evaluate(destination, from: source)
        guard !evaluation.blocked else { return finish(false, "filter", evaluation: evaluation) }
        guard let intent else { return finish(false, "no_activation_in_source_frame", evaluation: evaluation) }
        guard !intent.consumed else { return finish(false, "gesture_already_consumed", evaluation: evaluation) }
        guard now-intent.time < 1.5 else { return finish(false, "gesture_expired", evaluation: evaluation) }
        let permitted: Bool
        switch intent.kind {
        case "link": permitted = intent.href.map { PopupDestinationRules.canonical($0) == PopupDestinationRules.canonical(destination) } ?? false
        case "form":
            if intent.method == "get", let href = intent.href {
                var expected = URLComponents(url: PopupDestinationRules.canonical(href), resolvingAgainstBaseURL: true)
                var actual = URLComponents(url: PopupDestinationRules.canonical(destination), resolvingAgainstBaseURL: true)
                expected?.query = nil; actual?.query = nil
                permitted = expected == actual
            } else { permitted = intent.href.map { PopupDestinationRules.canonical($0) == PopupDestinationRules.canonical(destination) } ?? false }
        case "button": permitted = true // JS sign-in, payment, share and export controls.
        default: permitted = false
        }
        guard permitted else {
            return finish(false, intent.kind == "none" ? "non_action_content_or_overlay" : "destination_differs_from_tapped_control", evaluation: evaluation)
        }
        intent.consumed = true
        return finish(true, "trusted_"+intent.kind, evaluation: evaluation)
    }
    /// Popunders can open the desired content and redirect the original page to an
    /// ad. Only script navigation in the short popup interval uses popup filters.
    func blocksOpenerNavigation(_ action: WKNavigationAction, in page: WKWebView) -> Bool {
        guard action.targetFrame?.isMainFrame == true, action.navigationType == .other,
              let destination = action.request.url, isEnabled(for: page.url),
              let context = Self.contexts.object(forKey: page), context.popupUntil > ProcessInfo.processInfo.systemUptime else { return false }
        let evaluation = rules.evaluate(destination, from: page.url)
        log("opener.navigation", in: page, requestID: context.lastRequestID, destination: destination,
            frame: action.sourceFrame.request.url, details: ["allowed": String(!evaluation.blocked), "reason": evaluation.blocked ? "popunder_filter" : "opener_navigation_allowed",
                "popupWindowRemainingMs": String(format: "%.1f", (context.popupUntil-ProcessInfo.processInfo.systemUptime)*1000)], evaluation: evaluation)
        return evaluation.blocked
    }
    func blocksPopupDestination(_ url: URL, from source: URL?) -> Bool {
        isEnabled(for: source) && rules.blocks(url, from: source)
    }

    func rejectWindow(_ action: WKNavigationAction, in page: WKWebView, reason: String) {
        var details = requestDetails(action, in: page)
        details["allowed"] = "false"; details["reason"] = reason
        log("window.decision", in: page, requestID: UUID().uuidString, destination: action.request.url,
            frame: action.sourceFrame.request.url, details: details)
    }
    func noteNavigation(_ event: String, in page: WKWebView, destination: URL? = nil, details: [String: String] = [:]) {
        log(event, in: page, destination: destination, details: details)
    }
    private func requestDetails(_ action: WKNavigationAction, in page: WKWebView) -> [String: String] {
        ["navigationType": String(action.navigationType.rawValue), "method": action.request.httpMethod ?? "GET",
         "sourceFrameIsMain": String(action.sourceFrame.isMainFrame), "download": String(action.shouldPerformDownload),
         "nativeAutomaticWindowsAllowed": String(page.configuration.preferences.javaScriptCanOpenWindowsAutomatically), "enabled": String(isEnabled(for: page.url))]
    }
    private func log(_ event: String, in page: WKWebView, requestID: String? = nil, source: URL? = nil,
                     destination: URL? = nil, frame: URL? = nil, details: [String: String] = [:], evaluation: PopupDestinationRules.Evaluation? = nil) {
        let context = Self.contexts.object(forKey: page)
        diagnostics.record(event, pageID: context?.pageID, documentID: context?.documentID, chainID: context?.chainID,
            requestID: requestID, source: source ?? page.url ?? context?.inheritedSource ?? context?.url, destination: destination, frame: frame, details: details, rules: evaluation)
    }

    private final class Intent {
        let nativeID = UUID().uuidString
        let id: String, kind: String, href: URL?, method: String, time: TimeInterval
        var consumed = false
        init(id: String, kind: String, href: URL?, method: String) {
            self.id = id; self.kind = kind; self.href = href; self.method = method
            time = ProcessInfo.processInfo.systemUptime
        }
    }
    private final class Context: NSObject, WKScriptMessageHandler {
        let pageID = UUID().uuidString
        var documentID = UUID().uuidString, chainID: String?, lastRequestID: String?, preparedPolicy: String?
        weak var owner: MobilePopupBlocker?
        var url: URL?, popupSource: URL?, inheritedSource: URL?, popupUntil: TimeInterval = 0
        var intents: [String: Intent] = [:]
        struct Observation { let id: String; let time: TimeInterval }
        var observations: [String: Observation] = [:]
        // Page-supplied correlation strings remain in memory only. Exports use
        // native UUIDs so a page cannot smuggle arbitrary text into an ID field.
        var observationIDs: [String: String] = [:]
        private var observerPeriod = ProcessInfo.processInfo.systemUptime, observerCount = 0, suppressed = 0
        static func key(_ frame: WKFrameInfo) -> String {
            let origin = frame.securityOrigin
            return "\(frame.isMainFrame)|\(origin.protocol)|\(origin.host)|\(origin.port)|\(frame.request.url?.absoluteString ?? "")"
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "risePopupObserver" { observe(message); return }
            guard let body = message.body as? [String: String], let id = body["id"], id.count < 128,
                  let kind = body["kind"], ["none", "link", "button", "form"].contains(kind),
                  let href = body["href"], href.count < 16384 else { return }
            let key = Self.key(message.frameInfo)
            // A later click must not replenish the allowance consumed on pointerdown.
            guard intents[key]?.id != id else { return }
            if intents.count > 128 { intents.removeAll() }
            let intent = Intent(id: id, kind: kind, href: URL(string: href), method: body["method"] ?? "")
            intents[key] = intent
            let endedRedirectProtection = popupSource != nil
            popupSource = nil // Subsequent deliberate browsing is ordinary navigation.
            owner?.diagnostics.record("gesture.captured", pageID: pageID, documentID: documentID, chainID: chainID,
                source: message.webView?.url ?? url, destination: intent.href, frame: message.frameInfo.request.url,
                details: ["gestureID": intent.nativeID, "kind": kind, "method": intent.method,
                    "sourceFrameIsMain": String(message.frameInfo.isMainFrame), "captureEvent": String((body["event"] ?? "unknown").prefix(24)),
                    "redirectProtectionEnded": String(endedRedirectProtection),
                    "classification": String((body["reason"] ?? "unknown").prefix(48)), "node": String((body["node"] ?? "unknown").prefix(24))])
        }
        private func observe(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: String], let phase = body["phase"],
                  ["ready", "attempt", "returned", "threw"].contains(phase), let id = body["id"], id.count < 128 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now-observerPeriod >= 10 {
                if suppressed > 0 {
                    owner?.diagnostics.record("observer.rate_limited", pageID: pageID, documentID: documentID,
                        source: message.webView?.url ?? url, frame: message.frameInfo.request.url,
                        details: ["suppressed": String(suppressed), "trust": "unverified_page_world"])
                }
                observerPeriod = now; observerCount = 0; suppressed = 0
            }
            guard observerCount < 100 else {
                suppressed += 1
                if suppressed == 1 { owner?.diagnostics.record("observer.rate_limited", pageID: pageID, documentID: documentID,
                    source: message.webView?.url ?? url, frame: message.frameInfo.request.url,
                    details: ["trust": "unverified_page_world", "limit": "100 messages per 10 seconds"]) }
                return
            }
            observerCount += 1
            let key = Self.key(message.frameInfo)
            let correlationKey = key+"|"+id
            if observationIDs.count > 128 { observationIDs.removeAll() }
            let observationID = observationIDs[correlationKey] ?? UUID().uuidString
            observationIDs[correlationKey] = observationID
            if phase == "attempt" {
                if observations.count > 128 { observations.removeAll() }
                observations[key] = Observation(id: observationID, time: now)
            }
            let raw = body["url"] ?? ""
            let destination = raw.count <= 8192 && !raw.isEmpty && raw != "<non-string>" ? URL(string: raw, relativeTo: message.frameInfo.request.url)?.absoluteURL : nil
            let target = ["_blank", "_self", "_parent", "_top", ""].contains(body["target"] ?? "named") ? body["target"]! : "named"
            owner?.diagnostics.record("window.open."+phase, pageID: pageID, documentID: documentID, chainID: chainID,
                source: message.webView?.url ?? url, destination: destination, frame: message.frameInfo.request.url,
                details: ["observationID": observationID, "trust": "unverified_page_world", "target": target,
                    "reportedUserActivation": body["active"] == "true" ? "true" : "false", "handle": body["handle"] == "window" ? "window" : "null_or_unspecified",
                    "sourceFrameIsMain": String(message.frameInfo.isMainFrame), "resultMeaning": phase == "returned" ? "null_does_not_prove_blocking" : "observation_only"])
        }
    }
}
