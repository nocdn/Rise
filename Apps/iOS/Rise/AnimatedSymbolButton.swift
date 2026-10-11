import UIKit

/// The button stays in place and keeps its hit area as the outgoing and incoming icons overlap.
final class AnimatedSymbolButton: UIButton {
    private(set) var symbolName: String
    private var glyph: UIImageView
    private let symbolConfiguration: UIImage.SymbolConfiguration

    override var isEnabled: Bool {
        didSet { tintColor = isEnabled ? .label : .tertiaryLabel }
    }

    init(symbol: String, pointSize: CGFloat = 19, weight: UIImage.SymbolWeight = .semibold) {
        symbolName = symbol
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        symbolConfiguration = configuration
        glyph = Self.imageView(symbol, configuration: configuration)
        super.init(frame: .zero)
        tintColor = .label
        addSubview(glyph)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Include room for the blurred edges, laying out by bounds while an icon scales.
        for image in subviews.compactMap({ $0 as? UIImageView }) {
            image.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
            image.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    func setSymbol(_ symbol: String) {
        guard symbolName != symbol else { return }
        symbolName = symbol
        let previous = glyph, next = Self.imageView(symbol, configuration: symbolConfiguration)
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

    private static func imageView(_ symbol: String, configuration: UIImage.SymbolConfiguration) -> UIImageView {
        let image = UIImageView(image: UIImage(systemName: symbol,
            withConfiguration: configuration))
        image.contentMode = .center
        image.isUserInteractionEnabled = false
        image.isAccessibilityElement = false
        return image
    }
}
