import Foundation
import CoreGraphics

/// The browser loading hairline's geometry and motion, shared by desktop and iOS.
public enum PageLoadProgress {
    public struct Style {
        public var thickness: CGFloat, frontThickness: CGFloat, taper: CGFloat, glow: CGFloat
        public var glowOpacity: Float
        public init(thickness: CGFloat = 0.5, frontThickness: CGFloat = 1, taper: CGFloat = 140,
                    glow: CGFloat = 1.5, glowOpacity: Float = 0.6) {
            self.thickness = thickness; self.frontThickness = frontThickness; self.taper = taper
            self.glow = glow; self.glowOpacity = glowOpacity
        }
    }
    public static let color: UInt32 = 0x007AFF, hardReloadColor: UInt32 = 0xF03C64
    public static let overrun: CGFloat = 48, stiffness: CGFloat = 11
    public static let fadeDuration = 0.35
    public static func target(_ value: Double) -> CGFloat { min(0.97, max(0.07, CGFloat(value))) }
    public static func step(front: CGFloat, target: CGFloat, speed: CGFloat, dt: CGFloat) -> (front: CGFloat, speed: CGFloat) {
        let offset = front-target, decay = exp(-stiffness*dt)
        let carried = speed+stiffness*offset
        let next = target+(offset+carried*dt)*decay
        return next >= target ? (target, 0) : (next, (speed-stiffness*carried*dt)*decay)
    }
    public static func path(front: CGFloat, centre: CGFloat, style: Style = Style()) -> CGPath {
        let path = CGMutablePath(), thin = style.thickness/2
        let thick = max(thin, style.frontThickness/2), capX = max(thick, front-thick)
        let taperStart = max(0, capX-style.taper)
        path.move(to: CGPoint(x: 0, y: centre-thin))
        path.addLine(to: CGPoint(x: taperStart, y: centre-thin))
        let middle = (taperStart+capX)/2
        path.addCurve(to: CGPoint(x: capX, y: centre-thick), control1: CGPoint(x: middle, y: centre-thin), control2: CGPoint(x: middle, y: centre-thick))
        path.addArc(center: CGPoint(x: capX, y: centre), radius: thick, startAngle: -.pi/2, endAngle: .pi/2, clockwise: false)
        path.addCurve(to: CGPoint(x: taperStart, y: centre+thin), control1: CGPoint(x: middle, y: centre+thick), control2: CGPoint(x: middle, y: centre+thin))
        path.addLine(to: CGPoint(x: 0, y: centre+thin))
        path.closeSubpath()
        return path
    }
}
