import SwiftUI
import UIKit

/// The ChatGPT app's send, measured frame by frame from a recording of two sends (30 fps),
/// fitted to under 0.5% error and checked against the second send. The question's text lifts off
/// the field and sweeps up into its bubble at the top of the screen: sideways on a quick spring
/// that is mostly done in the first 0.1 s, upwards on a slower one that settles in about half a
/// second. The two finishing at different times is what bends the path. The bubble and the text's
/// blue fade in around it on the way, at full size.
enum SendMotion {
    /// Stiffness 7225 and damping 357 (mass 1), leaving at 112 widths a second.
    static let across = SummariseSpring(85, 2.1, 112)
    /// Stiffness 441 and damping 48.3 (mass 1), from rest. The scroll that carries the question to
    /// the top of the screen uses it too, so on screen the text rises exactly on this curve.
    static let up = SummariseSpring(21, 1.15)
    /// The bubble's fill and the text's blue come in after this, over `surfaceDuration`, easing
    /// out (cubic): 0.21 of the way at 0.12 s, 0.72 at 0.18 s, all of it by 0.44 s.
    static let surfaceDelay = 0.09
    static let surfaceDuration = 0.35
    static let surfaceEasing = CubicEasing(0.33, 1, 0.68, 1)
    /// The copy hands over to the bubble once it's within this of its place, and the fade is done.
    static let settled = 0.25
    static let longest = 1.2
    /// The top of the text left in sight above a sent question, under the status bar.
    static let topGap = 12.0
    /// How many lines of what came before stay in sight above a sent question's bubble.
    static let contextLines = 4
}

/// A question asked under the summary, as in the ChatGPT app: blue text in a light blue bubble on
/// the right, measured from the recording (#E6F3FF; the text, #3B5576 there, with the colour the
/// video's compression takes out of thin strokes put back, at the same hue).
enum SendBubble {
    static let fill = UIColor(red: 230/255, green: 243/255, blue: 255/255, alpha: 1)
    static let ink = UIColor(red: 45/255, green: 91/255, blue: 159/255, alpha: 1)
    /// The band sweeping the text while it's being answered.
    static let shimmer = UIColor(red: 20/255, green: 52/255, blue: 108/255, alpha: 1)
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 14
    static let radius: CGFloat = 20
    /// From the screen's right edge, a little further out than the paragraphs' 24.
    static let edgeInset: CGFloat = 16
    /// The widest a bubble gets, as a share of the screen's width.
    static let widthShare: CGFloat = 0.72

    @MainActor static func text(_ question: String) -> some View {
        Text(question)
            .font(Font(SummaryBlocks.font))
            .lineSpacing(SummaryBlocks.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func maxTextWidth(screen width: CGFloat) -> CGFloat {
        min(width*widthShare, width-2*edgeInset)-2*horizontalPadding
    }

    /// The question's text drawn once in white, for the flying copy's mask, and its size, which the
    /// bubble lays its text out in too so the two match exactly.
    @MainActor static func render(_ question: String, screen width: CGFloat, scale: CGFloat) -> (image: CGImage?, size: CGSize) {
        let renderer = ImageRenderer(content: text(question).foregroundStyle(.white))
        renderer.proposedSize = ProposedViewSize(width: maxTextWidth(screen: width), height: nil)
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            return (nil, CGSize(width: maxTextWidth(screen: width), height: SummaryBlocks.font.lineHeight))
        }
        return (image, CGSize(width: CGFloat(image.width)/scale, height: CGFloat(image.height)/scale))
    }

    static func size(text: CGSize) -> CGSize {
        CGSize(width: text.width+2*horizontalPadding, height: text.height+2*verticalPadding)
    }
}

/// The question's text on its way from the field to its bubble, in the summary's content, with the
/// summary scrolling the bubble to the top of the screen on the upward spring. As a pure function
/// of time, for keyframes and tests.
struct SendFlight {
    typealias M = SendMotion
    /// The text's first line's top left in the field, and in the bubble.
    let from: CGPoint, to: CGPoint
    let scrollFrom: Double, scrollTo: Double
    /// When it's settled enough to hand over to the bubble.
    let duration: Double

    init(from: CGPoint, to: CGPoint, scrollFrom: Double, scrollTo: Double) {
        self.from = from; self.to = to; self.scrollFrom = scrollFrom; self.scrollTo = scrollTo
        let across = abs(Double(to.x-from.x)), up = max(abs(Double(to.y-from.y)), abs(scrollTo-scrollFrom))
        var t = M.surfaceDelay+M.surfaceDuration
        while t < M.longest, abs(1-M.across(t))*across > M.settled || abs(1-M.up(t))*up > M.settled { t += 1/240 }
        duration = t
    }

