import Foundation
import CoreGraphics

/// Port of the cloth demo's single clock. No implicit CA animation is allowed
/// to interpolate these samples a second time or retain a residual bend.
struct ClothMotion {
    static let settlingDuration = 0.55
    static let rippleDuration = 0.30
    static let resistance = 160.0
    private var releasedAt: TimeInterval?
    private var releasedPull = 0.0
    private(set) var ripples = false
    private(set) var strength = 0.0
    private(set) var originFraction = 0.0

    static func pull(distance: Double) -> Double {
        let distance = max(0, distance)
        return distance / (distance + resistance)
    }
    mutating func release(distance: Double, at time: TimeInterval, cancelled: Bool) {
        releasedPull = Self.pull(distance: distance)
        releasedAt = time
        ripples = !cancelled && releasedPull > 0
        strength = 0.4 + releasedPull * 0.6
        // Demo origin 14 * pull, multiplied by 3 for its 840-point sheet.
        originFraction = 0.05 * releasedPull
    }
    func elapsed(at time: TimeInterval) -> Double { max(0, time - (releasedAt ?? time)) }
    func pull(at time: TimeInterval, reduceMotion: Bool = false) -> Double {
        guard releasedAt != nil else { return 0 }
        let elapsed = elapsed(at: time)
        if reduceMotion { return releasedPull * pow(1 - min(elapsed / 0.16, 1), 3) }
        guard elapsed + 1e-9 < Self.settlingDuration else { return 0 }
        let decay = 19.0, frequency = sqrt(500.0 - decay * decay)
        return releasedPull * exp(-decay * elapsed) *
            (cos(frequency * elapsed) + decay / frequency * sin(frequency * elapsed))
    }

    /// Compress every row equally. The dragged edge and its corners move as
    /// one straight edge; displacement tapers linearly to the fixed far edge.
    static func outline(size: CGSize, pull: Double, forward: Bool, corner: CGFloat = 7, continuous: Bool = false) -> CGPath {
        let depth = size.width * 0.05 * pull
        let rect = CGRect(x: forward ? 0 : depth, y: 0, width: size.width-depth, height: size.height)
        return PageOutline.path(in: rect, radius: corner, continuous: continuous)
    }

    /// The outer backing and shadow compress with the active page. An interior
    /// split edge leaves the other pane's external frame unchanged.
    static func frameOutline(size: CGSize, sheet: CGRect, pull: Double, forward: Bool, corner: CGFloat = 7, continuous: Bool = false) -> CGPath? {
        guard forward ? abs(sheet.maxX-size.width) < 0.5 : abs(sheet.minX) < 0.5 else { return nil }
        let depth = sheet.width * 0.05 * pull
        let rect = CGRect(x: forward ? 0 : depth, y: 0, width: size.width-depth, height: size.height)
        return PageOutline.path(in: rect, radius: corner, continuous: continuous)
    }
}
