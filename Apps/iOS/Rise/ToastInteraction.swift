import UIKit

/// Snap's preview-style resistance and velocity-preserving spring flight, sampled
/// once on release. Finger tracking only writes a transform; flight runs in CA.
enum ToastInteraction {
    static let rubberBandLength: CGFloat = 22
    static let resistance: CGFloat = 0.42
    static let flightClearance: CGFloat = 34
    static let projectionTime: CGFloat = 0.22
    static let maximumVelocity: CGFloat = 5_000
    static let dampingRatio: CGFloat = 0.90

    struct Flight {
        var points: [CGPoint]
        var duration: Double
    }

    static func resisted(_ value: CGFloat) -> CGFloat {
        let scaled = value*resistance
        return scaled/(1+abs(scaled)/rubberBandLength)
    }
    static func tracked(_ translation: CGPoint) -> CGPoint {
        CGPoint(x: resisted(translation.x),y: translation.y < 0 ? resisted(translation.y) : translation.y)
    }
    static func untracked(_ point: CGPoint) -> CGPoint {
        func inverse(_ v: CGFloat) -> CGFloat { v/(resistance*max(0.01,1-abs(v)/rubberBandLength)) }
        return CGPoint(x: inverse(point.x),y: point.y < 0 ? inverse(point.y) : point.y)
    }
    static func releaseVelocity(_ velocity: CGPoint,at translation: CGPoint) -> CGPoint {
        let scale = min(1,maximumVelocity/max(1,hypot(velocity.x,velocity.y)))
        let dx = resistance/pow(1+abs(translation.x)*resistance/rubberBandLength,2)
        let dy = translation.y < 0 ? resistance/pow(1+abs(translation.y)*resistance/rubberBandLength,2) : 1
        return CGPoint(x: velocity.x*scale*dx,y: velocity.y*scale*dy)
    }
    static func dismissalScale(at offset: CGFloat,travel: CGFloat) -> CGFloat {
        1-0.1*min(1,max(0,offset)/max(1,travel))
    }
    static func shouldDismiss(offset: CGPoint,velocity: CGPoint,intendedVelocity: CGPoint? = nil) -> Bool {
        let direction = intendedVelocity ?? velocity
        return offset.y >= 0 && velocity.y >= -80 && offset.y+velocity.y*projectionTime > 30
            && (offset.y > 30 || direction.y > abs(direction.x)*0.5)
    }
    static func flight(from: CGPoint,velocity: CGPoint,exitY: CGFloat) -> Flight {
        // Aim beyond the visible edge, as Snap does, so a hard flick keeps its
        // velocity instead of braking towards a nearby off-screen resting point.
        let target = CGPoint(x: from.x+velocity.x*projectionTime,
                             y: max(exitY,from.y)+flightClearance+max(0,velocity.y)*projectionTime)
        var points = [from]
        for frame in 1...240 {
            let t = Double(frame)/120
            let point = CGPoint(x: spring(from: from.x,to: target.x,velocity: velocity.x,stiffness: 280,time: t),
                                y: spring(from: from.y,to: target.y,velocity: max(0,velocity.y),stiffness: 280,time: t))
            points.append(point)
            if point.y >= exitY { break }
        }
        return Flight(points: points,duration: Double(points.count-1)/120)
    }
    static func spring(from: CGFloat,to: CGFloat,velocity: CGFloat,stiffness: CGFloat,time: Double) -> CGFloat {
        let omega = sqrt(stiffness), decay = dampingRatio*omega, damped = omega*sqrt(1-dampingRatio*dampingRatio)
        let a = from-to, b = (velocity+decay*a)/damped, t = CGFloat(time)
        return to+exp(-decay*t)*(a*cos(damped*t)+b*sin(damped*t))
    }
}
