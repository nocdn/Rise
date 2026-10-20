import UIKit
import WebKit

/// An independent live page: dismissing it leaves the original page and scroll position intact.
/// It has no bar: swiping the handle down closes it and swiping up makes it the page.
final class PeekViewController: UIViewController, UIViewControllerTransitioningDelegate {
    /// The strip above the page that holds the handle, tinted to continue the page's top.
    static let headerHeight: CGFloat = 16
    /// The handle's invisible touch area, which reaches a little into the page.
    static let handleTouchSize = CGSize(width: 120, height: 28)

    let browser: BrowserViewController
    let handle = PeekHandle()
    let header = UIView()
    private let onExpand: @MainActor (WKWebView, UIColor?) -> Void
    private var headerHeight = PeekViewController.headerHeight
    private lazy var tint = PageEdgeTint { [weak self] color in self?.setHeaderColor(color) }
    /// The colour of the strip above the page, which continues the page's top edge.
    var topColor: UIColor? { tint.color }

    /// `onExpand` receives the live page once the card has grown to fill the window, with the
    /// colour of its top edge.
    init(url: URL, isPrivateBrowsing: Bool = false, websiteDataStore: WKWebsiteDataStore? = nil,
         adBlocker: MobileAdBlocker = .shared, videoPlayback: VideoPlaybackPolicy = .shared,
         onExpand: @escaping @MainActor (WKWebView, UIColor?) -> Void) {
        browser = BrowserViewController(startURL: url, allowsPeek: false, adBlocker: adBlocker,
                                        isPrivateBrowsing: isPrivateBrowsing, websiteDataStore: websiteDataStore, videoPlayback: videoPlayback)
        self.onExpand = onExpand
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("Use init(url:onExpand:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        header.backgroundColor = .systemBackground
        addChild(browser)
        view.addSubview(browser.view)
        browser.didMove(toParent: self)
        view.addSubview(header)
        view.addSubview(handle)
        handle.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Close") { [weak self] _ in self?.dismiss(animated: true); return true },
            UIAccessibilityCustomAction(name: "Open as page") { [weak self] _ in self?.openInMainPage(); return true },
        ]

        tint.track(browser.webView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        browser.view.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: bounds.height-headerHeight)
        let touch = Self.handleTouchSize
        handle.frame = CGRect(x: (bounds.width-touch.width)/2, y: 0, width: touch.width, height: touch.height)
        view.bringSubviewToFront(header)
        view.bringSubviewToFront(handle)
    }

    /// Whether a drag from this point, in the card's coordinates, moves the card itself.
    func isOnHandle(_ point: CGPoint) -> Bool {
        header.frame.contains(point) || handle.frame.contains(point)
    }

    /// As the card grows to fill the window, its strip becomes the strip behind the status bar
    /// that the main page shows, so the page lands exactly where it will stay. The page resizes
    /// inside the animation, so WebKit sizes and paints it for where the card will end up.
    /// Call `layoutIfNeeded` inside the animation.
    func prepareToFill(statusBarHeight: CGFloat) {
        headerHeight = statusBarHeight
        view.setNeedsLayout()
    }

    /// Grows the card into the page, which keeps its history, scroll position and forms.
    func openInMainPage() {
        (presentationController as? PeekPresentationController)?.expand()
    }

    /// Hands the live page to the page underneath, then leaves without animating: the card is
    /// already covering the window, so the switch is invisible.
    func becomePage() {
        onExpand(browser.webView, topColor)
        dismiss(animated: false)
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    private func setHeaderColor(_ color: UIColor) {
        guard color != header.backgroundColor else { return }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.header.backgroundColor = color
            self.view.backgroundColor = color
        }
        handle.onDarkBackground = PageEdgeColor.isDark(color)
    }

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?,
                                source: UIViewController) -> UIPresentationController? {
        let sheet = PeekPresentationController(presentedViewController: presented, presenting: presenting)
        sheet.scrollView = browser.webView.scrollView
        sheet.onExpand = { [weak self] in self?.becomePage() }
        return sheet
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        PeekSheetAnimator(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        PeekSheetAnimator(presenting: false)
    }
}

/// The pill at the top of a Peek. Holding it lengthens and darkens it with the springs of the
/// Mac's split handle; the view itself is a larger, invisible touch area around the pill.
final class PeekHandle: UIView {
    static let thickness: CGFloat = 4
    static let restingLength: CGFloat = 36, pressedLength: CGFloat = 44
    static let pillTop: CGFloat = 6
    /// Quick, with a little bounce as it lengthens; it settles back without one.
    static let growSpring = (duration: 0.28, bounce: 0.3)
    static let shrinkSpring = (duration: 0.22, bounce: 0.0)

    let pill = UIView()
    private(set) var pressed = false
    var onDarkBackground = false { didSet { if onDarkBackground != oldValue { update(animated: false) } } }
    /// Lighter at rest, and as dark as the system grabber while held.
    var pillColor: UIColor {
        (onDarkBackground ? UIColor.white : UIColor.black).withAlphaComponent(pressed ? 0.3 : 0.18)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.isUserInteractionEnabled = false
        pill.layer.cornerRadius = Self.thickness/2
        addSubview(pill)
        isAccessibilityElement = true
        accessibilityLabel = "Peek"
        accessibilityHint = "Swipe down to close, or up to open as the page."
        update(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.center = CGPoint(x: bounds.midX, y: Self.pillTop+Self.thickness/2)
    }

    func setPressed(_ pressed: Bool) {
        guard pressed != self.pressed else { return }
        self.pressed = pressed
        update(animated: true)
    }

    private func update(animated: Bool) {
        let length = pressed ? Self.pressedLength : Self.restingLength
        let size = CGSize(width: length, height: Self.thickness)
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            pill.bounds.size = size; pill.backgroundColor = pillColor; return
        }
        UIView.animate(withDuration: pressed ? 0.06 : 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.pill.backgroundColor = self.pillColor
        }
        let spring = pressed ? Self.growSpring : Self.shrinkSpring
        UIView.animate(springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.pill.bounds.size = size
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        setPressed(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        setPressed(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        setPressed(false)
    }
}
