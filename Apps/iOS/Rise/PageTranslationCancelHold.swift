import UIKit

/// Capture the document at touch-down and consume release after one recognised hold.
@MainActor final class PageTranslationCancelHold: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    static let duration = 0.4
    private let prepareCancellation: () -> (() -> Void)?
    private var cancellation: (() -> Void)?

    init(prepare: @escaping () -> (() -> Void)?) {
        prepareCancellation = prepare
        super.init(target: nil, action: nil)
        minimumPressDuration = Self.duration
        cancelsTouchesInView = true
        delegate = self
        addTarget(self, action: #selector(holdChanged))
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        cancellation = prepareCancellation()
        return cancellation != nil
    }
    @objc private func holdChanged() {
        if state == .began {
            let cancel = cancellation; cancellation = nil
            cancel?()
        } else if state == .ended || state == .cancelled || state == .failed { cancellation = nil }
    }
}
