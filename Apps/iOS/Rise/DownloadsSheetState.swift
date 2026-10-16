import UIKit

/// Only these two resting heights exist. Dragging follows the finger between them,
/// and stops at either endpoint without stretching or dismissing Downloads.
struct DownloadsSheetState {
    enum Detent { case compact, expanded }
    struct Heights {
        let compact: CGFloat, expanded: CGFloat
        func clamp(_ height: CGFloat) -> CGFloat { min(expanded, max(compact, height)) }
        func height(for detent: Detent) -> CGFloat { detent == .compact ? compact : expanded }
    }
    private(set) var detent = Detent.compact
    private var startHeight: CGFloat?
    private var draggedHeight: CGFloat?
    var isDragging: Bool { startHeight != nil }

    func height(in heights: Heights) -> CGFloat { heights.clamp(draggedHeight ?? heights.height(for: detent)) }
    mutating func reset() { detent = .compact; startHeight = nil; draggedHeight = nil }
    mutating func begin(at height: CGFloat, in heights: Heights) {
        startHeight = heights.clamp(height)
        draggedHeight = startHeight
    }
    mutating func drag(by translation: CGFloat, in heights: Heights) {
        draggedHeight = heights.clamp((startHeight ?? heights.height(for: detent))-translation)
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
