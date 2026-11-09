import UIKit

/// The transport of the page being displayed, rather than an address being typed.
@MainActor enum PageConnection {
    case secure, insecure

    init?(_ url: URL?) {
        guard let url, url.host?.isEmpty == false else { return nil }
        switch url.scheme?.lowercased() {
        case "https": self = .secure
        case "http": self = .insecure
        default: return nil
        }
    }
    var tint: UIColor { self == .secure ? .systemGreen : .systemRed }
    var accessibilityLabel: String { self == .secure ? "Secure" : "Not secure" }
    private static var unlockedImages: [CGFloat: UIImage] = [:]
    func image(pointSize: CGFloat) -> UIImage? {
        if self == .insecure, let cached = Self.unlockedImages[pointSize] { return cached }
        let image = UIImage(systemName: self == .secure ? "lock.fill" : "lock.open.fill",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        guard self == .insecure, let image else { return image }
        // UIImageView can ignore orientation on symbol images. Bake the leftward
        // opening into a cached template so both the address and flying cue agree.
        let flipped = UIGraphicsImageRenderer(size: image.size).image { context in
            context.cgContext.translateBy(x: image.size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            image.draw(at: .zero)
        }.withRenderingMode(.alwaysTemplate)
        Self.unlockedImages[pointSize] = flipped
        return flipped
    }
}
