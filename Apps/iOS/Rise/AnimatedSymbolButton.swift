import UIKit

/// The button stays in place and keeps its hit area as the outgoing and incoming icons overlap.
final class AnimatedSymbolButton: UIButton {
    private(set) var symbolName: String
    private var glyph: Content
    private let symbolConfiguration: UIImage.SymbolConfiguration

    override var isEnabled: Bool {
        didSet { tintColor = isEnabled ? .label : .tertiaryLabel }
    }

    init(symbol: String, pointSize: CGFloat = 19, weight: UIImage.SymbolWeight = .semibold) {
        symbolName = symbol
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        symbolConfiguration = configuration
        glyph = Content(image: UIImage(systemName: symbol, withConfiguration: configuration))
        super.init(frame: .zero)
        tintColor = .label
        addSubview(glyph)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Include room for the blurred edges, laying out by bounds while an icon scales.
        for image in subviews.compactMap({ $0 as? Content }) {
            image.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
            image.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    func setSymbol(_ symbol: String) {
        setGlyph(UIImage(systemName: symbol, withConfiguration: symbolConfiguration), name: symbol)
    }

    func setGlyph(_ image: UIImage?, name: String) {
        guard symbolName != name else { return }
        setContent(Content(image: image), name: name)
    }

    /// Keep the native spinner's rotation separate from the swap's scale and blur.
    func setLoading(name: String) {
        guard symbolName != name else { return }
        setContent(Content(spinner: true), name: name)
    }

    private func setContent(_ next: Content, name: String) {
        symbolName = name
        let previous = glyph
        glyph = next
        next.alpha = 0
        addSubview(next)
        setNeedsLayout(); layoutIfNeeded()
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            BlurCrossfade.stop(in: self)
            previous.removeFromSuperview(); next.alpha = 1
            return
        }
        BlurCrossfade.swap(from: previous, to: next, style: .symbol) { previous.removeFromSuperview() }
    }

    private final class Content: UIView {
        private let content: UIView
        init(image: UIImage?) {
            let image = UIImageView(image: image)
            image.contentMode = .center
            content = image
            super.init(frame: .zero)
            configure()
        }
        init(spinner: Bool) {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.color = .label
            indicator.transform = CGAffineTransform(scaleX: 0.77, y: 0.77)
            indicator.startAnimating()
            content = indicator
            super.init(frame: .zero)
            configure()
        }
        required init?(coder: NSCoder) { fatalError() }
        private func configure() {
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            addSubview(content)
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            if content is UIImageView { content.bounds = bounds }
            content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}
