import UIKit

/// Older tabs rise out of the toolbar's little stack while the current page moves right.
/// Explicit, 120 Hz keyframes keep the fan moving while WebKit draws its deferred thumbnail.
@MainActor final class TabDeckEntrance {
    private(set) var isPrepared = false
    private var origin = CGPoint.zero
    private var radius: CGFloat = 0
    private var progress: CGFloat = 0
    private static let prefix = "deck."

    func prepare(size: CGSize, bottomInset: CGFloat, radius: CGFloat) {
        isPrepared = true
        progress = 0
        origin = CGPoint(x: BottomBar.sideCentre, y: size.height-bottomInset/2)
        self.radius = radius
    }

    func place(_ cell: TabCell, depth: Int) {
        let start = CGPoint(x: origin.x-CGFloat(depth)*3, y: origin.y-CGFloat(depth)*5)
        cell.center = CGPoint(x: start.x+(cell.center.x-start.x)*progress, y: start.y+(cell.center.y-start.y)*progress)
        let scale = 0.18+0.82*progress
        cell.transform = CGAffineTransform(rotationAngle: (-0.08-Double(depth)*0.035)*(1-progress)).scaledBy(x: scale, y: scale)
        for layer in cell.roundingLayers { layer.cornerRadius = radius+(TabSwitcherView.cornerRadius-radius)*progress }
        cell.setNeedsLayout(); cell.layoutIfNeeded()
    }

    func follow(_ progress: CGFloat) { self.progress = min(1, max(0, progress*1.6)) }

    func animate(cells: [TabCell], current: Int, order: [Int], cardWidth: CGFloat, frame: (Int) -> CGRect) {
        isPrepared = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let start = CACurrentMediaTime(), duration = 0.46, samples = 56
        for (slot, index) in order.enumerated() where index != current {
            let cell = cells[index]
            let shown = cell.layer.presentation() ?? cell.layer
            let from = shown.position, transform = CATransform3DGetAffineTransform(shown.transform)
            let fromRadius = cell.card.layer.presentation()?.cornerRadius ?? cell.card.layer.cornerRadius
            stop(cell)
            let target = frame(slot)
            cell.center = CGPoint(x: target.midX, y: target.midY)
            cell.transform = .identity
            let targetRadius = TabSwitcherView.cornerRadius*target.width/max(1, cardWidth)
            cell.card.layer.cornerRadius = targetRadius
            cell.setNeedsLayout(); cell.layoutIfNeeded()
            guard !cell.isHidden else { continue }
            let delay = Double(min(4, order.count-1-slot))*0.012
            // A critically damped approach never overshoots. Normalise its finite
            // tail so the final keyframe meets the resting pose exactly too.
            let end = TabDeckMotion.stack(duration-delay)
            let progress = (0..<samples).map { i in
                TabDeckMotion.stack(max(0, Double(i)*duration/Double(samples-1)-delay))/end
            }
            func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a+(b-a)*p }
            func keyframes(_ layer: CALayer, _ key: String, _ values: [Any]) {
                let animation = CAKeyframeAnimation(keyPath: key)
                animation.values = values; animation.duration = duration
                animation.calculationMode = .linear
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                animation.beginTime = layer.convertTime(start, from: nil)
                layer.add(animation, forKey: Self.prefix+key)
            }
            keyframes(cell.layer, "position", progress.map {
                NSValue(cgPoint: CGPoint(x: mix(from.x, target.midX, $0), y: mix(from.y, target.midY, $0)))
            })
            keyframes(cell.layer, "transform", progress.map { p in
                NSValue(caTransform3D: CATransform3DMakeAffineTransform(CGAffineTransform(
                    a: mix(transform.a, 1, p), b: mix(transform.b, 0, p),
                    c: mix(transform.c, 0, p), d: mix(transform.d, 1, p),
                    tx: mix(transform.tx, 0, p), ty: mix(transform.ty, 0, p))))
            })
            for layer in cell.roundingLayers { keyframes(layer, "cornerRadius", progress.map { mix(fromRadius, targetRadius, $0) }) }
            keyframes(cell.cardShadow.layer, "shadowPath", progress.map {
                UIBezierPath(roundedRect: cell.cardShadow.bounds, cornerRadius: mix(fromRadius, targetRadius, $0)).cgPath
            })
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    func stop(_ cell: TabCell) {
        for layer in [cell.layer, cell.cardShadow.layer]+cell.roundingLayers {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.prefix) { layer.removeAnimation(forKey: key) }
        }
    }
    func stop(cells: [TabCell]) {
        isPrepared = false
        cells.forEach(stop)
    }

    /// A close can interrupt the incoming stack. Preserve its displayed pose before
    /// removing the entry keyframes so the gap closes from where the cards really are.
    func freeze(cells: [TabCell]) {
        UIView.performWithoutAnimation {
            for cell in cells where cell.layer.animation(forKey: Self.prefix+"position") != nil {
                let shown = cell.layer.presentation() ?? cell.layer
                let position = shown.position, transform = shown.transform
                let radius = cell.card.layer.presentation()?.cornerRadius ?? cell.card.layer.cornerRadius
                stop(cell)
                cell.center = position
                cell.transform = CATransform3DGetAffineTransform(transform)
                cell.card.layer.cornerRadius = radius
                cell.setNeedsLayout(); cell.layoutIfNeeded()
            }
        }
        isPrepared = false
    }
}