    func textOrigin(at t: Double) -> CGPoint {
        CGPoint(x: from.x+(to.x-from.x)*M.across(t), y: from.y+(to.y-from.y)*M.up(t))
    }

    func scroll(at t: Double) -> Double { scrollFrom+(scrollTo-scrollFrom)*M.up(t) }

    /// The bubble's fill and the text's blue, from 0 to 1.
    func surface(at t: Double) -> Double { M.surfaceEasing((t-M.surfaceDelay)/M.surfaceDuration) }

    /// The text where it shows, against the screen.
    func onScreen(at t: Double) -> CGPoint {
        let origin = textOrigin(at: t)
        return CGPoint(x: origin.x, y: origin.y-scroll(at: t))
    }

    /// Times to sample at, 120 a second, ending exactly at `duration`.
    var keyTimes: [Double] {
        let count = Int((duration*120).rounded(.up))
        return (0...count).map { min(duration, Double($0)/120) }
    }
}

/// The question's flying copy: the bubble's fill and the text, the text a mask over a colour that
/// goes from the field's ink to the bubble's blue. It flies on Core Animation keyframes, with the
/// summary's scroll, so it keeps moving while the keyboard goes, which holds up the main thread.
final class SendGhost {
    let layer = CALayer()
    private let fill = CALayer()
    private let text = CALayer()

    init(mask image: CGImage?, textSize: CGSize, scale: CGFloat) {
        let size = SendBubble.size(text: textSize)
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.anchorPoint = .zero
        // Over the summary and the field, under the card.
        layer.zPosition = 1000
        fill.frame = layer.bounds
        fill.backgroundColor = SendBubble.fill.cgColor
        fill.cornerRadius = SendBubble.radius
        fill.cornerCurve = .continuous
        text.frame = CGRect(x: SendBubble.horizontalPadding, y: SendBubble.verticalPadding, width: textSize.width, height: textSize.height)
        text.backgroundColor = SendBubble.ink.cgColor
        let mask = CALayer()
        mask.frame = text.bounds
        mask.contents = image
        mask.contentsScale = scale
        text.mask = mask
        layer.addSublayer(fill)
        layer.addSublayer(text)
    }

    /// Starts the flight now, from `startInk`, scrolling `scroll` with it. Model values are left at
    /// the end, so the flight's last frame and what's left after it match. `onScreen`, the copy is
    /// placed against the screen rather than in the scrolling content, where it lands all the same.
    func fly(_ flight: SendFlight, startInk: UIColor, scroll: CALayer, onScreen: Bool = false) {
        let times = flight.keyTimes, begin = CACurrentMediaTime()
        let keyTimes = times.map { NSNumber(value: $0/flight.duration) }
        let inset = CGPoint(x: SendBubble.horizontalPadding, y: SendBubble.verticalPadding)
        func origin(_ t: Double) -> CGPoint {
            let text = onScreen ? flight.onScreen(at: t) : flight.textOrigin(at: t)
            return CGPoint(x: text.x-inset.x, y: text.y-inset.y)
        }
        let blend = { (t: Double) -> CGColor in
            let k = CGFloat(flight.surface(at: t))
            var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), b = a
            startInk.getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
            SendBubble.ink.getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
            return UIColor(red: a.0+(b.0-a.0)*k, green: a.1+(b.1-a.1)*k, blue: a.2+(b.2-a.2)*k, alpha: a.3+(b.3-a.3)*k).cgColor
        }
        let bounds = scroll.bounds
        let animations: [(CALayer, String, [Any])] = [
            (layer, "position", times.map { NSValue(cgPoint: origin($0)) }),
            (fill, "opacity", times.map { flight.surface(at: $0) }),
            (text, "backgroundColor", times.map(blend)),
            (scroll, "bounds", times.map { NSValue(cgRect: CGRect(origin: CGPoint(x: bounds.minX, y: flight.scroll(at: $0)), size: bounds.size)) }),
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = origin(flight.duration)
        fill.opacity = 1
        text.backgroundColor = SendBubble.ink.cgColor
        for (target, key, values) in animations {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.duration = flight.duration
            animation.beginTime = begin
            animation.fillMode = .backwards
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            target.add(animation, forKey: "send.\(key)")
        }
        CATransaction.commit()
    }
}
