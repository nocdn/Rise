import UIKit

/// Torph's sampled easing, interrupted-size carry and proportional fades, on Core Animation.
/// MIT © 2025 Lochie Axon; see Torph-LICENSE.txt. No display-link layout or drawing.
enum TorphAnimation {
    struct Timing: Sendable {
        var duration: Double
        var curve: @Sendable (Double) -> Double
        static let standard = Timing(duration: 0.4, curve: TorphAnimation.cubic)
    }
    static func cubic(_ x: Double) -> Double {
        func bezier(_ t: Double, _ p: Double, _ q: Double) -> Double { 3*(1-t)*(1-t)*t*p+3*(1-t)*t*t*q+t*t*t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 { let t = (lo+hi)/2; if bezier(t,0.19,0.22) < x { lo = t } else { hi = t } }
        return x <= 0 ? 0 : x >= 1 ? 1 : bezier((lo+hi)/2,1,1)
    }
    static func slope(_ curve: (Double) -> Double, _ t: Double) -> Double {
        let a = min(max(t,0),1-0.0001)
        return (curve(a+0.0001)-curve(a))/0.0001
    }
    static func carried(_ base: @escaping @Sendable (Double) -> Double, velocity: Double) -> @Sendable (Double) -> Double {
        let k = max(0,min(8,velocity)-slope(base,0))
        guard k.isFinite, k > 0 else { return base }
        let bump = max(3,ceil(k/(exp(1)*0.1))-1)
        return { t in t >= 1 ? 1 : base(t)+k*t*pow(1-t,bump) }
    }
    @MainActor static func add(to layer: CALayer, path: String, key: String, timing: Timing,
                    delay: Double = 0, screen: UIScreen? = nil, value: (Double) -> Any) {
        guard timing.duration.isFinite, timing.duration > 0 else { return }
        let count = min(120,max(32,Int((timing.duration/0.008).rounded())))
        let animation = CAKeyframeAnimation(keyPath: path)
        animation.values = (0..<count).map { i in value(i == count-1 ? 1 : timing.curve(Double(i)/Double(count-1))) }
        animation.duration = timing.duration; animation.calculationMode = .linear
        // A native menu dismissal or first icon snapshot can hold this transaction
        // open. Zero starts at commit, like WAAPI's pending start, rather than
        // spending the morph's duration before anything has reached the display.
        animation.fillMode = .backwards
        let fps = Float(min(120,screen?.maximumFramesPerSecond ?? 120))
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(80,fps),maximum: fps,preferred: fps)
        if delay > 0 {
            animation.beginTime = delay
            let group = CAAnimationGroup()
            group.animations = [animation]; group.duration = delay+timing.duration
            group.preferredFrameRateRange = animation.preferredFrameRateRange
            layer.add(group,forKey: key)
        } else { layer.add(animation, forKey: key) }
    }
    @MainActor static func keyframes(in layer: CALayer,key: String) -> CAKeyframeAnimation? {
        let animation = layer.animation(forKey: key)
        return animation as? CAKeyframeAnimation ?? (animation as? CAAnimationGroup)?.animations?.first as? CAKeyframeAnimation
    }
    static func mix(_ from: CGFloat, _ to: CGFloat, _ t: Double) -> CGFloat { from+(to-from)*t }
    static func mix(_ from: CGPoint, _ to: CGPoint, _ t: Double) -> CGPoint { .init(x: mix(from.x,to.x,t),y: mix(from.y,to.y,t)) }
    static func mix(_ from: CGSize, _ to: CGSize, _ t: Double) -> CGSize { .init(width: mix(from.width,to.width,t),height: mix(from.height,to.height,t)) }
}

/// One axis, with Torph's same-target continuation and bounded momentum on interruption.
@MainActor final class TorphSizeTransition {
    struct Run {
        var from: CGFloat, to: CGFloat, started: Double
        var timing: TorphAnimation.Timing
        func progress(_ now: Double) -> Double { min(1,max(0,(now-started)/timing.duration)) }
        func value(_ now: Double) -> CGFloat { TorphAnimation.mix(from,to,timing.curve(progress(now))) }
        func velocity(_ now: Double) -> Double {
            progress(now) < 1 ? Double(to-from)*TorphAnimation.slope(timing.curve,progress(now))/timing.duration : 0
        }
    }
    private(set) var run: Run?
    func retarget(from fallback: CGFloat, to target: CGFloat, visible: CGFloat? = nil, timing: TorphAnimation.Timing,
                  now: Double = CACurrentMediaTime()) -> Run? {
        guard timing.duration.isFinite, timing.duration > 0 else { reset(); return nil }
        if let run, run.progress(now) < 1, abs(run.to-target) < 0.5 { return nil }
        let current = visible ?? run.map { $0.value(now) } ?? fallback
        let velocity = run?.velocity(now) ?? 0, delta = Double(target-current)
        let curve = abs(delta) > 0.5 ? TorphAnimation.carried(timing.curve,velocity: velocity*timing.duration/delta) : timing.curve
        let next = Run(from: current,to: target,started: now,timing: .init(duration: timing.duration,curve: curve))
        run = next; return next
    }
    func reset() { run = nil }
}
