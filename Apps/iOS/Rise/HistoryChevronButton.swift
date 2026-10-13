import UIKit

/// History keeps separate Back and Forward actions, but a sole chevron turns in place as the
/// available direction changes. Only the glyph rotates; pressing still scales the whole button.
final class HistoryChevronButton: UIButton {
    enum Direction {
        case back, forward
        var angle: CGFloat { self == .back ? 0 : .pi }
        var label: String { self == .back ? "Back" : "Forward" }
    }

    private let direction: Direction
    private let glyph = UIImageView(image: UIImage(systemName: "chevron.left", withConfiguration:
        UIImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)))
    private var turn: UIViewPropertyAnimator?

    init(_ direction: Direction) {
        self.direction = direction
        super.init(frame: .zero)
        tintColor = .label
        accessibilityLabel = direction.label
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        glyph.isAccessibilityElement = false
        glyph.transform = CGAffineTransform(rotationAngle: direction.angle)
        addSubview(glyph)
        shrinksWhenPressed(to: AddressBar.pressedScale)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        glyph.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func turn(from previous: HistoryChevronButton) {
        let pose = previous.glyph.layer.presentation()?.affineTransform() ?? previous.glyph.transform
        previous.resetDirection()
        resetDirection()
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        glyph.transform = pose
        let spring = UISpringTimingParameters(dampingRatio: 0.76)
        let animator = UIViewPropertyAnimator(duration: 0.32, timingParameters: spring)
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.glyph.transform = CGAffineTransform(rotationAngle: self.direction.angle)
        }
        turn = animator
        animator.startAnimation()
    }

    func resetDirection() {
        if let turn, turn.state == .active { turn.stopAnimation(true) }
        turn = nil
        glyph.transform = CGAffineTransform(rotationAngle: direction.angle)
    }
}
