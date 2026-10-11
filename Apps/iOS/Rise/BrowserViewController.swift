import UIKit
import WebKit

/// The iOS shell owns one persistent page. Browser chrome can be added around it later.
final class BrowserViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, UIGestureRecognizerDelegate {
    static let homeURL = URL(string: "https://news.ycombinator.com/")!
    private(set) var webView: WKWebView
    /// Pages an expanded Peek replaced, most recent last, held for Back as on the Mac.
    private(set) var previousPages: [WKWebView] = []
    private lazy var backSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swipeBack))
    private let startURL: URL?
    private let allowsPeek: Bool

    init(startURL: URL? = BrowserViewController.homeURL, allowsPeek: Bool = true) {
        self.startURL = startURL
        self.allowsPeek = allowsPeek
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Honor the focus-zoom cap in our viewport script while still allowing manual pinch zoom.
        configuration.ignoresViewportScaleLimits = true
        configuration.userContentController.addUserScript(InputZoomPolicy.userScript)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        adoptDelegates(of: webView)
    }

    private func adoptDelegates(of webView: WKWebView) {
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void) {
        guard allowsPeek, let url = elementInfo.linkURL, Self.canPeek(url) else {
            // Keep WebKit's suggested actions for images, external schemes, and links inside Peek.
            completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { actions in
                UIMenu(children: actions)
            })
            return
        }
        // nil can fall back to WebKit's Data Detectors link preview. An explicit empty
        // configuration suppresses that preview without replacing WebKit's link hit testing.
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in nil })
        // Let WebKit finish resolving its menu before presenting our interactive sheet.
        DispatchQueue.main.async { [weak self] in self?.showPeek(url) }
    }

    static func canPeek(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    func showPeek(_ url: URL) {
        guard allowsPeek, Self.canPeek(url), viewIfLoaded?.window != nil,
              presentedViewController == nil else { return }
        let peek = PeekViewController(url: url) { [weak self] page in self?.adopt(page) }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        present(peek, animated: true)
    }

    required init?(coder: NSCoder) { fatalError("Use init(startURL:)") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        install(webView)
        backSwipe.edges = .left
        backSwipe.delegate = self
        view.addGestureRecognizer(backSwipe)
    }

    /// Moves a page straight from wherever it is: removing it first would take it out of the
    /// window for a moment, and WebKit would drop its painted content and flash.
    private func install(_ page: WKWebView) {
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(page)
        page.frame = view.bounds
    }

    /// Makes an expanded Peek's live page this page, without loading it again.
    func adopt(_ page: WKWebView) {
        guard page !== webView else { return }
        page.transform = .identity
        install(page)
        webView.removeFromSuperview()
        previousPages.append(webView)
        adoptDelegates(of: page)
        webView = page
    }

    /// Back past the start of an adopted page's history returns to the page it replaced.
    func returnToPreviousPage() {
        guard let previous = previousPages.popLast() else { return }
        previous.transform = .identity
        install(previous)
        webView.removeFromSuperview()
        webView = previous
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // WebKit's own swipe handles Back within the page's history.
        gestureRecognizer !== backSwipe || (!previousPages.isEmpty && !webView.canGoBack)
    }

    /// Slides the page off to the right over the previous one, as WebKit's Back swipe does.
    @objc private func swipeBack(_ swipe: UIScreenEdgePanGestureRecognizer) {
        guard let previous = previousPages.last else { return }
        let width = max(1, view.bounds.width)
        let distance = max(0, swipe.translation(in: view).x)
        let place = { [weak self] (progress: CGFloat) in
            self?.webView.transform = CGAffineTransform(translationX: progress*width, y: 0)
            previous.transform = CGAffineTransform(translationX: -(1-progress)*width/3, y: 0)
        }
        switch swipe.state {
        case .began:
            previous.frame = view.bounds
            view.insertSubview(previous, belowSubview: webView)
            place(distance/width)
        case .changed:
            place(distance/width)
        case .ended, .cancelled, .failed:
            let velocity = swipe.velocity(in: view).x
            let back = swipe.state == .ended && (velocity > 500 || distance > width/3 && velocity > -200)
            let remaining = back ? width-distance : distance
            UIView.animate(springDuration: 0.3, bounce: 0, initialSpringVelocity: abs(velocity)/max(1, remaining),
                           delay: 0, options: [.beginFromCurrentState]) {
                place(back ? 1 : 0)
            } completion: { [weak self] _ in
                guard let self else { return }
                if back { returnToPreviousPage() } else { previous.removeFromSuperview(); previous.transform = .identity }
            }
        default: break
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let startURL { webView.load(URLRequest(url: startURL)) }
    }

    // With no tab UI yet, links requesting a new window navigate this page instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if DEBUG
        if webView.url == Self.homeURL { print("Rise iOS: Hacker News loaded") }
        #endif
    }
}
