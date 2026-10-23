import SwiftUI
import UIKit

/// A hosted native mini spinner with its own geometry and controller lifecycle.
/// A cell content configuration can misplace its center inside the compact toolbar.
@MainActor final class MiniSpinnerView: UIView {
    private struct Indicator: View {
        var ink: UIColor = .label
        var body: some View {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(Color(uiColor: ink))
                .scaleEffect(1.12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private let host = UIHostingController(rootView: Indicator())

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        host.rootView = Indicator(ink: tintColor)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            if host.parent != nil {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            return
        }
        var responder: UIResponder? = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let parent = responder as? UIViewController, host.parent !== parent else { return }
        parent.addChild(host)
        host.view.frame = bounds
        if host.view.superview !== self { addSubview(host.view) }
        host.didMove(toParent: parent)
    }
}
