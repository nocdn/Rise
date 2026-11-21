import UIKit

/// A compositor-animated plaque, tucked behind the toolbar on entry and dismissal.
/// Finger tracking changes only its transform; it never lays out or snapshots per frame.
@MainActor class Toast: UIView {
    let symbol = AnimatedSymbolButton(symbol: "")
    let label = TorphTextView()
    let motion = PanelMotion()
    private let motionName: String
    private let surface = ToastSurface()
    private let pan = UIPanGestureRecognizer()
    private var removal: Task<Void, Never>?
    /// How long it stays once let go of after a drag that didn't dismiss it; nil until it's set to leave.
    private var lingerAfterDrag: Double?
    private var exitCompletion: ToastAnimationCompletion?
    private var resizeDiagnostics: Task<Void,Never>?
    private var dragStart = CGPoint.zero
    private var dragInput = CGPoint.zero
    private var dragScale: CGFloat = 1
    private var dragScaleCorrection: CGFloat = 0
    /// Before the text: room for the icon, or less where a toast has none at its start.
    let leadingInset: CGFloat
    /// Past the text. A busier icon looks better balanced with less. A change takes effect
    /// with the next `setMessage`, which animates the width to it.
    var trailingInset: CGFloat
    private var contentInsets: CGFloat { leadingInset+trailingInset }
    private var hiddenOffset: CGFloat = 90
    private var contentWidth: CGFloat = 140
    private let sizeTransition = TorphSizeTransition()
    private(set) var widthAnimationCount = 0
    private(set) var dismissed = false
    var onDismiss: (() -> Void)?
    /// Views a subclass adds that follow the width as a message changes it, as the surface does.
    var widthFollowers: [UIView] { [] }
    /// Draws the shadow; a subclass that scales its contents when pressed moves it there.
    var shadowCaster: CALayer { layer }

