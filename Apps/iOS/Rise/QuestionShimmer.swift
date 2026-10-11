import UIKit

/// A bright sweep masked to the question's glyphs, never the field's background or buttons.
final class QuestionShimmer: UIView {
    private let band = CAGradientLayer()
    private weak var field: UITextField?
    private(set) var isRunning = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.addSublayer(band)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func start(on field: UITextField) {
        stop()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        self.field = field
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        frame = field.bounds
        field.addSubview(self)
        let rect = field.textRect(forBounds: field.bounds)
        let font = field.font ?? UIFont.preferredFont(forTextStyle: .body)
        let maskImage = UIGraphicsImageRenderer(size: bounds.size).image { context in
            context.cgContext.clip(to: rect)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            ((field.text ?? "") as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY-font.lineHeight/2,
                width: rect.width, height: font.lineHeight),
                withAttributes: [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
        }
        let mask = CALayer(); mask.frame = bounds; mask.contents = maskImage.cgImage
        layer.mask = mask
        let color = UIColor.label.resolvedColor(with: traitCollection)
        band.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        band.locations = [0, 0.5, 1]
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        band.frame = CGRect(x: rect.minX-80, y: 0, width: 80, height: bounds.height)
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0; sweep.toValue = rect.width+80
        sweep.duration = 1; sweep.repeatCount = .infinity
        band.add(sweep, forKey: "questionSweep")
        field.textColor = .secondaryLabel
        alpha = 0; isHidden = false; isRunning = true
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
    }

    func stop() {
        isRunning = false
        band.removeAllAnimations()
        field?.textColor = .label
        removeFromSuperview()
        isHidden = true
        field = nil
    }

    func finish() {
        UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }) { _ in
            if self.alpha == 0 { self.stop() }
        }
    }
}
