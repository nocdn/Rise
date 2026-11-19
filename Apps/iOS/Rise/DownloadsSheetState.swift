import UIKit

/// Only these two resting heights exist. Dragging follows the finger between them, stretches
/// with resistance past the tall one, as the other panels do against an upward pull, and stops
/// at the short one without dismissing Downloads.
struct DownloadsSheetState {
    enum Detent { case compact, expanded }
    struct Heights {
        let compact: CGFloat, expanded: CGFloat
        func clamp(_ height: CGFloat) -> CGFloat { min(expanded, max(compact, height)) }
        func height(for detent: Detent) -> CGFloat { detent == .compact ? compact : expanded }
    }
    private(set) var detent = Detent.compact
    private var startHeight: CGFloat?
    /// Where the finger would have the sheet, before any stretch past the tall height.
    private var draggedHeight: CGFloat?
    var isDragging: Bool { startHeight != nil }

    /// How far the sheet gives for a pull `beyond` the tall height: the panels' own stretch.
    static func stretch(_ beyond: CGFloat) -> CGFloat { 40*(1-1/(1+max(0, beyond)/160)) }
    /// The pull that gives `stretched`, for catching the sheet as it springs back.
    static func pull(for stretched: CGFloat) -> CGFloat { 160*(1/(1-min(39.9, max(0, stretched))/40)-1) }

    func height(in heights: Heights) -> CGFloat {
        guard let draggedHeight else { return heights.height(for: detent) }
        if draggedHeight > heights.expanded { return heights.expanded+Self.stretch(draggedHeight-heights.expanded) }
        return heights.clamp(draggedHeight)
    }
    mutating func reset() { detent = .compact; startHeight = nil; draggedHeight = nil }
    mutating func begin(at height: CGFloat, in heights: Heights) {
        startHeight = height > heights.expanded ? heights.expanded+Self.pull(for: height-heights.expanded) : heights.clamp(height)
        draggedHeight = startHeight
    }
    mutating func drag(by translation: CGFloat, in heights: Heights) {
        draggedHeight = max(heights.compact, (startHeight ?? heights.height(for: detent))-translation)
    }
    mutating func finish(velocity: CGFloat, cancelled: Bool, in heights: Heights) {
        if !cancelled {
            let projected = height(in: heights)-velocity*0.16
            if abs(velocity) > 450 { detent = velocity < 0 ? .expanded : .compact }
            else { detent = projected > (heights.compact+heights.expanded)/2 ? .expanded : .compact }
        }
        startHeight = nil; draggedHeight = nil
    }
}
