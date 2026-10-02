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
    private var didClick = false
    var consumesScroll: Bool { isTracking && axis == .horizontal }
    var arrowPull: Double {
        let normalized = distance / Self.threshold
        return normalized <= 1 ? normalized : 1.5 - 0.25 / (normalized - 1 + 0.5)
    }
    mutating func begin() { self = Self(); isTracking = true }
    /// Direction stays locked; returning below the threshold disarms navigation.
    /// The haptic remains limited to the first crossing in each gesture.
    mutating func move(dx: Double, dy: Double, canBack: Bool, canForward: Bool) -> Bool {
        guard isTracking, axis != .rejected else { return false }
        totalX += dx; totalY += dy
        if axis == .undecided {
            guard max(abs(totalX), abs(totalY)) >= 6 else { return false }
            guard abs(totalX) > abs(totalY) * 1.2,
                  totalX > 0 ? canBack : canForward else { axis = .rejected; return false }
            axis = .horizontal; direction = totalX > 0 ? .back : .forward
            distance = abs(totalX)
        } else { distance = max(0, totalX * (direction?.fingerSign ?? 1)) }
        isArmed = distance >= Self.threshold
        if isArmed, !didClick { didClick = true; return true }
        return false
    }
    mutating func finish(cancelled: Bool = false) -> HistoryDirection? {
        let result = isTracking && isArmed && !cancelled ? direction : nil
        self = Self(); return result
    }
}
