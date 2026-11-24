#if DEBUG
import UIKit
import WebKit
import Network
import ObjectiveC

@MainActor enum LinkPreviewAudit {
    static let argument = "-RiseLinkPreviewAudit"
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("LinkPreviewAudit")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var checks: [String: Bool] = [:]
            @MainActor func check(_ name: String, _ value: Bool) throws {
                checks[name] = value
                try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
                if !value { throw NSError(domain: name, code: 1) }
            }
            @MainActor func wait(_ name: String, seconds: Double = 12, _ ready: @MainActor () async throws -> Bool) async throws {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    if try await ready() { try check(name, true); return }
                    try await Task.sleep(for: .milliseconds(30))
                }
                try check(name, false)
            }
            do {
                let automatic = ProcessInfo.processInfo.arguments.contains("-RiseLinkPreviewAutoAudit")
                let fixture = try LinkPreviewFixture(holdArticle: automatic); try await fixture.start()
                defer { fixture.stop() }
                let source = browser.webView
                source.load(URLRequest(url: fixture.url.appendingPathComponent("home")))
                try await wait("source-page-ready") { try await source.evaluateJavaScript("document.querySelector('#preview-link') !== null") as? Bool == true }
                let originalURL = source.url, count = browser.tabs.count
                try "Ready".write(to: folder.appendingPathComponent("ready.txt"), atomically: true, encoding: .utf8)
                var automaticMenu: LinkPreviewAuditMenu?
                defer { automaticMenu?.host.removeFromSuperview() }
                if automatic {
                    // Present the same app configuration in UIKit directly. This
                    // exercises real native layout/hit testing without synthetic HID
                    // or requiring the missing Simulator desktop application.
                    let menu = LinkPreviewAuditMenu(browser: browser, source: source, url: fixture.url.appendingPathComponent("article"))
                    automaticMenu = menu
                    browser.view.addSubview(menu.host)
                    menu.host.frame = CGRect(x: 24, y: 200, width: 300, height: 60)
                    let selector = NSSelectorFromString("_presentMenuAtLocation:")
                    guard let method = class_getInstanceMethod(type(of: menu.interaction), selector) else { throw NSError(domain: "No native menu presenter", code: 1) }
                    typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
                    let present = unsafeBitCast(method_getImplementation(method), to: Present.self)
                    present(menu.interaction, selector, CGPoint(x: 150, y: 30))
                }
                // The UI check uses an actual native long press and swipes through Agent Desktop.
                try await wait("native-menu-has-a-live-preview", seconds: 180) { browser.linkPreview?.viewIfLoaded?.window != nil }
                let preview = browser.linkPreview!
                if let automaticMenu {
                    try await wait("preview-request-is-loading") { preview.page.isLoading }
                    try await Task.sleep(for: .milliseconds(650))
                    let scrolled = try automaticMenu.expandAndScroll(preview)
                    fixture.releaseArticle()
                    try await wait("scrolled-preview-finishes-loading") { !preview.page.isLoading }
                    try check("loading-keeps-the-preview-and-menu-position", scrolled.matches(automaticMenu.geometry(preview)))
                    try check("refresh-updates-the-native-menu", InteractiveLinkMenu.updateVisibleMenu(on: automaticMenu.interaction) { menu in
                        menu.replacingChildren(menu.children.dropLast() + [UIAction(title: "Star repository") { _ in }])
                    })
                    try check("refresh-keeps-the-preview-and-menu-position", scrolled.matches(automaticMenu.geometry(preview)))
                    try await Task.sleep(for: .milliseconds(500))
                    try check("the-menu-stays-scrolled-after-refresh", scrolled.matches(automaticMenu.geometry(preview)))
                    try check("the-updated-action-remains-visible", automaticMenu.isActionVisible("Star repository", in: preview))
                }
                try await wait("preview-article-loaded") { try await preview.page.evaluateJavaScript("document.querySelector('#counter') !== null") as? Bool == true }
                try check("preview-shares-source-data-store", preview.page.configuration.websiteDataStore === source.configuration.websiteDataStore)
                try check("preview-shares-source-session-cookie", try await preview.page.evaluateJavaScript("document.cookie.includes('rise_preview=approved')") as? Bool == true)
                try check("preview-keeps-source-page-and-tabs", browser.tabs.count == count && source.url == originalURL)
                let webkitMenus = InteractiveLinkMenu.interactions(in: source)
                try check("webkits-own-link-interaction-gets-the-scoped-hook", !webkitMenus.isEmpty && webkitMenus.allSatisfy { NSStringFromClass(type(of: $0)).hasPrefix("RiseInteractiveLinkMenu_") })
                try await Task.sleep(for: .milliseconds(700))
                let window = preview.page.window!
                let point = preview.page.convert(CGPoint(x: preview.page.bounds.midX, y: preview.page.bounds.midY), to: window)
                let hit = window.hitTest(point, with: nil)
                try check("native-preview-delivers-touches-to-web-content", hit === preview.page || hit?.isDescendant(of: preview.page) == true)
                if automatic {
                    try check("preview-page-buttons-run-in-place", try await preview.page.evaluateJavaScript("document.querySelector('#counter').click(); window.count") as? Int == 1)
                }
                if automatic {
                    let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    try capture.pngData()?.write(to: folder.appendingPathComponent("native-preview.png"))
                    preview.page.scrollView.setContentOffset(CGPoint(x: 0, y: 450), animated: true)
                }
                try await wait(automatic ? "live-preview-scrolls-with-native-menu-still-open" : "native-swipe-scrolls-the-preview", seconds: 120) { preview.page.scrollView.contentOffset.y > 100 }
                try check("scrolling-does-not-commit-or-dismiss-menu", browser.linkPreview === preview && browser.isLinkContextMenuOpen)
                try check("source-remains-at-its-original-scroll-position", source.scrollView.contentOffset.y < 1)
                try check("preview-does-not-enter-history", !browser.addressSuggestions.history.entries.contains(where: { URL(string: $0.url)?.path.hasPrefix("/article") == true }))
                try "Scroll verified".write(to: folder.appendingPathComponent("scroll-verified.txt"), atomically: true, encoding: .utf8)
                if automatic {
                    try await Task.sleep(for: .milliseconds(350))
                    let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    try capture.pngData()?.write(to: folder.appendingPathComponent("native-preview-scrolled.png"))
                    automaticMenu?.interaction.dismissMenu()
                }
                try await wait("native-menu-dismisses", seconds: 120) { browser.linkPreview == nil }
                try check("dismissing-stops-preview-loading-and-releases-delegates", preview.stopped && preview.page.navigationDelegate == nil && preview.page.uiDelegate == nil)
                try check("dismissing-restores-original-page", source.url == originalURL && browser.tabs.count == count)
                let privateSource = BrowserViewController.makeWebView(dataStore: .nonPersistent())
                let privatePreview = LinkPreviewController(url: fixture.url.appendingPathComponent("article"), source: privateSource, blocker: MobileAdBlocker(preferences: nil), videoPlayback: .shared)
                try check("private-preview-keeps-its-nonpersistent-session", !privatePreview.page.configuration.websiteDataStore.isPersistent && privatePreview.page.configuration.websiteDataStore === privateSource.configuration.websiteDataStore)
                try check("private-preview-never-uses-regular-session", privatePreview.page.configuration.websiteDataStore !== source.configuration.websiteDataStore)
                privatePreview.stop(); privatePreview.stop()
                try check("cancellation-is-idempotent-before-presentation", privatePreview.stopped)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Only the no-HID audit uses this host. Normal link menus remain WebKit's own.
@MainActor private final class LinkPreviewAuditMenu: NSObject, UIContextMenuInteractionDelegate {
    let host = UIView()
    private let browser: BrowserViewController
    private let source: WKWebView
    private let url: URL
    lazy var interaction = UIContextMenuInteraction(delegate: self)
    init(browser: BrowserViewController, source: WKWebView, url: URL) {
        self.browser = browser; self.source = source; self.url = url
        super.init()
        host.addInteraction(interaction)
    }
    struct Geometry {
        let preview: CGRect
        let menu: CGRect
        let offset: CGPoint

        func matches(_ other: Geometry?) -> Bool {
            guard let other else { return false }
            let differences = [
                preview.minX - other.preview.minX, preview.minY - other.preview.minY,
                preview.width - other.preview.width, preview.height - other.preview.height,
                menu.minX - other.menu.minX, menu.minY - other.menu.minY,
                menu.width - other.menu.width, menu.height - other.menu.height,
                offset.x - other.offset.x, offset.y - other.offset.y
            ]
            return differences.allSatisfy { abs($0) < 0.5 }
        }
    }
    private func view(in root: UIView, matching matches: (UIView) -> Bool) -> UIView? {
        if matches(root) { return root }
        for child in root.subviews {
            if let match = view(in: child, matching: matches) { return match }
        }
        return nil
    }
    private func actionList(in window: UIWindow) -> UICollectionView? {
        guard let list = view(in: window, matching: { NSStringFromClass(type(of: $0)) == "_UIContextMenuListView" }) else { return nil }
        // UIKit temporarily adds a second collection view during a row replacement.
        return view(in: list, matching: { $0 is UICollectionView }) as? UICollectionView
    }
    func geometry(_ preview: LinkPreviewController) -> Geometry? {
        guard let window = preview.page.window, let list = actionList(in: window),
              let menu = view(in: window, matching: { NSStringFromClass(type(of: $0)) == "_UIContextMenuView" }) else { return nil }
        return Geometry(preview: preview.page.convert(preview.page.bounds, to: window),
                        menu: menu.convert(menu.bounds, to: window), offset: list.contentOffset)
    }
    func isActionVisible(_ title: String, in preview: LinkPreviewController) -> Bool {
        guard let window = preview.page.window, let list = actionList(in: window),
              let label = view(in: list, matching: { ($0 as? UILabel)?.text == title }) else { return false }
        return window.bounds.contains(label.convert(label.bounds, to: window))
    }
    func expandAndScroll(_ preview: LinkPreviewController) throws -> Geometry {
        func get(_ obj: NSObject, _ name: String) -> NSObject? {
            let selector = NSSelectorFromString(name)
            return obj.responds(to: selector) ? obj.perform(selector)?.takeUnretainedValue() as? NSObject : nil
        }
        let moveSelector = NSSelectorFromString("moveToDetentPosition:updateScrubPath:")
        guard let before = geometry(preview), let window = preview.page.window,
              let list = actionList(in: window),
              let presentations = get(interaction, "presentationsByIdentifier") as? NSDictionary,
              let presentation = presentations.allValues.first as? NSObject,
              let controller = get(presentation, "uiController"),
              let pan = get(controller, "platterPanController"),
              pan.responds(to: moveSelector) else { throw NSError(domain: "Native menu layout unavailable", code: 1) }
        typealias Move = @convention(c) (NSObject, Selector, Int, Bool) -> Void
        let move = unsafeBitCast(pan.method(for: moveSelector), to: Move.self)
        // Choose the same expanded position reached by swiping up in the action list.
        NativeMenuLoading.withoutAnimation { move(pan, moveSelector, 0, false) }
        let inset = list.adjustedContentInset
        let bottom = list.contentSize.height + inset.bottom - list.bounds.height
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: bottom), animated: false)
        guard let after = geometry(preview), after.preview.height < before.preview.height,
              after.menu.minY < before.menu.minY, after.offset.y > before.offset.y else {
            throw NSError(domain: "Native menu did not expand and scroll", code: 1)
        }
        return after
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let configuration = browser.linkPreviewConfiguration(for: url, in: source)
        InteractiveLinkMenu.setEnabled(true, on: interaction)
        return configuration
    }
    @objc(_contextMenuInteraction:overrideSuggestedActionsForConfiguration:)
    func suggestedActions(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration) -> [UIMenuElement] {
        [UIAction(title: "Open Link", image: UIImage(systemName: "arrow.up.right.square")) { _ in },
         UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in },
         UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in }]
            + (1...9).map { index in UIAction(title: "Test action \(index)") { _ in } }
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        browser.beginLinkContextMenu(in: source)
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        browser.endLinkContextMenu(in: source)
    }
}

