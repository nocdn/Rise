import UIKit
import ImageIO

/// Keep the site's own artwork for each appearance. UIImageView resolves the asset
/// against its own traits, including private panels and changes while already visible.
enum MobileFavicon {
    struct Saved: Codable {
        let light: Data
        let dark: Data?

        init?(_ image: UIImage) {
            guard let light = MobileFavicon.variant(image, style: .light).pngData(), light.count <= 100_000 else { return nil }
            let dark = MobileFavicon.variant(image, style: .dark).pngData()
            self.light = light
            self.dark = dark != light && (dark?.count ?? 0) <= 100_000 ? dark : nil
        }

        var image: UIImage? {
            guard let light = MobileFavicon.decode(light) else { return nil }
            return MobileFavicon.adaptive(light: light, dark: dark.flatMap(MobileFavicon.decode))
        }
    }

    static func adaptive(light: UIImage, dark: UIImage?) -> UIImage {
        guard let dark else { return light }
        let asset = UIImageAsset()
        for (style, image) in [(UIUserInterfaceStyle.light, light), (.dark, dark)] {
            asset.register(image, with: UITraitCollection {
                $0.userInterfaceStyle = style; $0.displayScale = image.scale
            })
        }
        return asset.image(with: UITraitCollection(userInterfaceStyle: .light))
    }

    static func variant(_ image: UIImage, style: UIUserInterfaceStyle) -> UIImage {
        image.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: style)) ?? image
    }

    static func decode(_ data: Data) -> UIImage? {
        guard data.count <= 1_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // An ICO can start with a 16-pixel image; preserve the sharper size for Retina displays.
        let index = (0..<CGImageSourceGetCount(source)).max { left, right in
            let a = CGImageSourceCopyPropertiesAtIndex(source, left, nil) as? [CFString: Any]
            let b = CGImageSourceCopyPropertiesAtIndex(source, right, nil) as? [CFString: Any]
            return (a?[kCGImagePropertyPixelWidth] as? Int ?? 0) < (b?[kCGImagePropertyPixelWidth] as? Int ?? 0)
        } ?? 0
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
