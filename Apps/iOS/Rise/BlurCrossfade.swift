import CoreImage
import UIKit

/// Swaps one view for another as a web page might with Motion: the incoming view fades in, grows
/// from 96% and sharpens from a slight blur, while the outgoing one does the reverse, its fade a
/// little quicker. Layers have no public blur filter on iOS, so each view's blurred state is a
/// blurred snapshot laid over it, faded in or out as the blur would grow or clear.
@MainActor enum BlurCrossfade {
    static let duration = 0.27
    /// The outgoing view's fade, quicker than the rest.
    static let exitFadeDuration = 0.19
    /// As `cubic-bezier(0.26, 0.08, 0.25, 1)`.
    static var timing: UICubicTimingParameters {
        UICubicTimingParameters(controlPoint1: CGPoint(x: 0.26, y: 0.08), controlPoint2: CGPoint(x: 0.25, y: 1))
    }
    static let scale: CGFloat = 0.96
    /// The blur's radius at its most, in points (CSS pixels): 1 at most.
    static let radius: CGFloat = 1
    private static let context = CIContext()
    private static var running: [UIViewPropertyAnimator] = []

    /// Both views keep their place in their superview as it animates; lay them out by bounds and
    /// center, as they're scaled.
    static func swap(from previous: UIView?, to next: UIView?) {
        // Carries on from wherever an interrupted swap had got to.
        for animator in running where animator.state == .active {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
        }
        running = []
        let shrunk = CGAffineTransform(scaleX: scale, y: scale)
        let outgoing = previous.flatMap(blurredCopy)
        let incoming = next.flatMap(blurredCopy)
        if let next {
            if next.alpha == 0 { next.transform = shrunk }
            incoming?.alpha = next.alpha == 0 ? 1 : 0
        }
        outgoing?.alpha = 0

        let move = UIViewPropertyAnimator(duration: duration, timingParameters: timing)
        move.addAnimations {
            next?.alpha = 1
            next?.transform = .identity
            incoming?.alpha = 0
            previous?.transform = shrunk
            outgoing?.alpha = 1
        }
        move.addCompletion { _ in
            incoming?.removeFromSuperview()
            outgoing?.removeFromSuperview()
            // Hidden now, so it can be put back for the next time it shows.
            if let previous, previous.alpha == 0 { previous.transform = .identity }
        }
        let fade = UIViewPropertyAnimator(duration: exitFadeDuration, timingParameters: timing)
        fade.addAnimations { previous?.alpha = 0 }
        running = [move, fade]
        move.startAnimation()
        fade.startAnimation()
    }

    /// Lays a blurred copy of the view, as it looks fully shown, over it, hidden for now.
    private static func blurredCopy(of view: UIView) -> UIImageView? {
        view.layoutIfNeeded()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let alpha = view.alpha
        view.alpha = 1
        let format = UIGraphicsImageRendererFormat(for: view.traitCollection)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { view.layer.render(in: $0.cgContext) }
        view.alpha = alpha
        guard let source = image.cgImage else { return nil }
        let input = CIImage(cgImage: source)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: radius*image.scale).cropped(to: input.extent)
        guard let output = context.createCGImage(blurred, from: input.extent) else { return nil }
        let copy = UIImageView(image: UIImage(cgImage: output, scale: image.scale, orientation: .up))
        copy.frame = view.bounds
        copy.isUserInteractionEnabled = false
        copy.isAccessibilityElement = false
        // Inside the view, so it scales and fades with it.
        view.addSubview(copy)
        return copy
    }
}
