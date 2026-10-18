import Foundation

/// A damped spring integrated in 1 ms steps, matching the playgrounds'. Springs use the
/// (perceptual duration, bounce) pair of `CASpringAnimation(perceptualDuration:bounce:)`.
struct MotionSpring {
    var value: Double, velocity = 0.0, target: Double
    private var stiffness = 0.0, damping = 0.0
    init(_ value: Double = 0) { self.value = value; target = value }
    mutating func configure(response: Double, bounce: Double) {
        let ratio = 1 - min(0.95, max(0, bounce))
        stiffness = pow(2 * .pi/response, 2); damping = 4 * .pi*ratio/response
    }
    mutating func step(_ dt: Double) {
        var left = dt
        while left > 0 {
            let h = min(0.001, left)
            velocity += (-stiffness*(value-target) - damping*velocity)*h; value += velocity*h
            left -= 0.001
        }
    }
    func isResting(within tolerance: Double) -> Bool { abs(value-target) < tolerance && abs(velocity) < tolerance*10 }
}

/// A damped spring solved in closed form, as the iOS app's motion is: its progress from
/// 0 towards 1, or from one value to another with a starting velocity.
struct ClosedSpring {
    let w: Double, z: Double
    init(response: Double, damping: Double) { w = 2 * .pi/response; z = damping }
    func value(from: Double, to: Double, velocity: Double, at t: Double) -> Double {
        guard t > 0 else { return from }
        let d = from-to
        if z < 1 {
            let wd = w*(1-z*z).squareRoot()
            return to+exp(-z*w*t)*(d*cos(wd*t)+(velocity+z*w*d)/wd*sin(wd*t))
        }
        return to+exp(-w*t)*(d+(velocity+w*d)*t)
    }
    func callAsFunction(_ t: Double) -> Double { value(from: 0, to: 1, velocity: 0, at: t) }
}
