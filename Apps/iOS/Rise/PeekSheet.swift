import UIKit

/// Peek's sheet: a card floating inside the window's edges that springs up from the bottom
/// over a dimmed page. Dragging the card down closes it with the finger; dragging its handle
/// up grows it, and letting go near the top makes it the page, as on the Mac.
final class PeekPresentationController: UIPresentationController, UIGestureRecognizerDelegate {
    static let heightFraction: CGFloat = 0.8
    static let margin: CGFloat = 10
    static let cornerRadius: CGFloat = 40
    /// Whether the page behind recedes. Off for now; the bar's panel recedes the page instead.
    static let recedesPage = false
    /// Quick, with the slight overshoot of Rise's other springs on the Mac.
    static let openSpring = (duration: 0.24, bounce: 0.15)
    /// The card leaves without overshoot; the page's bigger bounce makes its return visible.
    static let closeSpring = (duration: 0.26, bounce: 0.0)
    static let pageReturnSpring = (duration: 0.3, bounce: 0.3)
    /// Filling the window, quickly: any overshoot would fall outside the screen, so none.
    static let expandSpring = (duration: 0.2, bounce: 0.0)

    /// The page inside the card; pulling down at its top drags the card instead of scrolling.
    weak var scrollView: UIScrollView?
    /// Makes the card's page the main page once the card fills the window.
    var onExpand: @MainActor () -> Void = {}
    /// Downward speed at release, in points per second, for the dismissal to carry on from.
    private(set) var releaseVelocity: CGFloat = 0
    private(set) var dragOffset: CGFloat = 0
    /// How far the card has grown towards filling the window: 0 is resting, 1 is full.
    private(set) var expansion: CGFloat = 0
    private(set) var isExpanding = false
    private var dragging = false, dragStart: CGFloat = 0
    private let dimming = UIView()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))

    var page: UIView { presentingViewController.view }
    private var peek: PeekViewController? { presentedViewController as? PeekViewController }
    private var motion: Bool { !UIAccessibility.isReduceMotionEnabled }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let bounds = containerView?.bounds else { return .zero }
        let height = (bounds.height*Self.heightFraction).rounded()
        return CGRect(x: Self.margin, y: bounds.maxY-Self.margin-height,
                      width: bounds.width-2*Self.margin, height: height)
    }
    /// How far the card moves to leave the window entirely.
    var travel: CGFloat { max(1, (containerView?.bounds.maxY ?? 0)-frameOfPresentedViewInContainerView.minY) }
    /// How far the card's top edge moves up to reach the window's.
    var reach: CGFloat { max(1, frameOfPresentedViewInContainerView.minY-(containerView?.bounds.minY ?? 0)) }

    /// Between the resting card and the whole window.
    func cardFrame(expansion: CGFloat) -> CGRect {
        let rest = frameOfPresentedViewInContainerView
        guard let full = containerView?.bounds else { return rest }
        let e = min(1, max(0, expansion))
        return CGRect(x: rest.minX+(full.minX-rest.minX)*e, y: rest.minY+(full.minY-rest.minY)*e,
                      width: rest.width+(full.width-rest.width)*e, height: rest.height+(full.height-rest.height)*e)
    }

    override func presentationTransitionWillBegin() {
        guard let containerView, let presentedView else { return }
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        dimming.frame = containerView.bounds
        dimming.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        containerView.insertSubview(dimming, at: 0)

        presentedView.layer.cornerRadius = Self.cornerRadius
        presentedView.layer.cornerCurve = .continuous
        presentedView.clipsToBounds = true
        presentedView.accessibilityViewIsModal = true
        pan.delegate = self
        // Pages keep receiving their own touches while the card follows the finger.
        pan.cancelsTouchesInView = false
        presentedView.addGestureRecognizer(pan)

        page.layer.cornerCurve = .continuous
        page.clipsToBounds = true
        if presentedViewController.transitionCoordinator?.isAnimated == false { setCard(0); setPage(0) }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed { dimming.removeFromSuperview(); setPage(1) }
    }

    override func dismissalTransitionWillBegin() {
        // A card that became the page has nothing left to show. Moving it down by its usual
        // travel would leave the top of a full-window card on screen for a frame.
        if isExpanding { presentedView?.isHidden = true; dimming.isHidden = true; return }
        if presentedViewController.transitionCoordinator?.isAnimated == false { setCard(1); setPage(1) }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed {
            dimming.removeFromSuperview()
            let browser = presentingViewController as? BrowserViewController
            DispatchQueue.main.async { [weak browser] in browser?.applyPendingSharedTabs() }
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard let containerView else { return }
        dimming.frame = containerView.bounds
        setExpansion(expansion)
    }

    /// Lays the card out at an expansion, without touching the transform that carries its travel down.
    func setExpansion(_ value: CGFloat) {
        expansion = value
        guard let presentedView else { return }
        let frame = cardFrame(expansion: value)
        presentedView.bounds = CGRect(origin: .zero, size: frame.size)
        presentedView.center = CGPoint(x: frame.midX, y: frame.midY)
        presentedView.layer.cornerRadius = Self.cornerRadius*(1-min(1, max(0, value)))
    }

    /// Places the card along its travel: 0 is resting, 1 is just below the window.
    func setCard(_ progress: CGFloat) {
        presentedView?.transform = CGAffineTransform(translationX: 0, y: progress*travel)
        dimming.alpha = 1-min(1, max(0, progress))
    }

    /// Recedes the page: 0 is fully receded behind the card, 1 is back at full size.
    func setPage(_ progress: CGFloat) {
        guard Self.recedesPage else { return }
        PageRecede.apply(1-progress, to: page)
    }

    /// Follows the finger: down moves the card and restores the page; up grows the card.
    func drag(to offset: CGFloat) {
        dragOffset = offset
        if offset >= 0 {
            setExpansion(0)
            setCard(offset/travel)
            setPage(offset/travel)
        } else {
            setCard(0)
            setExpansion(min(1, -offset/reach))
            setPage(0)
        }
    }

    /// Dismisses after a flick or a long enough drag down, and fills the window after one up.
    /// Anything shorter springs back into place.
    func endDrag(velocity: CGFloat) {
        let offset = dragOffset
        dragOffset = 0
        if offset < 0, expansion > 0.5 && velocity < 200 || velocity < -800 {
            expand(velocity: velocity)
            return
        }
        if offset >= 0, velocity > 600 || (offset > travel*0.3 && velocity > -200) {
            releaseVelocity = velocity
            presentedViewController.dismiss(animated: true)
            return
        }
        let spring = Self.openSpring
        UIView.animate(springDuration: spring.duration, bounce: spring.bounce,
                       initialSpringVelocity: offset == 0 ? 0 : -velocity/offset, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.setCard(0); self.setExpansion(0); self.setPage(0)
            self.presentedView?.layoutIfNeeded()
        }
    }

    /// Grows the card to fill the window, then hands its page over to become the main page.
    func expand(velocity: CGFloat = 0) {
        guard !isExpanding, !presentedViewController.isBeingPresented, !presentedViewController.isBeingDismissed
        else { return }
        isExpanding = true
        pan.isEnabled = false
        peek?.prepareToFill(statusBarHeight: containerView?.safeAreaInsets.top ?? 0)
        let remaining = max(1, cardFrame(expansion: expansion).minY-(containerView?.bounds.minY ?? 0))
        let finish = { [weak self] in
            guard let self else { return }
            setPage(1)
            onExpand()
        }
        guard motion else { setCard(0); setExpansion(1); presentedView?.layoutIfNeeded(); finish(); return }
        let spring = Self.expandSpring
        UIView.animate(springDuration: spring.duration, bounce: spring.bounce,
                       initialSpringVelocity: max(0, -velocity)/remaining, delay: 0, options: [.beginFromCurrentState]) {
            self.setCard(0); self.setExpansion(1)
            self.peek?.handle.alpha = 0
            self.presentedView?.layoutIfNeeded()
        } completion: { _ in finish() }
    }

    @objc private func close() { presentedViewController.dismiss(animated: true) }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let containerView, let presentedView, !isExpanding, !presentedViewController.isBeingPresented,
              !presentedViewController.isBeingDismissed else { return }
        let translation = pan.translation(in: containerView)
        switch pan.state {
        case .began, .changed:
            if !dragging {
                let start = pan.location(in: presentedView).applying(
                    CGAffineTransform(translationX: -translation.x, y: -translation.y))
                guard translation.y != 0, abs(translation.y) > abs(translation.x),
                      translation.y > 0 ? canDragDown(from: start) : isOnHandle(start) else { return }
                dragging = true
                peek?.handle.setPressed(true)
                dragStart = translation.y
                if let scrollView {
                    // Cancel the page's scroll so it doesn't rubber-band under the moving card.
                    scrollView.panGestureRecognizer.isEnabled = false
                    scrollView.panGestureRecognizer.isEnabled = true
                    if translation.y > 0 { scrollView.contentOffset.y = -scrollView.adjustedContentInset.top }
                }
            }
            drag(to: translation.y-dragStart)
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            peek?.handle.setPressed(false)
            endDrag(velocity: pan.state == .ended ? pan.velocity(in: containerView).y : 0)
        default: break
        }
    }

    private func isOnHandle(_ point: CGPoint) -> Bool { peek?.isOnHandle(point) ?? true }

    /// The handle always drags the card down; the page does once it is scrolled to the top.
    private func canDragDown(from point: CGPoint) -> Bool {
        guard let scrollView else { return true }
        return isOnHandle(point) || scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top+1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Slides the card up from the bottom edge, or down off it, while the page recedes or returns.
final class PeekSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool
    init(presenting: Bool) { self.presenting = presenting }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { 0.4 }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let controller = context.viewController(forKey: key),
              let sheet = controller.presentationController as? PeekPresentationController else {
            context.completeTransition(!context.transitionWasCancelled); return
        }
        let options: UIView.AnimationOptions = [.allowUserInteraction, .beginFromCurrentState]
        if presenting {
            context.containerView.addSubview(controller.view)
            sheet.containerViewWillLayoutSubviews()
            sheet.setCard(1)
            sheet.setPage(1)
            let spring = PeekPresentationController.openSpring
            UIView.animate(springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: 0,
                           delay: 0, options: options) {
                sheet.setCard(0); sheet.setPage(0)
            } completion: { _ in context.completeTransition(!context.transitionWasCancelled) }
            return
        }
        // Continue from wherever a drag let go, at the speed it was moving.
        let remaining = max(1, sheet.travel-max(0, sheet.presentedView?.transform.ty ?? 0))
        let close = PeekPresentationController.closeSpring
        UIView.animate(springDuration: close.duration, bounce: close.bounce,
                       initialSpringVelocity: max(0, sheet.releaseVelocity)/remaining, delay: 0, options: options) {
            sheet.setCard(1)
        } completion: { _ in context.completeTransition(!context.transitionWasCancelled) }
        let back = PeekPresentationController.pageReturnSpring
        UIView.animate(springDuration: back.duration, bounce: back.bounce, initialSpringVelocity: 0,
                       delay: 0, options: options) { sheet.setPage(1) }
    }
}
