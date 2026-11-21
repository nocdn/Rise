import UIKit
import WebKit

/// A toast offering something to do with its page, such as opening it in the App Store or saving
/// its file: the whole plaque is one button, with an icon at its end, that shrinks a little and
/// clicks when pressed. Toast's outer layer still owns entry, swipe tracking and dismissal; a
/// swipe cancels the button's tracking. It hides with the tab switcher.
@MainActor class PageActionToast: Toast {
    weak var page: WKWebView?
    let trailingIcon: UIImageView
    let pressButton = UIButton(type: .custom)
    private let click = UIImpactFeedbackGenerator(style: .rigid)
    #if DEBUG
    private(set) var activationFeedbackCount = 0
    #endif
    var onActivate: (() -> Void)?
    /// A swipe or VoiceOver's Dismiss took it away, rather than the page changing.
    var onUserDismiss: (() -> Void)?
    /// Whether a press does anything just now; one that doesn't neither shrinks nor clicks.
    var isActionable = true { didSet { pressButton.isEnabled = isActionable } }

    init(message: String, motionName: String, page: WKWebView, leadingInset: CGFloat = 47,
         trailingInset: CGFloat = 47, trailingIcon image: UIImage?) {
        self.page = page
        trailingIcon = UIImageView(image: image)
        super.init(message: message, motionName: motionName, leadingInset: leadingInset, trailingInset: trailingInset)
        trailingIcon.tintColor = symbol.tintColor
        trailingIcon.contentMode = .center
        addSubview(trailingIcon)
        for part in subviews { adopt(part) }
        pressButton.layer.shadowColor = layer.shadowColor
        pressButton.layer.shadowOpacity = layer.shadowOpacity
        pressButton.layer.shadowRadius = layer.shadowRadius
        pressButton.layer.shadowOffset = layer.shadowOffset
        layer.shadowOpacity = 0
        addSubview(pressButton)
        pressButton.shrinksWhenPressed(to: SearchPanel.pressedScale)
        pressButton.addAction(UIAction { [weak self] _ in self?.click.prepare() }, for: .touchDown)
        pressButton.addAction(UIAction { [weak self] _ in self?.activate() }, for: .primaryActionTriggered)
        pressButton.isAccessibilityElement = false
        accessibilityTraits = .button
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Dismiss") { [weak self] _ in
            self?.dismissByUser(); return true
        }]
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Puts a view in the button, so it shrinks with the press without taking the tap itself.
    func adopt(_ view: UIView) {
        view.isUserInteractionEnabled = false
        pressButton.addSubview(view)
    }
    override var widthFollowers: [UIView] { [pressButton, trailingIcon] }
    override var shadowCaster: CALayer { pressButton.layer }

    override func layoutSubviews() {
        super.layoutSubviews()
        pressButton.bounds = bounds
        pressButton.center = CGPoint(x: bounds.midX, y: bounds.midY)
        pressButton.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 17).cgPath
        label.frame = CGRect(x: leadingInset, y: 0, width: max(0, bounds.width-leadingInset-trailingInset), height: bounds.height)
        trailingIcon.frame = CGRect(x: bounds.width-44, y: 11, width: 32, height: 32)
    }

    func activate() {
        guard !dismissed, isActionable else { return }
        click.impactOccurred(intensity: 0.5)
        #if DEBUG
        activationFeedbackCount += 1
        #endif
        onActivate?()
    }
    override func accessibilityActivate() -> Bool {
        guard isActionable else { return false }
        activate(); return !dismissed
    }

    func dismissByUser() {
        guard !dismissed else { return }
        onUserDismiss?()
        dismiss()
    }
    override func endDrag(velocity: CGPoint, cancelled: Bool = false) {
        super.endDrag(velocity: velocity, cancelled: cancelled)
        if dismissed { onUserDismiss?() }
    }
}
