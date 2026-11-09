import UIKit

/// A small incoming impulse shared by download arrivals and page-status cues.
@MainActor enum ToolbarLandingImpact {
    static let duration = 0.55
    private static let spring = SummariseSpring(2 * .pi/0.34, 0.6)

    static func transform(at time: Double, direction: CGVector) -> CATransform3D {
        guard time > 0, time < duration else { return CATransform3DIdentity }
        let length = max(1, hypot(direction.dx, direction.dy))
        let dx = direction.dx/length, dy = direction.dy/length
        let k = spring.value(from: 0, to: 0, velocity: 46, at: time)
        var result = CATransform3DMakeTranslation(dx*2.2*k, dy*2.2*k, 0)
        result = CATransform3DRotate(result, dx*0.035*k, 0, 0, 1)
        return CATransform3DScale(result, 1+0.025*k, 1-0.04*k, 1)
    }
}
