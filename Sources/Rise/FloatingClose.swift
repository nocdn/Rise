import AppKit

/// How Rise's floating video and a page's floating window (Meet's call) come in: growing from 90%
/// on a spring with a light bounce, while fading in from clear on an ease in and out, so the first
/// frames stay faint. The engine's fade for a page's window (patch 0011) matches `fadeDuration`.
enum FloatingEntrance {
    static let startScale: CGFloat = 0.9, stiffness = 540.0, dampingRatio = 0.62
    static let fadeDuration: TimeInterval = 0.16
    static let fadeTiming = CAMediaTimingFunction(name: .easeInEaseOut)
}

/// iOS's picture in picture closing, measured frame by frame from a recording at 60 fps: the
/// window fades, blurs and shrinks toward its middle together, gone in 310 ms. Rise's floating
/// video and a page's floating window (Meet's call) both close this way.
enum FloatingClose {
    static let duration: CFTimeInterval = 0.31
    static let keys = ["closeOpacity", "closeScale", "closeBlur"]
    /// `width` is the window's, against iOS's 371-point one, so the blur keeps its look at any size.
    /// The blur is what Core Animation needs to be given for its frames to measure as iOS's do: it
    /// draws large radii a little softer than asked.
    static func curves(at time: Double, width: CGFloat) -> (opacity: CGFloat, scale: CGFloat, blur: CGFloat) {
        let time = min(max(0, time), duration)
        let opacity = time < duration ? exp(-pow(time/0.156, 1.7)) : 0
        let scale = 1-0.294*(1-exp(-max(0, time-0.02)/0.25))
        let blur = 61*width/371*(1-exp(-max(0, time-0.0095)/0.187))
        return (CGFloat(opacity), CGFloat(scale), CGFloat(blur))
    }
    /// Plays the close on `layer`, about its middle, ending gone. The layer's view needs
    /// `layerUsesCoreImageFilters` for the blur.
    static func play(on layer: CALayer, width: CGFloat) {
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        func scaled(_ scale: CGFloat) -> CATransform3D {
            CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(center.x, center.y, 0), scale, scale, 1), -center.x, -center.y, 0)
        }
        let steps = 31
        let samples = (0...steps).map { curves(at: duration*Double($0)/Double(steps), width: width) }
        let keyTimes = (0...steps).map { NSNumber(value: Double($0)/Double(steps)) }
        func keyframes(_ path: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: path)
            animation.values = values; animation.keyTimes = keyTimes; animation.duration = duration
            // Until it starts, the window shows as it was, not as it ends.
            animation.calculationMode = .linear; animation.fillMode = .backwards; return animation
        }
        // A layer's filter works in points, as its content scale does.
        let blur = CIFilter(name: "CIGaussianBlur"); blur?.name = "closeBlur"
        let final = curves(at: duration, width: width)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The model holds the end, so nothing returns between the last frame and leaving.
        blur?.setValue(final.blur, forKey: kCIInputRadiusKey)
        layer.filters = blur.map { [$0] }; layer.opacity = 0; layer.transform = scaled(final.scale)
        CATransaction.commit()
        layer.add(keyframes("opacity", samples.map(\.opacity)), forKey: keys[0])
        layer.add(keyframes("transform", samples.map { NSValue(caTransform3D: scaled($0.scale)) }), forKey: keys[1])
        if blur != nil { layer.add(keyframes("filters.closeBlur.inputRadius", samples.map(\.blur)), forKey: keys[2]) }
    }
}
