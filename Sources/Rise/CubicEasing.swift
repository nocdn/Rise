import Foundation

/// CSS-style cubic Bézier easing.
struct CubicEasing {
    private let ax, bx, cx, ay, by, cy: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3*x1; bx = 3*(x2-x1)-cx; ax = 1-cx-bx
        cy = 3*y1; by = 3*(y2-y1)-cy; ay = 1-cy-by
    }
    private func sampleX(_ t: Double) -> Double { ((ax*t+bx)*t+cx)*t }
    private func sampleY(_ t: Double) -> Double { ((ay*t+by)*t+cy)*t }
    private func slopeX(_ t: Double) -> Double { (3*ax*t+2*bx)*t+cx }
    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }; if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t)-x, slope = slopeX(t)
            if abs(error) < 1e-6 || abs(slope) < 1e-6 { break }
            t -= error/slope
        }
        if !(t >= 0 && t <= 1) || abs(sampleX(t)-x) > 1e-4 {
            var low = 0.0, high = 1.0; t = x
            for _ in 0..<40 { if sampleX(t) < x { low = t } else { high = t }; t = (low+high)/2 }
        }
        return sampleY(t)
    }
}

