#if DEBUG
import UIKit
import WebKit

@MainActor enum GitHubStarAudit {
    static let argument = "-RiseGitHubStarAudit"
    static let deviceArgument = "-RiseGitHubStarDeviceAudit"
    struct Failure: Error { let name: String }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("GitHubStarAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(browser, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    private static func exercise(_ browser: BrowserViewController, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) throws {
            checks[name] = value
            try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys, .prettyPrinted]).write(to: folder.appendingPathComponent("checks.json"))
            if !value { throw Failure(name: name) }
        }
        func wait(_ name: String, seconds: Double = 12, _ ready: () async -> Bool) async throws {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                if await ready() { try check(name, true); return }
                try await Task.sleep(for: .milliseconds(30))
            }
            try check(name, false)
        }
        func capture(_ name: String) throws {
            let window = browser.view.window!
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        func repository(_ name: String) -> GitHubRepository { .init(url: URL(string: "https://github.com/owner/\(name)"))! }
        func gestureTest() async throws {
            let tracking = GitHubStarToast(repository: repository("gesture"))
            browser.githubStarToast = tracking
            tracking.onDismiss = { [weak browser] in browser?.githubStarToast = nil }
            browser.view.insertSubview(tracking, belowSubview: browser.bottomBar)
            tracking.place(above: browser.bottomBar.frame.minY, in: browser.view.bounds, safeTop: browser.view.safeAreaInsets.top)
            tracking.appear()
            let hit = browser.view.hitTest(tracking.center, with: nil)
            try check("the-visible-toast-receives-native-touches", hit === tracking || hit?.isDescendant(of: tracking) == true)
            try "Ready".write(to: folder.appendingPathComponent("gesture-ready.txt"), atomically: true, encoding: .utf8)
            try await wait("native-downward-swipe-dismisses-the-loading-toast", seconds: 90) { tracking.dismissed }
            try await wait("native-dismissal-stops-its-frame-rate-request") { tracking.superview == nil && !tracking.motion.isHoldingRate }
        }
        let store = browser.webView.configuration.websiteDataStore
        browser.overrideUserInterfaceStyle = .light
        browser.view.layoutIfNeeded()
        try check("link-peek-is-hard-disabled-without-removing-native-actions", !BrowserViewController.longPressPeekEnabled && browser.webView.allowsLinkPreview)
        try check("the-provided-vector-star-is-installed", UIImage(named: "GitHubStar") != nil)
        if ProcessInfo.processInfo.arguments.contains("-RiseGitHubToastGestureAudit") { try await gestureTest(); return }
        if ProcessInfo.processInfo.arguments.contains(deviceArgument) {
            try check("the-physical-browser-session-is-signed-in-to-github", await MobileGitHubStarrer.signedIn(store: store))
            if ProcessInfo.processInfo.arguments.contains("-RiseGitHubUnstarDeviceAudit") {
                try await GitHubUnstarAudit.device(browser,check: check)
                return
            }
            let target = GitHubRepository(url: URL(string: "https://github.com/nocdn/Rise"))!
            browser.starGitHubRepository(target, store: store)
            let toast = browser.githubStarToast!
            try await wait("the-physical-github-request-finishes", seconds: 65) { toast.completed }
            try browser.githubStarrer.diagnostics.joined(separator: "\n").write(to: folder.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
            try String(describing: toast.outcome).write(to: folder.appendingPathComponent("outcome.txt"), atomically: true, encoding: .utf8)
            try check("github-server-confirms-the-star", toast.outcome == .starred || toast.outcome == .alreadyStarred)
            try capture("device-starred")
            try check("one-success-haptic-after-verification", browser.githubStarToast?.successFeedbackCount == 1)
            return
        }
        let fixture = try GitHubStarHTTPFixture(); try await fixture.start()
        defer { fixture.stop(); browser.githubStarrer.cancelAll() }
        let starrer = browser.githubStarrer
        starrer.origin = fixture.url; starrer.loadTimeout = 3; starrer.verificationTimeout = 1.3
        func cookie(_ domain: String, _ name: String, _ value: String, expires: Date? = nil) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: "/", .name: name, .value: value]
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)!
        }
        let loggedIn = cookie(".github.com", "logged_in", "yes")
        try check("recognises-githubs-login-marker", MobileGitHubStarrer.signedIn(cookies: [loggedIn]))
        try check("does-not-mistake-lookalike-domains-for-a-session", !MobileGitHubStarrer.signedIn(cookies: [cookie("notgithub.com", "logged_in", "yes"), cookie("github.com.evil.test", "logged_in", "yes")]))
        try check("signed-out-and-expired-markers-are-not-authenticated", !MobileGitHubStarrer.signedIn(cookies: [cookie("github.com", "logged_in", "no"), cookie("github.com", "logged_in", "yes", expires: .distantPast)]))
        try check("an-empty-cookie-store-has-no-star-action", !(await MobileGitHubStarrer.signedIn(store: store)))
        await store.httpCookieStore.setCookie(loggedIn)
        await store.httpCookieStore.setCookie(cookie("127.0.0.1", "fixture_session", "allowed"))
        try check("native-menu-check-reads-the-held-links-cookie-store", await MobileGitHubStarrer.signedIn(store: store))
        if ProcessInfo.processInfo.arguments.contains("-RiseGitHubMenuPreview") {
            starrer.loadTimeout = 10
            fixture.setReadDelay("native-menu",5)
            let markup = "<meta name='viewport' content='width=device-width,initial-scale=1'><body style='font:22px system-ui;padding:30px;background:#f7f7f2'><h2>GitHub repository</h2><p><a href='https://github.com/owner/native-menu'>Star this repository</a></p><p>Native link actions, with no page preview.</p></body>"
            browser.webView.loadHTMLString(markup, baseURL: fixture.url)
            try "Ready".write(to: folder.appendingPathComponent("menu-ready.txt"), atomically: true, encoding: .utf8)
            try await wait("real-native-context-action-stars-the-held-repository", seconds: 120) { fixture.isStarred("native-menu") }
            try await wait("real-native-context-action-unstars-the-held-repository", seconds: 120) { !fixture.isStarred("native-menu") }
            try await Task.sleep(for: .seconds(2))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-RiseGitHubUnstarAudit") {
            try await GitHubUnstarAudit.exercise(browser,fixture: fixture,check: check)
            return
        }
        let privateStore = WKWebsiteDataStore.nonPersistent()
        try check("normal-sign-in-does-not-leak-to-private-browsing", !(await MobileGitHubStarrer.signedIn(store: privateStore)))
        let suggested = UIAction(title: "Copy link") { _ in }
        let ordinary = browser.nativeLinkMenu(in: browser.webView, url: URL(string: "https://example.com/a/b"), actions: [suggested])
        try check("ordinary-links-keep-their-native-actions", ordinary.children.count == 1 && ordinary.children.first === suggested)
        let menu = browser.nativeLinkMenu(in: browser.webView, url: URL(string: "https://github.com/owner/react/issues/4"), actions: [suggested])
        try check("repository-actions-keep-the-native-actions", menu.children.count == 2 && menu.children.first === suggested && menu.children.last is UIMenu)
        let menuState = browser.githubRepositoryMenu!
        let loading = menuState.action()
        try check("checking-row-is-disabled-with-the-static-star",loading.title == "Checking status..." && loading.attributes.contains(.disabled) && loading.image?.isEqual(UIImage(named: "GitHubStarMenu")) == true && loading.image?.images == nil)
        try await wait("menu-resolves-the-current-state") { menuState.status != nil }
        try check("opening-the-menu-is-read-only",fixture.postCount("react") == 0 && menuState.status == .unstarred)
        try check("unstarred-repository-keeps-the-same-star-and-enables-the-row",menuState.action().title == "Star repository" && menuState.action().identifier == loading.identifier && menuState.action().image?.isEqual(loading.image) == true && !menuState.action().attributes.contains(.disabled))
        try check("result-ready-before-presentation-never-leaves-a-loading-placeholder",(menuState.element().children.first as? UIAction)?.title == "Star repository")
        menuState.cancel(); browser.githubRepositoryMenu = nil
        for name in ["react", "hydration", "form", "delayed", "labelled"] {
            let outcome = await starrer.star(repository(name), store: store, host: browser.view)
            try check("\(name)-requires-a-fresh-server-confirmation", outcome == .starred && fixture.isStarred(name))
            try check("\(name)-clicks-star-exactly-once", fixture.postCount(name) == 1)
            try check("\(name)-removes-hidden-webviews-and-timers", starrer.isIdle)
        }
        let already = await starrer.star(repository("already"), store: store, host: browser.view)
        try check("already-starred-never-clicks-unstar", already == .alreadyStarred && fixture.postCount("already") == 0)
        let again = await starrer.star(repository("react"), store: store, host: browser.view)
        try check("repeating-a-completed-request-is-idempotent", again == .alreadyStarred && fixture.postCount("react") == 1)
        async let duplicateA = starrer.star(repository("duplicate"), store: store, host: browser.view)
        async let duplicateB = starrer.star(repository("duplicate"), store: store, host: browser.view)
        let duplicate = await (duplicateA, duplicateB)
        try check("simultaneous-requests-share-a-single-mutation", duplicate.0 == .starred && duplicate.1 == .starred && fixture.postCount("duplicate") == 1)
        async let queuedA = starrer.star(repository("queue-a"), store: store, host: browser.view)
        async let queuedB = starrer.star(repository("queue-b"), store: store, host: browser.view)
        let queued = await (queuedA, queuedB)
        try check("different-repositories-are-queued-without-dropping-a-request", queued.0 == .starred && queued.1 == .starred && fixture.postCount("queue-a") == 1 && fixture.postCount("queue-b") == 1)
        let signedOut = await starrer.star(repository("signed-out"), store: privateStore, host: browser.view)
        try check("signed-out-requests-cannot-borrow-the-normal-session", signedOut == .signedOut && fixture.postCount("signed-out") == 0)
        await privateStore.httpCookieStore.setCookie(cookie("127.0.0.1", "fixture_session", "allowed"))
        let privateOutcome = await starrer.star(repository("private"), store: privateStore, host: browser.view)
        try check("a-private-session-can-use-its-own-cookies", privateOutcome == .starred && fixture.postCount("private") == 1)
        for (name, expected) in [("missing", MobileGitHubStarrer.Outcome.notFound), ("expired", .signedOut), ("server-error", .failed), ("redirect", .failed), ("reject", .failed)] {
            let outcome = await starrer.star(repository(name), store: store, host: browser.view)
            try check("\(name)-does-not-report-success", outcome == expected && !fixture.isStarred(name))
            try check("\(name)-cleans-up-after-failure", starrer.isIdle)
        }
        try check("optimistic-react-updates-cannot-hide-a-rejected-mutation", fixture.postCount("reject") == 1)
        let start = CACurrentMediaTime()
        starrer.loadTimeout = 0.3
        let timeout = await starrer.star(repository("hang"), store: store, host: browser.view)
        try check("unresponsive-pages-time-out-and-release-the-worker", timeout == .failed && starrer.isIdle && CACurrentMediaTime()-start < 2)
        starrer.loadTimeout = 3
        let cancel = Task { await starrer.star(repository("hang"), store: store, host: browser.view) }
        try await Task.sleep(for: .milliseconds(100)); starrer.cancelAll()
        let cancelled = await cancel.value
        try check("cancelling-resumes-pending-work-and-destroys-its-webview", cancelled == .cancelled && starrer.isIdle)
        let detached = await starrer.star(repository("detached"), store: store, host: UIView())
        try check("detached-browser-does-not-launch-an-invisible-request", detached == .cancelled && fixture.postCount("detached") == 0)
        let action = browser.githubStarAction(repository("toast"), store: store)
        try check("native-menu-action-has-the-requested-label-and-star", action.title == "Star repository" && action.image != nil)
        let button = UIButton(); button.addAction(action, for: .primaryActionTriggered); button.sendActions(for: .primaryActionTriggered)
        try await wait("native-action-starts-the-loading-toast") { browser.githubStarToast != nil }
        let toast = browser.githubStarToast!
        try check("toast-has-the-translation-spinner-in-the-text-colour", toast.symbol.symbolName == "github-starring" && toast.symbol.tintColor == .white && toast.label.textColor == .white)
        try check("toast-is-centered-and-emerges-from-behind-the-button-bar", abs(toast.center.x-browser.view.bounds.midX) < 0.1 && browser.view.subviews.firstIndex(of: toast)! < browser.view.subviews.firstIndex(of: browser.bottomBar)!)
        try check("toast-requests-120-hz-compositor-animation", toast.layer.animation(forKey: "toast.appear")?.preferredFrameRateRange.preferred == Float(min(120, browser.view.window!.screen.maximumFramesPerSecond)) && toast.motion.isHoldingRate)
        try await Task.sleep(for: .milliseconds(100)); try capture("loading-toast")
        try await wait("verified-success-swaps-spinner-to-the-provided-star") { toast.symbol.symbolName == "github-star" }
        try check("verified-success-has-one-success-haptic", toast.successFeedbackCount == 1 && toast.completed)
        toast.finish(.starred)
        try check("duplicate-completions-do-not-repeat-feedback", toast.successFeedbackCount == 1)
        try await Task.sleep(for: .milliseconds(400)); try capture("success-toast")
        toast.dismiss()
        try await wait("dismissal-removes-toast-and-frame-rate-lease") { browser.githubStarToast == nil && !toast.motion.isHoldingRate }
        let errorToast = GitHubStarToast(repository: repository("error"))
        browser.view.insertSubview(errorToast, belowSubview: browser.bottomBar)
        errorToast.place(above: browser.bottomBar.frame.minY, in: browser.view.bounds, safeTop: browser.view.safeAreaInsets.top)
        errorToast.appear(); errorToast.finish(.failed)
        try check("errors-use-the-smaller-short-stemmed-vector-exclamation", errorToast.symbol.symbolName == "github-star-error" && UIImage(named: "GitHubToastError") != nil)
        try check("failures-never-play-a-success-haptic", errorToast.successFeedbackCount == 0)
        errorToast.dismiss(animated: false)
        let resizing = GitHubStarToast(repository: repository("resize"))
        browser.view.insertSubview(resizing, belowSubview: browser.bottomBar)
        resizing.place(above: browser.bottomBar.frame.minY, in: browser.view.bounds, safeTop: browser.view.safeAreaInsets.top)
        resizing.layoutIfNeeded()
        let initialWidth = resizing.bounds.width, fixedCenter = resizing.center.x
        resizing.finish(.alreadyStarred)
        let finalWidth = resizing.bounds.width
        try await Task.sleep(for: .milliseconds(80))
        let intermediateWidth = resizing.layer.presentation()?.bounds.width ?? finalWidth
        try check("content-width-eases-between-the-old-and-new-width", intermediateWidth > min(initialWidth, finalWidth)+0.5 && intermediateWidth < max(initialWidth, finalWidth)-0.5)
        try check("resizing-stays-horizontally-centered", abs(resizing.center.x-fixedCenter) < 0.1)
        try check("the-shadow-resizes-with-the-toast", resizing.layer.animation(forKey: "toast.width-shadow") != nil)
        resizing.dismiss(animated: false)
    }
}
#endif
