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

    /// Turns by angle rather than by matrix, so a turn to Forward goes clockwise and a turn back
    /// to Back the other way; a half turn interpolated as a transform always goes the same way.
    func turn(from previous: HistoryChevronButton) {
        let start = previous.angle
        previous.resetDirection()
        resetDirection()
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let spring = CASpringAnimation(perceptualDuration: 0.32, bounce: 0.24)
        spring.keyPath = "transform.rotation.z"
        spring.fromValue = start
        spring.toValue = direction.angle
        spring.duration = spring.settlingDuration
        glyph.layer.add(spring, forKey: Self.turnKey)
    }

    func resetDirection() {
        glyph.layer.removeAnimation(forKey: Self.turnKey)
        glyph.transform = CGAffineTransform(rotationAngle: direction.angle)
    }

    private static let turnKey = "turn"

    /// The glyph's angle on screen, from Back's 0 to Forward's half turn. Overshooting a half turn
    /// reads as just past minus a half turn, so it's brought back round.
    private var angle: CGFloat {
        let layer = glyph.layer.presentation() ?? glyph.layer
        let angle = (layer.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? direction.angle
        return angle < -.pi/2 ? angle+2*CGFloat.pi : angle
    }
}
