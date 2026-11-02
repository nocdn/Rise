import AppKit

/// One day per finger gesture. Vertical scrolling stays native; inertial tails
/// never skip through more days after the fingers leave the trackpad.
struct CalendarDaySwipe {
    private enum Axis { case undecided, horizontal, vertical }
    static let threshold: CGFloat = 50
    private var axis = Axis.undecided
    private var x: CGFloat = 0, y: CGFloat = 0
    private var committed = false
    private var lastInput: TimeInterval?

    mutating func handle(_ event: NSEvent) -> (consumed: Bool, day: Int?) {
        let fingerX = event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
        return handle(dx: fingerX, dy: event.scrollingDeltaY, phase: event.phase, momentum: event.momentumPhase,
                      precise: event.hasPreciseScrollingDeltas, timestamp: event.timestamp)
    }
    mutating func handle(dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase = [],
                         precise: Bool = true, timestamp: TimeInterval) -> (consumed: Bool, day: Int?) {
        guard precise else { return (false, nil) }
        if !momentum.isEmpty {
            let consumed = axis == .horizontal
            if momentum.contains(.ended) || momentum.contains(.cancelled) { self = Self() }
            return (consumed, nil)
        }
        if phase.contains(.began) || phase.contains(.mayBegin) || phase.isEmpty && lastInput.map({ timestamp-$0 > 0.3 }) == true { self = Self() }
        lastInput = timestamp
        if phase.contains(.cancelled) {
            let consumed = axis == .horizontal; self = Self(); return (consumed, nil)
        }
        if phase.contains(.ended) { return (axis == .horizontal, nil) }
        x += dx; y += dy
        if axis == .undecided, max(abs(x), abs(y)) >= 6 {
            if abs(x) > abs(y)*1.2 { axis = .horizontal }
            else if abs(y) > abs(x)*1.2 { axis = .vertical }
        }
        guard axis == .horizontal else { return (false, nil) }
        guard !committed, abs(x) >= Self.threshold else { return (true, nil) }
        committed = true
        return (true, x < 0 ? 1 : -1)
    }
}
