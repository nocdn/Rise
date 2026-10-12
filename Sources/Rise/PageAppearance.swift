import AppKit
import SwiftUI

/// Measured against Dia's native window at 2x: six-point outer margins,
/// continuous corners, and a tight shadow concentrated below the page.
enum PageAppearance {
    static let inset: CGFloat = 6
    static let radius: CGFloat = 9.5
    static let shadowOpacity: CGFloat = 0.14
    static let shadowBlur: CGFloat = 2
    static let shadowOffset: CGFloat = 1

    static func frame(in bounds: NSRect, sidebarWidth: CGFloat, sidebarVisible: Bool) -> NSRect {
        let left = sidebarVisible ? sidebarWidth : inset
        return NSRect(x: bounds.minX+left, y: bounds.minY+inset,
                      width: max(0, bounds.width-left-inset), height: max(0, bounds.height-2*inset))
    }
}

enum PageOutline {
    static func path(in rect: CGRect, radius: CGFloat, continuous: Bool) -> CGPath {
        // Apple's public continuous shape supplies the same smooth contour to
        // the explicit shadow path and the page masks. A circular
        // shadow around a continuous clip otherwise leaves mismatched corners.
        if continuous {
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
        }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
