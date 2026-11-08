import Foundation

// Adapted from testing-trackpad-back-haptics/BackSwipeState.swift. The selected
// demo mode is threshold-only: one click at 120 pt, and navigation on release.
enum HistoryDirection { case back, forward
    var fingerSign: Double { self == .back ? 1 : -1 }
}
struct HistorySwipeState {
    private enum Axis { case undecided, horizontal, rejected }
    static let threshold = 120.0
    private(set) var isTracking = false
    private(set) var isArmed = false
    private(set) var distance = 0.0
    private(set) var direction: HistoryDirection?
    private var axis = Axis.undecided
    private var totalX = 0.0, totalY = 0.0
    /// Fingers moving up or down, once a held swipe shows its list, scroll it a row for each this
    /// many points, as a page scrolls: with natural scrolling, down brings the row above.
    static let listStep = 15.0
    /// A row's change waits until the fingers are this much of a step past its edge, so a hand
    /// resting on an edge doesn't flick between two rows.
    static let listHysteresis = 0.25
    /// Where the swipe was when its list came up, and how many pages it holds.
    private(set) var listBase: Double?
    private(set) var listCount = 0
    /// The fingers' travel along the list, in points towards further pages, since it opened.
    private var listTravel = 0.0
    /// The page picked in the list, 0 being the nearest.
    private(set) var selection = 0
    /// How many pages a release now goes.
    var steps: Int { listBase == nil ? 1 : selection+1 }
    mutating func openList(count: Int) { listBase = distance; listCount = count; listTravel = 0; selection = 0 }
    mutating func closeList() { listBase = nil; listCount = 0; listTravel = 0; selection = 0 }
    /// `scroll` is the event's own vertical scroll, the way content would move: positive moves
    /// the list down, bringing the row above to the circle's place. Back lists the furthest page
    /// at the top, so that goes further; Forward lists it at the bottom, so that comes nearer.
    /// Travel past either end isn't kept: turning back answers at once.
    private mutating func moveAlongList(scroll: Double) {
        guard listBase != nil, listCount > 1 else { return }
        listTravel += direction == .back ? scroll : -scroll
        // Each row holds the fingers within half a step of it, and a little past that. Past the
        // end rows, travel stops at their middles, so turning back takes no more than elsewhere.
        let reach = 0.5 + Self.listHysteresis
        listTravel = min(max(listTravel, 0), Double(listCount-1)*Self.listStep)
        let rows = listTravel/Self.listStep
        while selection < listCount-1, rows >= Double(selection) + reach { selection += 1 }
        while selection > 0, rows <= Double(selection) - reach { selection -= 1 }
    }
    var consumesScroll: Bool { isTracking && axis == .horizontal }
    var arrowPull: Double {
        let normalized = distance / Self.threshold
        return normalized <= 1 ? normalized : 1.5 - 0.25 / (normalized - 1 + 0.5)
    }
    mutating func begin() { self = Self(); isTracking = true }
    /// Direction stays locked; returning below the threshold disarms navigation.
    /// Each crossing into it clicks, as the circle pops each time it arms. `dy` is the event's
    /// vertical scroll, which, with a list showing, scrolls through it.
    mutating func move(dx: Double, dy: Double, canBack: Bool, canForward: Bool) -> Bool {
        guard isTracking, axis != .rejected else { return false }
        totalX += dx; totalY += dy
        moveAlongList(scroll: dy)
        if axis == .undecided {
            guard max(abs(totalX), abs(totalY)) >= 6 else { return false }
            guard abs(totalX) > abs(totalY) * 1.2,
                  totalX > 0 ? canBack : canForward else { axis = .rejected; return false }
            axis = .horizontal; direction = totalX > 0 ? .back : .forward
            distance = abs(totalX)
        } else { distance = max(0, totalX * (direction?.fingerSign ?? 1)) }
        let wasArmed = isArmed
        isArmed = distance >= Self.threshold
        return isArmed && !wasArmed
    }
    mutating func finish(cancelled: Bool = false) -> HistoryDirection? {
        let result = isTracking && isArmed && !cancelled ? direction : nil
        self = Self(); return result
    }
}
