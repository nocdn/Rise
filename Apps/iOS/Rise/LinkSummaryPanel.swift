import UIKit

/// Summarise in a held link's menu: the bar grows into this panel, its title shimmering
/// "Summarising" while the linked page loads and the model starts, then the summary streams in
/// under it as Find's answers do, colouring each word as it lands but never sliding it, and the
/// title turns to "Summary" with the toast's morph. The panel grows ahead of the text: there's
/// always a line's room under the newest line, so a line never appears behind the panel's edge.
@MainActor final class LinkSummaryPanel: UIView {
    static let symbol = "text.line.2.summary"
    static let summarising = "Summarising", summary = "Summary"
    /// The header's row, as other panels' headers.
    static let headerHeight = SearchPanel.fieldHeight
    static let answerTop: CGFloat = 14
    /// Kept under the newest line as the panel grows: about three lines of the summary's text,
    /// as lines can come quicker than the panel finishes growing for the one before.
    static let growthRoom: CGFloat = 72
    static let inset = SearchPanel.inset+12
    /// The summary's text, larger than Find's answers: Summarise's own size.
    static let fontSize: CGFloat = 17
    /// While it's summarising, the soft hum of holding New Page; the success haptic ends it.
    let hum = HoldHum()
    /// How the panel follows each new line: as quickly as App settings' prompt editor follows its
    /// lines, without a bounce, so it leads the text smoothly rather than jumping.
    static let growth = (duration: 0.25, bounce: 0.0)

    /// The reply so far as it shows: its paragraphs with a blank line between, keeping a space
    /// after the last word so it counts as whole.
    static func display(_ reply: String) -> String {
        let text = PageSummary.paragraphs(in: reply).joined(separator: "\n\n")
        guard let last = reply.last, last.isWhitespace, !text.isEmpty else { return text }
        return text+" "
    }

    let title = TorphTextView()
    let closeButton = AnimatedSymbolButton(symbol: "xmark", pointSize: 14, weight: .bold)
    let answerView = AskAnswerView()
    var buttons: [UIButton] { [closeButton] }
    var onHeightChanged: (() -> Void)?
    /// The link summarised, for checks and for keeping its summary.
    private(set) var url: URL?
    private(set) var isFinished = false
    private let shimmer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = PanelHeader.font("OpenRunde-Semibold", size: 17, fallbackWeight: .semibold)
        title.textColor = .label
        title.setText(Self.summarising, animated: false)
        title.isAccessibilityElement = true; title.accessibilityTraits = .header
        closeButton.accessibilityLabel = "Close"
        closeButton.shrinksWhenPressed(to: BottomBar.pressedScale)
        answerView.entranceTravel = 0
        answerView.fontSize = Self.fontSize
        answerView.accessibilityLabel = "Summary"
        answerView.isScrollEnabled = false
        answerView.showsVerticalScrollIndicator = false
        answerView.onHeightChanged = { [weak self] in self?.updateScrolling(); self?.onHeightChanged?() }
        for view in [title, closeButton, answerView] as [UIView] { addSubview(view) }
        // A bright band sweeping the title's glyphs, by masking them: brighter where it passes.
        shimmer.startPoint = CGPoint(x: 0, y: 0.5); shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [UIColor(white: 1, alpha: 0.38), UIColor(white: 1, alpha: 0.38), .white,
                          UIColor(white: 1, alpha: 0.38), UIColor(white: 1, alpha: 0.38)].map(\.cgColor)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Waits for `url`'s summary, shimmering.
    func begin(_ url: URL) {
        self.url = url; isFinished = false
        answerView.reset()
        title.setText(Self.summarising, animated: false)
        title.accessibilityLabel = Self.summarising
        startShimmer()
        hum.start()
        setNeedsLayout()
    }

    /// The summary so far, or all of it.
    func show(_ text: String, finished: Bool) {
        if !text.isEmpty { answerView.show(text, finished: finished) }
        guard finished, !isFinished else { return }
        isFinished = true
        stopShimmer()
        hum.stop()
        title.setText(Self.summary)
        title.accessibilityLabel = Self.summary
        UIAccessibility.post(notification: .layoutChanged, argument: answerView)
    }

    /// Ends the wait without a summary, saying why.
    func fail(_ message: String) {
        answerView.show(message, finished: true)
        isFinished = true
        stopShimmer()
        hum.stop()
        title.setText("Couldn’t Summarise")
        title.accessibilityLabel = "Couldn’t Summarise"
    }

    func cancel() { stopShimmer(); hum.stop() }