private final class LinkPreviewFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.LinkPreviewAudit.HTTP")
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }
    private var holdArticle: Bool
    private var articleResponse: (() -> Void)?
    init(holdArticle: Bool) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.holdArticle = holdArticle
    }
    func releaseArticle() {
        queue.async {
            self.holdArticle = false
            self.articleResponse?()
            self.articleResponse = nil
        }
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.serve($0) }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            let request = String(decoding: data, as: UTF8.self)
            let article = request.hasPrefix("GET /article")
            let content = article ? """
            <h1>Interactive article preview</h1><p>This is a live web page inside the native menu.</p>
            <button id=counter onclick="this.textContent='Clicked '+(++window.count)">Tap to count</button>
            <script>window.count=0</script>
            \((1...50).map { "<h2>Section \($0)</h2><p>Scroll this preview. The link menu and original page stay in place.</p>" }.joined())
            """ : """
            <h1>Link preview check</h1><p>Hold the link below, then scroll the page inside the preview.</p>
            <a id=preview-link href='/article' style='display:block;padding:24px 0'>Preview this article</a>
            <p>The original page must stay here.</p><a href='https://github.com/nocdn/Rise'>GitHub repository menu</a>
            """
            let html = "<meta name=viewport content='width=device-width,initial-scale=1'><body style='font:18px -apple-system;padding:20px;background:#f5f4ef;color:#202020'>\(content)</body>"
            let body = Data(html.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nSet-Cookie: rise_preview=approved; Path=/; SameSite=Lax\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            let send = { connection.send(content: Data(header.utf8)+body, completion: .contentProcessed { _ in connection.cancel() }) }
            if article, holdArticle { articleResponse = send }
            else { send() }
        }
    }
}
#endif
