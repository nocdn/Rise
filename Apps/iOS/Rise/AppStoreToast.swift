import UIKit
import WebKit

/// The existing toast's surface and swipe physics, with optional product artwork.
@MainActor final class AppStoreToast: Toast {
    let link: AppStoreLink
    weak var page: WKWebView?
    let appIcon = UIImageView(image: UIImage(named: "ToastAppStore"))
    private var artworkTask: Task<Void, Never>?
    let openIcon = UIImageView(image: UIImage(named: "ToastOpenAppStore"))
    let pressButton = UIButton(type: .custom)
    private let click = UIImpactFeedbackGenerator(style: .rigid)
    #if DEBUG
    private(set) var activationFeedbackCount = 0
    #endif
    var open: (() -> Void)?
    var onUserDismiss: (() -> Void)?

    init(link: AppStoreLink, page: WKWebView, showsAppArtwork: Bool = false,
         artwork: @escaping @MainActor (AppStoreLink) async -> UIImage? = { await AppStoreArtwork.shared.image(for: $0) }) {
        self.link = link; self.page = page
        super.init(message: "Open App Store", motionName: "app-store-toast", trailingInset: 47)
        symbol.isHidden = true
        appIcon.tintColor = symbol.tintColor
        appIcon.contentMode = .scaleAspectFit
        appIcon.isUserInteractionEnabled = false
        appIcon.layer.cornerCurve = .continuous
        appIcon.clipsToBounds = true
        addSubview(appIcon)
        openIcon.tintColor = symbol.tintColor
        openIcon.contentMode = .center; openIcon.isUserInteractionEnabled = false
        addSubview(openIcon)
        // The button owns the visual press; Toast's outer layer still owns entry,
        // swipe tracking and dismissal. A swipe cancels native button tracking.
        for part in subviews {
            part.isUserInteractionEnabled = false
            pressButton.addSubview(part)
        }
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
        // Keep artwork support available, but show only the App Store icon for now.
        guard showsAppArtwork else { return }
        artworkTask = Task { [weak self] in
            let image = await artwork(link)
            guard !Task.isCancelled, let self, !dismissed, let image else { return }
            appIcon.image = image.withRenderingMode(.alwaysOriginal)
            appIcon.layer.cornerRadius = 5
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        pressButton.bounds = bounds
        pressButton.center = CGPoint(x: bounds.midX, y: bounds.midY)
        pressButton.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 17).cgPath
        appIcon.frame = CGRect(x: 14, y: 15, width: 24, height: 24)
        label.frame = CGRect(x: 47, y: 0, width: max(0, bounds.width-94), height: bounds.height)
        openIcon.frame = CGRect(x: bounds.width-44, y: 11, width: 32, height: 32)
    }
    func activate() {
        guard !dismissed else { return }
        click.impactOccurred(intensity: 0.5)
        #if DEBUG
        activationFeedbackCount += 1
        #endif
        open?()
    }
    override func accessibilityActivate() -> Bool { activate(); return !dismissed }

    private func dismissByUser() {
        guard !dismissed else { return }
        onUserDismiss?()
        dismiss()
    }
    override func dismiss(animated: Bool = true, velocity: CGPoint? = nil) {
        artworkTask?.cancel(); artworkTask = nil
        super.dismiss(animated: animated, velocity: velocity)
    }
    isolated deinit { artworkTask?.cancel() }

    override func endDrag(velocity: CGPoint, cancelled: Bool = false) {
        super.endDrag(velocity: velocity, cancelled: cancelled)
        if dismissed { onUserDismiss?() }
    }
}
