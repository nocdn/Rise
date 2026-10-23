import UIKit

/// UIKit port of Torph's text engine: word/character identity, FLIP, anchored
/// entry/exit, grouped replacements and presentation-state interruption.
/// MIT © 2025 Lochie Axon; see Torph-LICENSE.txt. Numeric rolling is separate upstream.
@MainActor final class TorphTextView: UIView {
    var font: UIFont = .systemFont(ofSize: 16) { didSet { rebuild() } }
    var textColor: UIColor = .label { didSet { fragments.values.forEach { $0.ink = textColor; $0.setNeedsDisplay() } } }
    var locale = "en" { didSet { rebuild() } }
    var timing = TorphAnimation.Timing.standard
    var disabled = false { didSet { if disabled { settle() } } }
    var onAnimationStart: (() -> Void)?
    var onAnimationComplete: (() -> Void)?
    var onAnimationCancel: (() -> Void)?
    private(set) var text: String?
    private(set) var segments: [TorphText.Segment] = []
    private(set) var fragments: [String: TorphFragmentView] = [:]
    private(set) var animating = false
    private var completion: Task<Void,Never>?
    private var measuredSize = CGSize.zero
    private var first = true
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true; accessibilityTraits = .staticText
        observer = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification,object: nil,queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: CGSize { measuredSize }
    override func layoutSubviews() {
        super.layoutSubviews()
        // A position-only parent layout must never reconcile text or restart a morph.
        let top = (bounds.height-measuredSize.height)/2
        for fragment in fragments.values {
            var frame = fragment.fragment.frame; frame.origin.y += top
            if fragment.frame != frame { UIView.performWithoutAnimation { fragment.frame = frame } }
        }
    }
    func setText(_ value: String, animated: Bool = true) {
        guard value != text else { return }
        if animating { completion?.cancel(); animating = false; onAnimationCancel?() }
        let oldSegments = segments
        text = value; accessibilityLabel = value
        let diff = oldSegments.isEmpty ? TorphText.Diff(segments: TorphText.segment(value,locale: locale),splits: [:]) : TorphText.diff(oldSegments,to: value,locale: locale)
        // As upstream, an empty value retains the line box until exiting text is gone.
        var next = diff.segments
        if next.count > 1024 { next = [.init(id: "large-value",text: value)] }
        let nextLayout = TorphTextLayout(next,font: font)
        let previousSize = measuredSize
        let canAnimate = animated && !first && !disabled && !UIAccessibility.isReduceMotionEnabled && window != nil && timing.duration.isFinite && timing.duration > 0
        first = false
        if !canAnimate {
            subviews.forEach { $0.removeFromSuperview() }; fragments = [:]; segments = next
            measuredSize = nextLayout.size; install(nextLayout)
            invalidateIntrinsicContentSize(); setNeedsLayout(); return
        }
        // Split a still-whole word at its current position, including a previous
        // animation's translation and opacity. Shaping stays whole-line Core Text.
        if !diff.splits.isEmpty {
            let flattened = oldSegments.flatMap { diff.splits[$0.id] ?? [$0] }
            let layout = TorphTextLayout(flattened,font: font)
            let expanded = Dictionary(uniqueKeysWithValues: layout.fragments.map { ($0.segment.id,$0) })
            for (id, parts) in diff.splits {
                guard let old = fragments.removeValue(forKey: id) else { continue }
                let pose = old.layer.presentation() ?? old.layer
                let delta = CGPoint(x: pose.position.x-old.layer.position.x,y: pose.position.y-old.layer.position.y)
                for part in parts {
                    guard let item = expanded[part.id] else { continue }
                    let child = TorphFragmentView(item,color: textColor)
                    child.frame.origin.y += (bounds.height-measuredSize.height)/2
                    child.frame.origin.x += delta.x; child.frame.origin.y += delta.y
                    child.layer.opacity = pose.opacity; addSubview(child); fragments[part.id] = child
                }
                old.removeFromSuperview()
            }
        }
        let oldOrder = oldSegments.flatMap { diff.splits[$0.id] ?? [$0] }.map(\.id)
        let old = fragments
        let newIDs = next.map(\.id), surviving = Set(newIDs).intersection(old.keys)
        let oldPoses = old.mapValues { view -> (CGPoint,Float,CATransform3D) in
            let layer = view.layer.presentation() ?? view.layer
            return (layer.position,layer.opacity,layer.transform)
        }
        let oldFrames = old.mapValues(\.frame)
        measuredSize = next.isEmpty ? previousSize : nextLayout.size; segments = next; fragments = [:]
        let y = (bounds.height-measuredSize.height)/2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for item in nextLayout.fragments {
            let child = old[item.segment.id] ?? TorphFragmentView(item,color: textColor)
            child.layer.removeAllAnimations(); child.update(item,color: textColor)
            child.frame = item.frame.offsetBy(dx: 0,dy: y); child.layer.opacity = 1; child.layer.transform = CATransform3DIdentity
            if child.superview == nil { addSubview(child) }
            fragments[item.segment.id] = child
        }
        CATransaction.commit()
        let entering = Set(newIDs).subtracting(old.keys), exiting = Set(old.keys).subtracting(newIDs)
        let enterGroups = TorphText.replacementRuns(ids: newIDs,members: entering)
        let exitGroups = TorphText.replacementRuns(ids: oldOrder,members: exiting)
        func centers(_ runs: [[String]], _ views: [String: TorphFragmentView]) -> [String: CGPoint] {
            var result: [String: CGPoint] = [:]
            for run in runs {
                let rect = run.compactMap { views[$0]?.frame }.reduce(CGRect.null) { $0.union($1) }
                run.forEach { result[$0] = CGPoint(x: rect.midX,y: rect.midY) }
            }
            return result
        }
        let enterCenters = centers(enterGroups,fragments), exitCenters = centers(exitGroups,old)
        for (id, child) in fragments {
            let isNew = entering.contains(id), target = child.layer.position
            let index = newIDs.firstIndex(of: id)!
            let anchor = isNew ? TorphText.nearestAnchor(at: index,ids: newIDs,persistent: surviving) : id
            let delta: CGPoint
            if let anchor, let previous = oldPoses[anchor], let destination = fragments[anchor] {
                delta = CGPoint(x: previous.0.x-destination.layer.position.x,y: previous.0.y-destination.layer.position.y)
            } else { delta = .zero }
            let groupCenter = enterCenters[id]
            let from = groupCenter.map { CGPoint(x: $0.x+(target.x-$0.x)*0.8,y: $0.y+(target.y-$0.y)*0.8) }
                ?? CGPoint(x: target.x+delta.x,y: target.y+delta.y)
            move(child,from: from,to: target,fromScale: groupCenter != nil ? 0.8 : isNew ? 0.95 : 1,toScale: 1)
            let alpha = isNew ? Float(0) : oldPoses[id]?.1 ?? 1
            if alpha < 1 {
                fade(child,from: alpha,to: 1,fraction: groupCenter != nil ? 0.35 : isNew ? 0.5 : 0.25,
                     delay: groupCenter != nil || !isNew ? 0 : timing.duration*0.25)
            }
        }
        for id in exiting {
            guard let child = old[id], let previous = oldPoses[id] else { continue }
            child.layer.removeAllAnimations()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            child.layer.position = previous.0; child.layer.transform = CATransform3DIdentity; child.layer.opacity = 0
            CATransaction.commit()
            let anchor = oldOrder.firstIndex(of: id).flatMap { TorphText.nearestAnchor(at: $0,ids: oldOrder,persistent: surviving,forwardFirst: true) }
            var target = previous.0
            if let anchor, let before = oldFrames[anchor], let after = fragments[anchor]?.frame {
                target.x += after.minX-before.minX; target.y += after.minY-before.minY
            }
            if let center = exitCenters[id] { target = CGPoint(x: center.x+(previous.0.x-center.x)*0.8,y: center.y+(previous.0.y-center.y)*0.8) }
            move(child,from: previous.0,to: target,fromScale: previous.2.m11,toScale: exitCenters[id] == nil ? 0.95 : 0.8)
            let fraction = exitCenters[id] == nil ? 0.25 : 0.45
            fade(child,from: previous.1,to: 0,fraction: fraction)
            child.remove(after: timing.duration*fraction+0.02)
        }
        invalidateIntrinsicContentSize()
        animating = true; onAnimationStart?()
        let duration = timing.duration
        completion = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
                guard let self else { return }
                animating = false; fragments.values.forEach { $0.layer.removeAllAnimations() }
                if segments.isEmpty { measuredSize = nextLayout.size; invalidateIntrinsicContentSize() }
                onAnimationComplete?()
            } catch { }
        }
    }
    private func move(_ view: UIView,from: CGPoint,to: CGPoint,fromScale: CGFloat,toScale: CGFloat) {
        TorphAnimation.add(to: view.layer,path: "position",key: "torph.position",timing: timing,screen: window?.screen) { NSValue(cgPoint: TorphAnimation.mix(from,to,$0)) }
        TorphAnimation.add(to: view.layer,path: "transform.scale",key: "torph.scale",timing: timing,screen: window?.screen) { TorphAnimation.mix(fromScale,toScale,$0) }
    }
    private func fade(_ view: UIView,from: Float,to: Float,fraction: Double,delay: Double = 0) {
        TorphAnimation.add(to: view.layer,path: "opacity",key: "torph.opacity",timing: .init(duration: timing.duration*fraction,curve: { $0 }),delay: delay,screen: window?.screen) { Double(from)+Double(to-from)*$0 }
    }
    private func install(_ layout: TorphTextLayout) {
        for fragment in layout.fragments {
            let view = TorphFragmentView(fragment,color: textColor); addSubview(view); fragments[fragment.segment.id] = view
        }
    }
    private func rebuild() {
        guard let text else { return }
        settle(); self.text = nil; first = true; segments = []; setText(text,animated: false)
    }
    private func settle() {
        completion?.cancel()
        if animating { animating = false; onAnimationCancel?() }
        subviews.filter { view in !fragments.values.contains { $0 === view } }.forEach { $0.removeFromSuperview() }
        fragments.values.forEach { $0.layer.removeAllAnimations(); $0.layer.opacity = 1; $0.layer.transform = CATransform3DIdentity }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { settle() } }
    isolated deinit { completion?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}
