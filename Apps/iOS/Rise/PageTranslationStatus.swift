import UIKit

/// Continues the current document's progress beside More once its panel is closed.
@MainActor final class PageTranslationStatus: UIButton {
    enum Phase { case translating, translated, leaving }
    static let completedHoldDuration = 0.75
    let documentID: String
    let symbol = AnimatedSymbolButton(symbol: "translate", pointSize: 14, weight: .bold)
    private(set) var phase = Phase.translating
    private var dismissal: Task<Void, Never>?
    private var visibility: UIViewPropertyAnimator?
    private var background: NSObjectProtocol?
    private var finished: (() -> Void)?

    init(documentID: String) {
        self.documentID = documentID
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Translation progress"
        accessibilityValue = "Translating to English"
        accessibilityHint = "Tap for status. Hold to cancel translation."
        symbol.accessibilityElementsHidden = true
        symbol.isUserInteractionEnabled = false
        symbol.tintColor = .label
        symbol.setLoading(name: "page-translation-loading")
        addSubview(symbol)
        alpha = 0
        if !UIAccessibility.isReduceMotionEnabled {
            transform = CGAffineTransform(scaleX: PageTranslationHint.initialScale, y: PageTranslationHint.initialScale)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func start(completion: @escaping () -> Void) {
        finished = completion
        background = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        animateVisibility(true)
    }
    func showLoading() {
        guard phase != .translating else { return }
        phase = .translating
        isUserInteractionEnabled = true
        accessibilityTraits = .button
        dismissal?.cancel(); dismissal = nil
        symbol.tintColor = .label
        symbol.setLoading(name: "page-translation-loading")
        accessibilityLabel = "Translation progress"
        accessibilityValue = "Translating to English"
        accessibilityHint = "Tap for status. Hold to cancel translation."
        animateVisibility(true)
    }
    func showTranslated() {
        guard phase == .translating else { return }
        phase = .translated
        isUserInteractionEnabled = false
        accessibilityTraits = .staticText
        symbol.tintColor = .systemBlue
        symbol.setGlyph(UIImage(named: "ToolbarTranslate"), name: "page-translation")
        accessibilityLabel = "Page translated to English"
        accessibilityValue = nil
        accessibilityHint = nil
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.completedHoldDuration)) }
            catch { return }
            guard let self, phase == .translated else { return }
            phase = .leaving
            animateVisibility(false)
        }
    }
    private func animateVisibility(_ shown: Bool) {
        if let visibility, visibility.state == .active {
            visibility.stopAnimation(false)
            visibility.finishAnimation(at: .current)
        }
        let animation = UIViewPropertyAnimator(duration: PageTranslationHint.revealDuration,
                                               timingParameters: PageTranslationHint.appearanceTiming)
        animation.addAnimations {
            self.alpha = shown ? 1 : 0
            let scale: CGFloat = shown || UIAccessibility.isReduceMotionEnabled ? 1 : PageTranslationHint.initialScale
            self.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        animation.addCompletion { [weak self] position in
            if !shown, position == .end { self?.cancel() }
        }
        visibility = animation
        animation.startAnimation()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        symbol.frame = bounds
    }
    func cancel() { removeFromSuperview() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        dismissal?.cancel(); dismissal = nil
        if let visibility, visibility.state == .active { visibility.stopAnimation(true) }
        visibility = nil
        BlurCrossfade.stop(in: symbol)
        if let background { NotificationCenter.default.removeObserver(background); self.background = nil }
        let completion = finished; finished = nil; completion?()
    }
}