    /// The answer's room: the lines revealed so far, and a line more while it's still coming.
    func answerHeight(width: CGFloat) -> CGFloat {
        let revealed = answerView.revealedHeight(for: width-2*Self.inset)
        // Waiting, it's small, but already has the room the first line will take.
        guard revealed > 0 else { return Self.answerTop+Self.growthRoom }
        return Self.answerTop+revealed+(isFinished ? 12 : Self.growthRoom)
    }
    /// From the panel's top to the bottom of its contents.
    func naturalHeight(width: CGFloat) -> CGFloat { Self.headerHeight+answerHeight(width: width) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let mid = Self.headerHeight/2
        closeButton.bounds = CGRect(x: 0, y: 0, width: 44, height: Self.headerHeight)
        closeButton.center = CGPoint(x: bounds.width-SearchPanel.inset-15, y: mid)
        // Where other panels' titles start.
        let titleX = SearchPanel.inset+AddressBar.outerCentre
        title.frame = CGRect(x: titleX, y: 0, width: max(0, closeButton.frame.minX-8-titleX), height: Self.headerHeight)
        // To the panel's bottom: once the panel is as tall as it gets, the summary scrolls in it.
        let top = Self.headerHeight+Self.answerTop
        // At once, even as the panel grows: the panel's edge shows as much as it has grown to,
        // while the text view, and the view in it drawing the text, are already their new size.
        // Grown inside the panel's animation, they grew from their old size, cutting off the
        // newest lines until they caught up.
        UIView.performWithoutAnimation {
            answerView.frame = CGRect(x: Self.inset, y: top, width: max(0, bounds.width-2*Self.inset), height: max(0, bounds.height-top))
            answerView.layoutIfNeeded()
        }
        updateScrolling()
        layoutShimmer()
    }

    /// The mask is six times the title's width, so it covers it wherever the band is.
    private func layoutShimmer() {
        guard title.layer.mask === shimmer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let width = max(1, title.bounds.width), span = width*6
        shimmer.bounds = CGRect(x: 0, y: 0, width: span, height: title.bounds.height)
        shimmer.position = CGPoint(x: width/2, y: title.bounds.midY)
        // A band about 70 points across, its edges soft.
        let half = Double(35/span)
        shimmer.locations = [0, 0.5-half, 0.5, 0.5+half, 1].map { NSNumber(value: $0) }
        CATransaction.commit()
    }

    private func startShimmer() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        title.layer.mask = shimmer
        layoutShimmer()
        let width = max(1, title.bounds.width), text = min(width, max(60, title.intrinsicContentSize.width))
        // Left to right across the word, then resting off it a moment, as Find's question shimmers.
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -width/2-text*0.4; sweep.toValue = text*1.4-width/2
        sweep.duration = QuestionShimmer.sweep
        let cycle = CAAnimationGroup()
        cycle.animations = [sweep]; cycle.duration = QuestionShimmer.sweep+QuestionShimmer.pause
        cycle.repeatCount = .infinity
        // At rest, between sweeps, the band waits off the word's left.
        shimmer.transform = CATransform3DMakeTranslation(-width/2-text*0.4, 0, 0)
        shimmer.add(cycle, forKey: "shimmer")
    }

    private func stopShimmer() {
        guard title.layer.mask === shimmer else { return }
        shimmer.removeAllAnimations()
        title.layer.mask = nil
    }

    var isShimmering: Bool { title.layer.mask === shimmer && shimmer.animation(forKey: "shimmer") != nil }

    /// Pulling down closes it, unless the summary has room to scroll back up first.
    /// On the summary, as on the title: up against the sheet's resistance or down to close, unless
    /// the summary is taller than the sheet gets, when it scrolls first, and closes from its top.
    func canPullToClose(at point: CGPoint, velocity: CGPoint) -> Bool {
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        guard answerView.frame.contains(point), isSummaryScrollable else { return true }
        return answerView.contentOffset.y <= -answerView.adjustedContentInset.top+1 && velocity.y > 0
    }

    /// Only once it's taller than the sheet gets: until then a swipe on it is the sheet's.
    /// By the text's own height: a text view that doesn't scroll doesn't keep its content size.
    var isSummaryScrollable: Bool {
        answerView.revealedHeight(for: answerView.bounds.width) > answerView.bounds.height+1
    }
    private func updateScrolling() {
        let scrollable = isSummaryScrollable
        if answerView.isScrollEnabled != scrollable { answerView.isScrollEnabled = scrollable }
    }
}
