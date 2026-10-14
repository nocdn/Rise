import UIKit

/// The supplied Tabler icons, with the weight of More's 20-point medium SF Symbols.
/// Template rendering gives the tiles and Site settings the same adaptive colour.
/// Paths by Paweł Kuna, MIT: https://github.com/tabler/tabler-icons/blob/master/LICENSE
@MainActor enum MenuIcons {
    /// The supplied SVG, preserved as a vector asset with the same 1.8-point stroke.
    static let siteSettings = UIImage(named: "MenuSiteSettings")
    static let blockAds = UIImage(named: "MenuBlockAds")
    static let blockTrackers = UIImage(named: "MenuBlockTrackers")
    static let blockCookieBanners = UIImage(named: "MenuBlockCookieBanners")
    static let bypassPaywall = UIImage(named: "MenuBypassPaywall")
    /// The arrow from Tabler's cloud download, enlarged slightly and centred.
    static let downloads = UIImage(named: "MenuDownloads")
    static let syncTabs = UIImage(named: "MenuSyncTabs")

    static let summarise: UIImage = {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 6, y: 10))
        path.addLine(to: CGPoint(x: 10, y: 10))
        path.addLine(to: CGPoint(x: 10, y: 6))
        path.move(to: CGPoint(x: 4.75, y: 4.75))
        path.addLine(to: CGPoint(x: 10, y: 10))
        path.move(to: CGPoint(x: 18, y: 14))
        path.addLine(to: CGPoint(x: 14, y: 14))
        path.addLine(to: CGPoint(x: 14, y: 18))
        path.move(to: CGPoint(x: 14, y: 14))
        path.addLine(to: CGPoint(x: 19.25, y: 19.25))
        return image(path)
    }()

    static let findOnPage: UIImage = {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 20, y: 11))
        path.addLine(to: CGPoint(x: 20, y: 9))
        path.addArc(withCenter: CGPoint(x: 18, y: 9), radius: 2,
                    startAngle: 0, endAngle: -.pi/2, clockwise: false)
        path.addLine(to: CGPoint(x: 6, y: 7))
        path.addArc(withCenter: CGPoint(x: 6, y: 9), radius: 2,
                    startAngle: -.pi/2, endAngle: -.pi, clockwise: false)
        path.addLine(to: CGPoint(x: 4, y: 14))
        path.addArc(withCenter: CGPoint(x: 6, y: 14), radius: 2,
                    startAngle: .pi, endAngle: .pi/2, clockwise: false)
        path.addLine(to: CGPoint(x: 11, y: 16))
        path.append(UIBezierPath(ovalIn: CGRect(x: 15, y: 15, width: 6, height: 6)))
        path.move(to: CGPoint(x: 20.2, y: 20.2))
        path.addLine(to: CGPoint(x: 22, y: 22))
        return image(path)
    }()

    private static func image(_ path: UIBezierPath) -> UIImage {
        let side: CGFloat = 28, scale = side/24
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let drawing = context.cgContext
            drawing.translateBy(x: side/2-path.bounds.midX*scale, y: side/2-path.bounds.midY*scale)
            drawing.scaleBy(x: scale, y: scale)
            drawing.setStrokeColor(UIColor.black.cgColor)
            drawing.setLineWidth(1.8/scale)
            drawing.setLineCap(.round)
            drawing.setLineJoin(.round)
            drawing.addPath(path.cgPath)
            drawing.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }
}
