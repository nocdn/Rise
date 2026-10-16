import UIKit

/// A row resists the finger until it detaches from its neighbours at the threshold.
/// Detachment springs it to the live finger position; reversing reconnects the rows.
@MainActor final class HistoryRowSwipe: NSObject, UIGestureRecognizerDelegate {
    let list: HistoryList
    private(set) lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag))
    var entry: ((Int) -> String?)?
    var commit: ((String) -> Void)?
    var remove: ((String, @escaping () -> Void) -> Void)?
    var isEnabled = true {
        didSet { pan.isEnabled = isEnabled; if !isEnabled { cancel() } }
    }
    private(set) var isArmed = false
    var isActive: Bool { cell != nil }
    var threshold: CGFloat { min(96, max(64, list.bounds.width*0.23)) }
    private let feedback = UIImpactFeedbackGenerator(style: .soft)
    private var cell: HistoryCell?
    private var key: String?
    private var distance: CGFloat = 0
    private var companions: [Companion] = []
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private enum Phase { case dragging, returning, leaving, collapsing }
    private var phase = Phase.dragging
    private var release = 0.0
    private var origin: CGFloat = 0, releaseVelocity: CGFloat = 0, destination: CGFloat = 0
    private var generation = 0
    private var touchOrigin: CGPoint?
    /// An additive spring relative to the moving finger, as in desktop tab detachment.
    private var attachment = Spring()

    private var trackingOffset: CGFloat {
        isArmed ? distance : distance*0.82/(1+abs(distance)/320)
    }

    private struct Companion {
        let cell: HistoryCell
        let weight: CGFloat
        var spring = Spring()
    }
    private struct Spring {
        var position = 0.0, velocity = 0.0
        mutating func step(to target: Double, dt: Double) {
            // Exact underdamped integration, independent of 60/120 Hz frame intervals.
            let w = 32.0, damping = 0.74, decay = damping*w
            let frequency = w*sqrt(1-damping*damping), offset = position-target
            let b = (velocity+decay*offset)/frequency
            let c = cos(frequency*dt), s = sin(frequency*dt), e = exp(-decay*dt)
            let wave = offset*c+b*s
            position = target+e*wave
            velocity = e*(-decay*wave+frequency*(-offset*s+b*c))
        }
    }

    init(list: HistoryList) {
        self.list = list
        super.init()
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        list.addGestureRecognizer(pan)
        list.panGestureRecognizer.require(toFail: pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled, !isActive, list.isUserInteractionEnabled else { return false }
        // UIKit may ask before it has a velocity sample; translation already gives
        // the gesture's direction and must not turn that first swipe into a tap.
        let delta = pan.translation(in: list), velocity = pan.velocity(in: list)
        let direction = abs(delta.x)+abs(delta.y) > 1 ? delta : velocity
        guard abs(direction.x) > abs(direction.y)*1.2 else { return false }
        return list.indexPathForItem(at: startPoint(pan)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !isActive else { return false }
        touchOrigin = touch.location(in: list)
        return true
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let start = touchOrigin ?? startPoint(gesture)
            guard let path = list.indexPathForItem(at: start), let cell = list.cellForItem(at: path) as? HistoryCell,
                  begin(cell) else { return }
            move(to: gesture.location(in: list).x-start.x)
        case .changed: move(to: displacement(gesture))
        case .ended:
            move(to: displacement(gesture))
            end(velocity: gesture.velocity(in: list).x)
        case .cancelled, .failed: end(velocity: 0, cancelled: true)
        default: break
        }
    }

    private func displacement(_ gesture: UIPanGestureRecognizer) -> CGFloat {
        guard let touchOrigin else { return gesture.translation(in: list).x }
        return gesture.location(in: list).x-touchOrigin.x
    }

    private func startPoint(_ gesture: UIPanGestureRecognizer) -> CGPoint {
        let point = gesture.location(in: list), delta = gesture.translation(in: list)
        return CGPoint(x: point.x-delta.x, y: point.y-delta.y)
    }

    @discardableResult func begin(_ cell: HistoryCell) -> Bool {
        guard isEnabled, !isActive, let index = list.indexPath(for: cell)?.item, let key = entry?(index) else { return false }
        self.cell = cell; self.key = key
        phase = .dragging; distance = 0; isArmed = false; attachment = Spring()
        companions = (-2...2).compactMap { offset in
            guard offset != 0, index+offset >= 0,
                  let neighbour = list.cellForItem(at: IndexPath(item: index+offset, section: 0)) as? HistoryCell else { return nil }
            return Companion(cell: neighbour, weight: abs(offset) == 1 ? 0.12 : 0.05)
        }
        feedback.prepare()
        holdFrameRate()
        return true
    }

    func move(to distance: CGFloat) {
        guard isActive, phase == .dragging else { return }
        let wasArmed = isArmed, previous = self.distance
        self.distance = distance
        // Four points of hysteresis prevent repeated taps at one stationary boundary.
        if isArmed, abs(distance) < threshold-4 || distance*previous < 0 { isArmed = false }
        if !isArmed, abs(distance) >= threshold { isArmed = true }
        if isArmed != wasArmed {
            // Change the live target without changing the displayed position in that frame.
            // The residual then springs away while further finger movement stays immediate.
            attachment.position = (cell?.swipeContent.transform.tx ?? 0)-trackingOffset
            if UIAccessibility.isReduceMotionEnabled { attachment = Spring() }
        }
        if isArmed && !wasArmed { feedback.impactOccurred(intensity: 0.65); feedback.prepare() }
        placeRow(at: trackingOffset+attachment.position)
    }

    func end(velocity: CGFloat, cancelled: Bool = false) {
        guard isActive, phase == .dragging else { return }
        let direction: CGFloat = distance < 0 ? -1 : 1
        let outwardSpeed = velocity*direction
        let flick = abs(distance) > 20 && outwardSpeed > 900 && abs(distance)+outwardSpeed*0.12 > threshold
        let crossed = isArmed && abs(distance) >= threshold && outwardSpeed > -350
        let deleting = !cancelled && (crossed || flick)
        let resistance = 1+abs(distance)/320
        let trackingSlope: CGFloat = isArmed ? 1 : 0.82/(resistance*resistance)
        let displayedVelocity = velocity*trackingSlope+attachment.velocity
        let displayedOffset = cell?.swipeContent.transform.tx ?? trackingOffset
        phase = deleting ? .leaving : .returning
        isArmed = false
        release = CACurrentMediaTime(); origin = displayedOffset
        releaseVelocity = min(5000, max(-5000, displayedVelocity))
        attachment = Spring()
        destination = deleting ? direction*(list.bounds.width+40) : 0
        if deleting, let key { commit?(key) }
        if UIAccessibility.isReduceMotionEnabled {
            if deleting { finishFlight() } else { cancel() }
        }
    }

    /// VoiceOver's action uses the same removal and gap animation as a committed swipe.
    @discardableResult func delete(_ cell: HistoryCell) -> Bool {
        guard begin(cell) else { return false }
        move(to: -threshold)
        end(velocity: -900)
        return true
    }

    func cancel() {
        generation += 1
        link?.invalidate(); link = nil
        for cell in [cell].compactMap({ $0 })+companions.map(\.cell) {
            cell.swipeContent.transform = .identity
            cell.swipeContent.alpha = 1
        }
        cell = nil; key = nil; companions = []; isArmed = false
        distance = 0; phase = .dragging; attachment = Spring()
    }

    func finishForScrolling() {
        if phase == .leaving { finishFlight() }
    }

    private func holdFrameRate() {
        let link = CADisplayLink(target: FrameTicker { [weak self] in self?.frame() }, selector: #selector(FrameTicker.tick))
        let maximum = Float(min(120, list.window?.screen.maximumFramesPerSecond ?? 120))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)
        lastFrame = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func frame() {
        let now = CACurrentMediaTime(), dt = min(1.0/30, max(0, now-lastFrame))
        lastFrame = now
        if phase == .dragging {
            attachment.step(to: 0, dt: dt)
            placeRow(at: trackingOffset+attachment.position)
        }
        if phase == .leaving || phase == .returning {
            let elapsed = now-release
            let spring = phase == .leaving ? SummariseSpring(22, 1) : SummariseSpring(24, 0.8)
            distance = spring.value(from: origin, to: destination, velocity: releaseVelocity, at: elapsed)
            placeRow(at: distance)
            if phase == .leaving, abs(distance) >= list.bounds.width+12 || elapsed > 0.45 { finishFlight() }
            else if phase == .returning, elapsed > 0.5 { cancel(); return }
        }
        for index in companions.indices {
            let target = phase == .dragging && !isArmed ? distance*companions[index].weight : 0
            companions[index].spring.step(to: target, dt: dt)
            let offset = UIAccessibility.isReduceMotionEnabled ? 0 : companions[index].spring.position
            companions[index].cell.swipeContent.transform = CGAffineTransform(translationX: offset, y: 0)
        }
    }

    private func placeRow(at offset: CGFloat) {
        cell?.swipeContent.transform = CGAffineTransform(translationX: offset, y: 0)
        cell?.swipeContent.alpha = max(0.12, 1-0.85*abs(offset)/max(1, list.bounds.width))
    }

    private func finishFlight() {
        guard phase == .leaving, let key else { return }
        phase = .collapsing
        for companion in companions { companion.cell.swipeContent.transform = .identity }
        companions = []
        let current = generation
        remove?(key) { [weak self] in
            guard let self, generation == current else { return }
            cancel()
        }
    }

    isolated deinit { link?.invalidate() }
}