    init(message: String, motionName: String, leadingInset: CGFloat = 47, trailingInset: CGFloat = 22) {
        self.motionName = motionName
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        super.init(frame: .zero)
        addSubview(surface)
        layer.shadowColor = UIColor.systemBlue.cgColor
        layer.shadowOpacity = 0.14; layer.shadowRadius = 12; layer.shadowOffset = CGSize(width: 0, height: 4)
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .white; label.timing = .standard
        label.setText(message, animated: false)
        contentWidth = label.intrinsicContentSize.width+contentInsets
        symbol.tintColor = .white; symbol.isUserInteractionEnabled = false
        addSubview(symbol); addSubview(label)
        pan.addTarget(self, action: #selector(dragged))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        isAccessibilityElement = true; accessibilityTraits = .staticText
        accessibilityLabel = label.text
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Dismiss", actionHandler: { [weak self] _ in
            self?.dismiss(); return true
        })]
    }
    /// A message that's already settled, with its icon.
    convenience init(message: String, glyph: UIImage?, name: String, trailingInset: CGFloat = 22) {
        self.init(message: message, motionName: "toast", trailingInset: trailingInset)
        symbol.setGlyph(glyph, name: name)
    }
    required init?(coder: NSCoder) { fatalError() }

    func place(above barTop: CGFloat, in rect: CGRect, safeTop: CGFloat) {
        let width = min(rect.width-40, contentWidth)
        bounds = CGRect(x: 0, y: 0, width: max(140, width), height: 54)
        center = CGPoint(x: rect.midX, y: max(safeTop+35, barTop-12-27))
        hiddenOffset = barTop-(center.y-bounds.height/2)+12
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 17).cgPath
        CATransaction.commit()
        surface.frame = bounds
        symbol.frame = CGRect(x: 12, y: 11, width: 32, height: 32)
        label.frame = CGRect(x: leadingInset, y: 0, width: bounds.width-63, height: bounds.height)
    }
    func appear() {
        layoutIfNeeded()
        var from = CATransform3DMakeTranslation(0, hiddenOffset, 0)
        from = CATransform3DScale(from, 0.9, 0.9, 1)
        spring(from: from, velocity: 0)
    }
    /// Content changes own their size transaction. Ordinary parent layouts never
    /// measure live text, so an icon swap cannot pre-empt the width animation.
    func setMessage(_ title: String, animated: Bool = true) {
        let layers = [layer,surface.layer,label.layer]+widthFollowers.map(\.layer)
        let poses = layers.map { ($0.presentation() ?? $0).bounds.size }
        let positions = layers.map { ($0.presentation() ?? $0).position }
        label.setText(title,animated: animated)
        let naturalWidth = label.intrinsicContentSize.width+contentInsets
        guard let parent = superview else { contentWidth = naturalWidth; return }
        let target = max(140,min(parent.bounds.width-40,naturalWidth))
        let canAnimate = animated && window != nil && !UIAccessibility.isReduceMotionEnabled && label.timing.duration.isFinite && label.timing.duration > 0
        let run = canAnimate ? sizeTransition.retarget(from: bounds.width,to: target,visible: layer.presentation()?.bounds.width,timing: label.timing) : nil
        UIView.performWithoutAnimation {
            contentWidth = naturalWidth
            place(above: center.y+39,in: parent.bounds,safeTop: parent.safeAreaInsets.top)
            layoutIfNeeded()
        }
        guard let run else {
            if !canAnimate {
                sizeTransition.reset(); resizeDiagnostics?.cancel()
                for item in layers {
                    for key in ["toast.width","toast.width-position","toast.width-shadow"] { item.removeAnimation(forKey: key) }
                }
                shadowCaster.removeAnimation(forKey: "toast.width-shadow")
            }
            return
        }
        widthAnimationCount += 1
        motion.begin(motionName,screen: window?.screen,minimumFPS: 120)
        motion.event("resize from=\(run.from) to=\(run.to) duration=\(run.timing.duration)")
        for (index, item) in layers.enumerated() {
            var from = poses[index]
            if index == 0 { from.width = run.from }
            let to = item.bounds.size
            TorphAnimation.add(to: item,path: "bounds.size",key: "toast.width",timing: run.timing,screen: window?.screen) {
                NSValue(cgSize: TorphAnimation.mix(from,to,$0))
            }
            if index > 0 {
                let from = positions[index], to = item.position
                TorphAnimation.add(to: item,path: "position",key: "toast.width-position",timing: run.timing,screen: window?.screen) {
                    NSValue(cgPoint: TorphAnimation.mix(from,to,$0))
                }
            }
        }
        TorphAnimation.add(to: shadowCaster,path: "shadowPath",key: "toast.width-shadow",timing: run.timing,screen: window?.screen) { progress in
            UIBezierPath(roundedRect: CGRect(x: 0,y: 0,width: TorphAnimation.mix(run.from,run.to,progress),height: 54),cornerRadius: 17).cgPath
        }
        motion.settle(for: max(0.48,run.timing.duration))
        resizeDiagnostics?.cancel()
        resizeDiagnostics = Task { [weak self] in
            for delay in [30,50,80,240] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self, !dismissed else { return }
                let root = layer.presentation()?.bounds.width ?? bounds.width
                let paint = surface.layer.presentation()?.bounds.width ?? surface.bounds.width
                motion.event("resize frame root=\(root) surface=\(paint)")
            }
        }
    }
    /// Dismisses it after `seconds`, or `afterDrag` seconds once a drag lets go of it.
    func leave(after seconds: Double, afterDrag: Double? = nil) {
        lingerAfterDrag = afterDrag ?? seconds
        scheduleRemoval(after: seconds)
    }
    private func scheduleRemoval(after seconds: Double) {
        removal?.cancel()
        removal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)); self?.dismiss() } catch { }
        }
    }
    func dismiss(animated: Bool = true,velocity: CGPoint? = nil) {
        guard !dismissed else { return }
        dismissed = true; isUserInteractionEnabled = false; removal?.cancel()
        let from = velocity != nil ? layer.transform : layer.presentation()?.transform ?? layer.transform
        layer.removeAnimation(forKey: "toast.appear")
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else { remove(); return }
        motion.begin(motionName, screen: window?.screen, minimumFPS: 120)
        if let velocity, let parent = superview {
            let exitY = parent.bounds.maxY-center.y+bounds.height/2+24
            let flight = ToastInteraction.flight(from: CGPoint(x: from.m41,y: from.m42),velocity: velocity,exitY: exitY)
            let animation = CAKeyframeAnimation(keyPath: "transform")
            let correction = from.m11-ToastInteraction.dismissalScale(at: from.m42,travel: hiddenOffset)
            animation.values = flight.points.map { point in
                let scale = ToastInteraction.dismissalScale(at: point.y,travel: hiddenOffset)+correction
                return NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(point.x,point.y,0),scale,scale,1))
            }
            animation.duration = flight.duration; animation.calculationMode = .linear
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.transform = (animation.values!.last as! NSValue).caTransform3DValue
            CATransaction.commit()
            motion.event("flick vx=\(velocity.x) vy=\(velocity.y) duration=\(flight.duration)")
            completeRemoval(after: animation)
            setRate(animation); layer.add(animation,forKey: "toast.dismiss")
            motion.settle(for: flight.duration)
            return
        }
        let target = CATransform3DScale(CATransform3DMakeTranslation(0, hiddenOffset, 0), 0.9, 0.9, 1)
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = target; CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = from; animation.toValue = target; animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0, 0.67, 0)
        completeRemoval(after: animation)
        setRate(animation); layer.add(animation, forKey: "toast.dismiss")
        motion.settle(for: 0.2)
    }
    private func completeRemoval(after animation: CAAnimation) {
        let completion = ToastAnimationCompletion { [weak self] in self?.remove() }
        exitCompletion = completion; animation.delegate = completion
    }
    private func remove() { exitCompletion = nil; resizeDiagnostics?.cancel(); motion.stop(); removeFromSuperview(); onDismiss?(); onDismiss = nil }
    private func spring(from: CATransform3D, velocity: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = CATransform3DIdentity; CATransaction.commit()
        guard !UIAccessibility.isReduceMotionEnabled else { motion.stop(); return }
        motion.begin(motionName, screen: window?.screen, minimumFPS: 120)
        let animation = CASpringAnimation(keyPath: "transform")
        animation.mass = 1; animation.stiffness = 600; animation.damping = 39
        animation.initialVelocity = velocity; animation.duration = 0.48
        animation.fromValue = from; animation.toValue = CATransform3DIdentity
        setRate(animation); layer.add(animation, forKey: "toast.appear")
        motion.settle(for: animation.duration)
    }
    private func setRate(_ animation: CAAnimation) {
        let fps = Float(min(120, window?.screen.maximumFramesPerSecond ?? 120))
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let began = CACurrentMediaTime()
        switch gesture.state {
        case .began:
            beginDrag()
            trackDrag(gesture.translation(in: superview))
        case .changed:
            trackDrag(gesture.translation(in: superview)); motion.tracked(since: began)
        case .ended, .cancelled:
            trackDrag(gesture.translation(in: superview))
            endDrag(velocity: gesture.velocity(in: superview),cancelled: gesture.state == .cancelled)
        default: break
        }
    }
    func beginDrag() {
        removal?.cancel()
        let current = layer.presentation()?.transform ?? layer.transform
        dragStart = ToastInteraction.untracked(CGPoint(x: current.m41,y: current.m42))
        dragInput = dragStart; dragScale = current.m11
        dragScaleCorrection = current.m11-ToastInteraction.dismissalScale(at: current.m42,travel: hiddenOffset)
        layer.removeAnimation(forKey: "toast.appear")
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = current; CATransaction.commit()
        motion.begin(motionName,screen: window?.screen,minimumFPS: 120)
        motion.event("drag.begin")
    }
    func trackDrag(_ translation: CGPoint) {
        dragInput = CGPoint(x: dragStart.x+translation.x,y: dragStart.y+translation.y)
        let point = ToastInteraction.tracked(dragInput)
        dragScale = ToastInteraction.dismissalScale(at: point.y,travel: hiddenOffset)+dragScaleCorrection
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DScale(CATransform3DMakeTranslation(point.x,point.y,0),dragScale,dragScale,1)
        CATransaction.commit()
    }
    func endDrag(velocity raw: CGPoint,cancelled: Bool = false) {
        let point = CGPoint(x: layer.transform.m41,y: layer.transform.m42)
        let velocity = cancelled ? .zero : ToastInteraction.releaseVelocity(raw,at: dragInput)
        motion.event("drag.release dx=\(point.x) dy=\(point.y) vx=\(velocity.x) vy=\(velocity.y) cancelled=\(cancelled)")
        if !cancelled, ToastInteraction.shouldDismiss(offset: point,velocity: velocity,intendedVelocity: raw) {
            dismiss(velocity: velocity); return
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.duration = 0.5; animation.calculationMode = .linear
        animation.values = (0...60).map { frame in
            if frame == 60 { return NSValue(caTransform3D: CATransform3DIdentity) }
            let t = Double(frame)/120
            let x = ToastInteraction.spring(from: point.x,to: 0,velocity: velocity.x,stiffness: 340,time: t)
            let y = ToastInteraction.spring(from: point.y,to: 0,velocity: velocity.y,stiffness: 340,time: t)
            let scale = ToastInteraction.spring(from: dragScale,to: 1,velocity: 0,stiffness: 340,time: t)
            return NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(x,y,0),scale,scale,1))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = CATransform3DIdentity; CATransaction.commit()
        if !UIAccessibility.isReduceMotionEnabled { setRate(animation); layer.add(animation,forKey: "toast.appear") }
        motion.settle(for: animation.duration)
        if let lingerAfterDrag { scheduleRemoval(after: lingerAfterDrag) }
    }
    isolated deinit { removal?.cancel(); resizeDiagnostics?.cancel() }
}

/// Cleanup follows the actual compositor completion, including a delayed commit.
/// A wall-clock timer can remove a fast flick before its first displayed frame.
@MainActor private final class ToastAnimationCompletion: NSObject, CAAnimationDelegate {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    nonisolated func animationDidStop(_ animation: CAAnimation,finished flag: Bool) {
        guard flag else { return }
        Task { @MainActor [self] in completion() }
    }
}

extension Toast {
    /// Over the surface's gradient and clipped to its corners, under the icon and text.
    func addToSurface(_ view: UIView) {
        surface.layer.masksToBounds = true
        surface.addSubview(view)
    }
}

@MainActor private final class ToastSurface: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as! CAGradientLayer
        gradient.colors = [UIColor(red: 0.28, green: 0.28, blue: 1, alpha: 1).cgColor,
                           UIColor(red: 0.16, green: 0.16, blue: 0.88, alpha: 1).cgColor]
        gradient.cornerRadius = 17; gradient.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
}
