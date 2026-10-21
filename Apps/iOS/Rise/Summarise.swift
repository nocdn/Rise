import CoreHaptics
import CoreImage
import SwiftUI
import UIKit

/// Arc Search's Summarise, timed from a recording of it frame by frame and tuned in
/// `Playgrounds/summarise.html`, whose dials these are, except where noted: the app has since
/// dropped the playground's fold for a pinch that follows the fingers. Lengths are in points on a 393-point-wide
/// iPhone and times in seconds. Springs are (ω, ζ, v₀), as there: angular frequency in rad/s,
/// damping ratio, and starting velocity in whole distances per second.
enum SummariseMotion {
    // The pinch, as Safari's into its tabs: the page follows the fingers, at their scale, the spot
    // pinched staying under them, and crops, rounds and tips towards the card as it shrinks. Let
    // go, it flies to the card on `release`, starting at the speed it was going in scale and
    // position, so a hard pinch shoots smaller than the card and springs back up to it.
    /// The page gives past these as the fingers carry on.
    static let pinchMinScale = 0.3
    static let pinchMaxScale = 1.06
    /// How the crop, corners and tilt follow the scale: their share of the way is the scale's
    /// share of the way to the card's, raised to this power, so they come in gently.
    static let pinchEasing = 1.3
    /// The page's corners round to this (unscaled) within the first `pinchRounding` of the way,
    /// then ease down to the card's.
    static let pinchRadius = 40.0
    static let pinchRounding = 0.05
    /// Let go smaller than this, or shrinking faster than `commitSpeed` (scale per second), it
    /// summarises; otherwise it springs back.
    static let commitScale = 0.85
    static let commitSpeed = 0.6
    /// The fastest the release carries on, in scale and in points per second.
    static let maxScaleSpeed = 5.0
    static let maxMoveSpeed = 4000.0
    /// How far back the fingers' speed is measured from when they let go: short enough to catch a
    /// flick at its quickest, which the page carries on with for a moment before it turns.
    static let velocityWindow = 0.06
    /// Its size settles with a little bounce, soft enough that a hard pinch carries it well past the
    /// card's before it comes back. It moves to its place more gently, in about half a second from
    /// across the screen, so it curves round to it from wherever it was going rather than snapping.
    /// The crop, corners and tilt settle on `placeCrop`, and a pinch let go short springs back on `cancel`.
    static let releaseScale = SummariseSpring(11, 0.8)
    static let releaseMove = SummariseSpring(9, 0.9)
    static let placeCrop = SummariseSpring(20, 0.9)
    static let cancel = SummariseSpring(2*Double.pi/0.36, 1)
    /// The model is asked once the card has about landed, so reading the page doesn't hold up its flight.
    static let requestDelay = 0.35
    static let perspective = 2000.0

    // The card: its width as a share of the screen's, and its top.
    static let loadScale = 0.526
    static let loadTop = 149.0
    static let revealScale = 0.659
    static let revealTop = 134.0
    static let cardAspect = 0.975
    /// The card shows the page from this far down.
    static let cropTop = 47.0
    static let cardRadius = 15.0
    /// Negative tips the top towards you.
    static let restTilt = -6.0
    static let shadow = 0.16
    static let backPeek = 12.0
    static let backInset = 6.0

    // From Summarise in More, and after a pinch, the whole page shrinks straight into the card.
    // A pinch replaces their starting velocities with the fingers'.
    static let menuShrink = SummariseSpring(9.5, 0.95, 7)
    static let menuCrop = SummariseSpring(24.5, 0.9)

    // The swing while the model works. The reveal waits for it to pass the middle.
    static let swingPeriod = 2.04
    static let swingTilt = 2.1
    static let swingX = 6.7
    static let swingY = 2.0
    static let syncTolerance = 0.12

    // The card peeking out behind fades in this long after the card starts to settle.
    static let backDelay = 0.38
    static let backDuration = 0.2

    // The bottom bar eases out as it slides off, and springs back with a little bounce.
    static let barExit = 0.18
    static let barResponse = 0.27
    static let barBounce = 0.25

    // The reveal: the card grows a little as the summary's blocks fade in and sharpen in turn.
    static let reveal = SummariseSpring(13, 1, 1)
    static let textDelay = 0.12
    static let stagger = 0.08
    static let textBlur = 20.0
    static let blurTau = 0.15
    static let fadeTau = 0.12
    /// The summary's first paragraph below the card; 26 in the playground.
    static let textGap = 38.0

    // The backdrop's glows, circling each other until the reveal.
    static let orbitPeriod = 4.0
    static let glowBlur = 40.0
    static let coolGlowSize = 460.0
    static let warmGlowSize = 480.0
    static let settle = 1.8
    static let warmGlowFade = 1.1
    static let coolGlowRest = 0.25

    // Tapping the card grows it back into the page.
    static let close = SummariseSpring(9.5, 1, 11.5)
    static let contentsOut = 0.1
    static let closeRecede = 0.1

    // Caught by a pinch as it grows back: how quickly its crop, corners and tilt come to the
    // pinch's own for its size. Let go, the summary it had comes forward as a recalled one does.
    static let grabBlend = SummariseSpring(2*Double.pi/0.3, 1)

    // Summarised before, with the page unchanged, the card flies straight to where it shows the
    // summary, which comes forward as it fades in: the close's sinking back, the other way, on
    // its spring.
    static let recallFade = 0.15

    // The follow-up field is held at the bottom of the screen, just above the keyboard as it
    // opens, unfocused until touched, faded in after the summary's last paragraph. The summary
    // scrolls behind it and fades out just above it. A question sent from it flies up into a
    // bubble as in the ChatGPT app (`SendMotion`).
    static let followUpHeight = 48.0
    /// Under the field, to the keyboard.
    static let followUpBottomGap = 12.0
    /// With the keyboard down, the field is held this much higher again over the screen's bottom.
    static let followUpRestLift = 12.0
    /// Focused, the field moves over by this for a plus on its left, and leaves as much on its
    /// right for a microphone, both fading in as it goes, on Find's Ask spring.
    static let followUpAccessory = 36.0
    static let followUpRowSpring = (duration: 0.3, bounce: 0.25)
    /// Focusing, they wait this long before coming in, as the keyboard starts up; they go at once.
    static let followUpRowDelay = 0.08
    /// The plus's and microphone's size: ChatGPT's `plus-lg-light-20` and `microphone-light-20`,
    /// a little larger for 17 pt text, their lines alike (1.33 of 20, about 1.46 pt).
    static let accessoryIconSize = 22.0
    /// The summary fades out above the field over 140 pt, quickly and then a long faint tail,
    /// picked from fifteen side by side (`fades` in the replays). It ends `followUpFadeInto` into
    /// the field's empty top, just above its text.
    static let followUpFade = SummaryFade(height: 140, curve: .quick)
    static let followUpFadeInto = 10.0
}

/// How the summary fades out above the follow-up field: over `height`, along `curve`, then held
/// wholly gone over `hold` down to just above the field's text.
struct SummaryFade: Equatable {
    enum Curve { case linear, smooth, quick, late }
    var height: Double
    var hold = 0.0
    var curve = Curve.linear

    /// Scrolled to the end, the last line's bottom sits this far above the field's top: where the
    /// fade starts, so it isn't dimmed.
    var clearance: Double { height+hold-SummariseMotion.followUpFadeInto }

    /// The text's opacity through the fade, `at` 0 at its top to 1 at its bottom.
    var steps: [(at: Double, alpha: Double)] {
        let count = curve == .linear ? 1 : 12
        return (0...count).map { i in
            let u = Double(i)/Double(count)
            let alpha: Double = switch curve {
            case .linear: 1-u
            case .smooth: 1-u*u*(3-2*u)
            // Gone quickly, a long faint tail: more solid near the field.
            case .quick: (1-u)*(1-u)
            // Stays longer, then goes.
            case .late: 1-u*u
            }
            return (u, alpha)
        }
    }

    static func == (a: SummaryFade, b: SummaryFade) -> Bool { a.height == b.height && a.hold == b.hold && a.curve == b.curve }
}

/// A damped spring's progress from 0 towards 1 after t seconds.
struct SummariseSpring {
    let w: Double, z: Double, v0: Double
    init(_ w: Double, _ z: Double, _ v0: Double = 0) { self.w = w; self.z = z; self.v0 = v0 }

    /// Where something released at `from`, moving at `velocity` (per second), is after t seconds
    /// on its way to `to`. Unlike `v0`, the velocity is in the value's own units, so it holds
    /// however near the target it starts.
    func value(from: Double, to: Double, velocity: Double, at t: Double) -> Double {
        guard t > 0 else { return from }
        let d = from-to
        if z < 1 {
            let wd = w*(1-z*z).squareRoot()
            return to+exp(-z*w*t)*(d*cos(wd*t)+(velocity+z*w*d)/wd*sin(wd*t))
        }
        return to+exp(-w*t)*(d+(velocity+w*d)*t)
    }

    func callAsFunction(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let d: Double
        if z < 1 {
            let wd = w*(1-z*z).squareRoot(), b = (v0-z*w)/wd
            d = exp(-z*w*t)*(-cos(wd*t)+b*sin(wd*t))
        } else if z == 1 {
            d = exp(-w*t)*(-1+(v0-w)*t)
        } else {
            let r = (z*z-1).squareRoot(), r1 = -w*(z-r), r2 = -w*(z+r)
            // 1 + c1·e^(r1 t) + c2·e^(r2 t), starting at 0 with speed v0.
            let c2 = (v0+r1)/(r2-r1), c1 = -1-c2
            d = c1*exp(r1*t)+c2*exp(r2*t)
        }
        return 1+d
    }
}

private func clamp(_ x: Double, _ low: Double = 0, _ high: Double = 1) -> Double { min(high, max(low, x)) }
private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a+(b-a)*t }
/// Smooth ease-out: k = 0 is linear.
private func easeOut(_ x: Double, _ k: Double) -> Double { let x = clamp(x); return (1-k)*x+k*(1-(1-x)*(1-x)) }
private let degrees = Double.pi/180

/// A page's summary: two short paragraphs of plain text.
struct PageSummary: Equatable {
    let paragraphs: [String]

    static let systemPrompt = """
    You summarise web pages in Rise, a web browser, for someone deciding whether to read the page. The page's text is below.

    Reply with exactly two short paragraphs of plain text, separated by a blank line, that together cover all the important information on the page: what it is, its main point, and the key facts, figures, names and dates. Nothing else: no title, headings, bullet points, lists, labels or Markdown, and no text before or after the paragraphs.

    Write in the page's language.
    """

    static let followUpPrompt = """
    You answer follow-up questions in Rise, a web browser, about a web page you have just summarised for the user. The page's text is below.

    Answer from the page. Be short and direct: usually one short paragraph, at most two, with no preamble, and don't restate the question. If the page doesn't say, say so in one short sentence; only then add what you know, clearly marked as not from the page. Write plain text: no headings, bullet points, lists or Markdown. Write in the language of the question.
    """

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "The summary didn’t come back in a form Rise could read." }
    }

    private static func context(of page: PageAssistant.Page) -> String {
        var context = "Title: \(page.title)\nURL: \(page.url)\n\n<page>\n\(page.text)\n</page>"
        if page.text.isEmpty { context += "\n(The page has no readable text.)" }
        return context
    }

    /// Asks the shared model for the page's summary, all at once, as it's revealed all at once.
    @MainActor static func make(of page: PageAssistant.Page, provider: ModelChoice = .openRouter, session: URLSession = .shared) async throws -> PageSummary {
        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt+"\n\n"+context(of: page)],
            ["role": "user", "content": "Summarise this page."],
        ]
        return try decode(try await reply(to: messages, provider: provider, session: session))
    }

    /// Answers a question asked under the summary, after the ones before it, all at once.
    @MainActor static func answer(_ question: String, after summary: PageSummary, history: [PageAssistant.Turn],
                                  of page: PageAssistant.Page, provider: ModelChoice = .openRouter, session: URLSession = .shared) async throws -> [String] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": followUpPrompt+"\n\n"+context(of: page)],
            ["role": "user", "content": "Summarise this page."],
            ["role": "assistant", "content": summary.paragraphs.joined(separator: "\n\n")],
        ]
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": question])
        let paragraphs = paragraphs(in: try await reply(to: messages, provider: provider, session: session))
        guard !paragraphs.isEmpty else { throw Failure.unreadable }
        return paragraphs
    }

    @MainActor private static func reply(to messages: [[String: Any]], provider: ModelChoice, session: URLSession) async throws -> String {
        var reply = ""
        try await ModelService.run(messages, provider: provider, session: session) { event in
            if case .text(let text) = event { reply += text }
        }
        try Task.checkCancellation()
        return reply
    }

    /// The reply's paragraphs, without any Markdown emphasis or code fences that slipped in.
    static func paragraphs(in reply: String) -> [String] {
        reply.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "```", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func decode(_ reply: String) throws -> PageSummary {
        let paragraphs = paragraphs(in: reply)
        guard !paragraphs.isEmpty else { throw Failure.unreadable }
        return PageSummary(paragraphs: paragraphs)
    }

    /// Shown in place of a summary, revealed the same way.
    static func failure(_ error: Error) -> PageSummary {
        PageSummary(paragraphs: ["Rise couldn’t summarise this page. \(error.localizedDescription)"])
    }
}

/// The page shrunk into a card over a glowing backdrop while the model reads it, then the summary
/// revealed under it, all of it scrolling together. Tapping the card grows it back into the page.
/// Pinching the page in shrinks it into the card with the fingers; Summarise in More does it on
/// its own. It sits under the bottom bar, which drops away as the page goes and springs back as the
/// card grows back into the page.
///
/// It runs on its own clock and renders every frame from the playground's model, so the motion
/// is the playground's exactly.
final class SummariseView: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate, UITextFieldDelegate {
    private typealias M = SummariseMotion
    enum Path { case pinch, menu }
    private enum Mode { case pinch, cancel, card, closing, done }
    private enum Key { case cropTop, cropH, radius, scale, x, top, rotation }
    private struct Tween {
        /// `release` carries on from a velocity in the value's own units per second.
        enum Curve { case none, spring(SummariseSpring), release(SummariseSpring, velocity: Double) }
        let from: Double, to: Double, t0: Double, curve: Curve
        func value(at t: Double) -> Double {
            switch curve {
            case .none: return to
            case .spring(let spring): return lerp(from, to, spring(t-t0))
            case .release(let spring, let velocity): return spring.value(from: from, to: to, velocity: velocity, at: t-t0)
            }
        }
    }

    /// Fetches the page's summary, from when it's committed to.
    var makeSummary: (@MainActor () async throws -> PageSummary)?
    /// The page's summary from before, if it hasn't changed since: shown at once, without asking.
    var memorised: PageSummary?
    /// A summary that came back, to remember for the page.
    var onSummary: ((PageSummary) -> Void)?
    /// Answers a question asked under the summary, after the ones before it.
    var answerFollowUp: (@MainActor (_ question: String, _ summary: PageSummary, _ history: [PageAssistant.Turn]) async throws -> [String])?
    /// New Page's voice input: holding the field's microphone dictates into it the same way.
    var voice: VoiceInput?
    /// Focused, the field has a plus on its left (it does nothing yet) and a microphone on its
    /// right. Each sits in its own slot, so their swaps don't cut each other short.
    private let plusSlot = UIView(), micSlot = UIView()
    private let plusButton = UIButton(type: .custom)
    /// ChatGPT's own plus, from the same icons as the microphone (`plus-lg-light-20`).
    private let plusGlyph = UIImageView(image: UIImage(named: "Plus"))
    private let micButton = UIButton(type: .custom)
    /// ChatGPT's own microphone, from its web app's icons (`microphone-light-20`).
    private let micGlyph = UIImageView(image: UIImage(named: "Microphone"))
    private let micWave = VoiceWaveform()
    private lazy var micHold = UILongPressGestureRecognizer(target: self, action: #selector(holdMicrophone))
    private var followUpEditing = false
    /// Whether the row shows the plus and microphone, a moment behind `followUpEditing` coming in.
    private var followUpRowOpen = false
    private var followUpRowOpening: DispatchWorkItem?
    private let accessoryTap = UIImpactFeedbackGenerator(style: .rigid)
    private var dictating: Task<Void, Never>?
    /// Where the bottom bar should be: 0 in place and 1 off the bottom of the screen.
    var onBar: ((CGFloat) -> Void)?
    /// The status bar is over the page, or over the backdrop.
    var onStatusBar: (() -> Void)?
    /// Done, and the page shows again: once the card has grown back, or a pinch was let go short.
    var onFinish: (() -> Void)?
    /// Notes how it runs, frame by frame, for looking at a choppy one afterwards.
    var log: SummariseLog?
    /// What the page underneath is up to, noted as the card grows back into it.
    var describePage: (() -> String)?
    private(set) var isOverPage = true
    var isRevealed: Bool { revealT != nil }
    /// Set, the scene runs on this clock, in seconds, instead of the display's; tests step it.
    var manualTime: CFTimeInterval? {
        didSet { if oldValue == nil, let manualTime { clock0 = manualTime; now = 0 } }
    }

    /// A replica of the page as it was.
    private let pageReplica: UIView
    private let size: CGSize
    private let reducesMotion = UIAccessibility.isReduceMotionEnabled

    private var mode = Mode.pinch
    private var path = Path.pinch
    private var clock0 = CACurrentMediaTime()
    private var now = 0.0
    private var link: CADisplayLink?
    private lazy var ticker = FrameTicker { [weak self] in self?.nextFrame() }

    /// The point on the page the fingers started on, which stays under them.
    private var anchor = CGPoint.zero
    /// Where the page has been as the fingers moved it: its scale, its middle's offset from the
    /// screen's, and its top.
    private var pinchHistory: [(t: Double, scale: Double, x: Double, top: Double)] = []
    /// Caught as it grew back: the scale it had, which the fingers' own scales, and how far its crop,
    /// corners and tilt were from the pinch's, which fades.
    private var grabScale = 1.0
    private var grabOffsets: (t: Double, cropTop: Double, cropH: Double, radius: Double, tilt: Double)?
    private var fingers: (scale: Double, centroid: CGPoint) = (1, .zero)
    private var t0 = 0.0
    private var tweens: [Key: Tween] = [:]
    private var swingT0: Double?, swingDirection = 1.0
    private var readyT = Double.infinity, revealT: Double?, pendingReveal: Double?, closeT: Double?
    /// When a summary already known started coming forward, rather than being revealed.
    private var recallT: Double?
    private var orbitT0: Double?, orbitStop: (t0: Double, a0: Double, a1: Double)?
    private var bar: (hide: Bool, t0: Double, from: Double)?
    private var closeScroll = 0.0
    private var task: Task<Void, Never>?
    private var summaryFailed = false
    private var haptics: CHHapticEngine?
    private var hum: CHHapticAdvancedPatternPlayer?
    private var hapticsReady = false, wantsHum = false, preparingHaptics = false
    /// Core Haptics supports worker queues. Playback stays on MainActor; a worker only owns
    /// preparation or shutdown, and never operates on an engine still being used by the scene.
    private struct HapticEngineTransfer: @unchecked Sendable { let engine: CHHapticEngine }

    // The backdrop, which stays put as everything else scrolls over it.
    private let backdrop = UIView()
    private let wash = CAGradientLayer(), fade = CAGradientLayer(), coolGlow = CALayer(), warmGlow = CALayer()
    private let scroll = UIScrollView()
    private let content = UIView()
    // The card: the page, cropped, with a card peeking out behind.
    private let group = CATransformLayer()
    private let back = CALayer()
    private let shadowWide = CALayer(), shadowNear = CALayer()
    private let card = CALayer()
    private let reveal: SummaryReveal
    private let summaryHost: UIHostingController<SummaryBlocks>
    private(set) var summaryHeight: CGFloat = 0
    /// The card, where it shows, for taps.
    private var cardArea = CGRect.null
    /// The follow-up field at the summary's end.
    private let followUp = UITextField()
    private lazy var followUpPress = UILongPressGestureRecognizer(target: self, action: #selector(pressedFollowUp))
    /// Resting at the end: from when, and after how many blocks of what was just revealed, which
    /// it fades in after, as one more; nil blocks when it comes forward with a recalled summary.
    private var followUpShown: (t0: Double, after: Int?)?
    /// Asking the model about a question sent from the field, and when its answer was revealed.
    private var followUpTask: Task<Void, Never>?
    private var followUpReveals: [(followUp: SummaryFollowUp, t0: Double)] = []
    /// Holds the field at the bottom of the screen, on the keyboard's layout guide, so it rides
    /// on the keyboard as it opens, closes or is dragged away.
    private let dock = UIView()
    /// Fades the summary out just above the field.
    private let summaryFade = CAGradientLayer()
    /// The fade's shape over the field (the replay's `fades` tries others side by side).
    var fadeShape = M.followUpFade { didSet { fadeShapeChanged = true } }
    private var fadeShapeChanged = true
    /// A question flying from the field to its bubble, from `t0`, as its copy.
    private var sending: (flight: SendFlight, t0: Double, followUp: SummaryFollowUp, ghost: SendGhost)?
    private var keyboardHeight = 0.0
    private lazy var cardElement = UIAccessibilityElement(accessibilityContainer: scroll)

    /// `page` makes a replica of the page, as `snapshotView(afterScreenUpdates:)` does, which is
    /// quick enough to make as the fingers start to move, unlike drawing it.
    init(page: @escaping () -> UIView, title: String, size: CGSize, summaryHost: UIHostingController<SummaryBlocks>) {
        pageReplica = page()
        self.size = size
        let reveal = SummaryReveal()
        self.reveal = reveal
        self.summaryHost = summaryHost
        super.init(frame: CGRect(origin: .zero, size: size))
        // A light canvas keeps the summary readable over Rise's pale icon colours.
        overrideUserInterfaceStyle = .light
        accessibilityViewIsModal = true

        backdrop.frame = bounds
        backdrop.isUserInteractionEnabled = false
        addSubview(backdrop)
        // linear-gradient(100deg, …): the line runs through the middle, long enough to reach the corners.
        let angle = 100*degrees, direction = CGPoint(x: sin(angle), y: -cos(angle))
        let half = (abs(size.width*direction.x)+abs(size.height*direction.y))/2
        // Rise.icon's cream, mint and lilac, softened towards white.
        wash.colors = [Self.color(0xFFF8EC), Self.color(0xF1FCFB), Self.color(0xF9F4FE)]
        wash.locations = [0, 0.5, 1]
        wash.startPoint = CGPoint(x: 0.5-direction.x*half/size.width, y: 0.5-direction.y*half/size.height)
        wash.endPoint = CGPoint(x: 0.5+direction.x*half/size.width, y: 0.5+direction.y*half/size.height)
        wash.frame = bounds
        for glow in [coolGlow, warmGlow] { glow.opacity = 0 }
        coolGlow.contents = Self.coolGlowImage
        warmGlow.contents = Self.warmGlowImage
        for glow in [coolGlow, warmGlow] {
            guard let image = glow.contents.map({ $0 as! CGImage }) else { continue }
            glow.bounds.size = CGSize(width: image.width, height: image.height)
        }
        // Lighter towards the bottom.
        fade.colors = [Self.color(0xF9FAFD, alpha: 0), Self.color(0xF9FAFD)]
        fade.startPoint = CGPoint(x: 0.5, y: 0.68)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.frame = bounds
        for layer in [wash, coolGlow, warmGlow, fade] { backdrop.layer.addSublayer(layer) }

        scroll.frame = bounds
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        // Short summaries still give a little under a finger, as long ones do at their ends.
        scroll.alwaysBounceVertical = true
        scroll.isScrollEnabled = false
        scroll.contentSize = size
        scroll.keyboardDismissMode = .interactive
        scroll.delegate = self
        addSubview(scroll)
        content.frame = bounds
        scroll.addSubview(content)

        // Plain, as the summary's text: no fill or border, its text where the paragraphs' starts.
        followUp.font = .systemFont(ofSize: 17)
        followUp.textColor = UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 0.85)
        followUp.tintColor = UIColor(red: 42/255, green: 48/255, blue: 1, alpha: 1)
        followUp.returnKeyType = .send
        followUp.enablesReturnKeyAutomatically = true
        followUp.isUserInteractionEnabled = false
        followUp.delegate = self
        // Placed and scaled from its text's left.
        followUp.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        setFollowUpPlaceholder(Self.askPlaceholder)
        // Focused as soon as a finger lands on it, rather than when it lifts.
        followUpPress.minimumPressDuration = 0
        followUpPress.allowableMovement = .greatestFiniteMagnitude
        // The field's own taps and the summary's scrolling still see the touch.
        followUpPress.cancelsTouchesInView = false
        followUpPress.delegate = self
        followUp.addGestureRecognizer(followUpPress)
        dock.isHidden = true
        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.addSubview(followUp)
        // Softer than the text, stronger than the placeholder.
        let accessoryTint = UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 0.55)
        plusGlyph.tintColor = accessoryTint
        plusGlyph.contentMode = .scaleAspectFit
        plusGlyph.isUserInteractionEnabled = false
        plusButton.addSubview(plusGlyph)
        plusButton.accessibilityLabel = "Add"
        micGlyph.tintColor = accessoryTint
        micGlyph.contentMode = .scaleAspectFit
        micButton.isAccessibilityElement = true
        micButton.accessibilityLabel = "Dictate"
        micButton.accessibilityHint = "Hold to dictate a question."
        micWave.alpha = 0
        for glyph in [micGlyph, micWave] as [UIView] { glyph.isUserInteractionEnabled = false; micButton.addSubview(glyph) }
        micHold.minimumPressDuration = 0.15
        // The button keeps the finger, staying pressed while it listens.
        micHold.cancelsTouchesInView = false
        micHold.delegate = self
        for button in [plusButton, micButton] {
            // As the bar's buttons in fields: pressed in, with the same light, crisp tap.
            button.shrinksWhenPressed(to: AddressBar.pressedScale)
            button.addAction(UIAction { [weak self] _ in self?.accessoryTap.impactOccurred(intensity: 0.5) }, for: .touchDown)
        }
        micButton.addGestureRecognizer(micHold)
        plusSlot.addSubview(plusButton)
        micSlot.addSubview(micButton)
        for (slot, button) in [(plusSlot, plusButton as UIView), (micSlot, micButton)] {
            button.alpha = 0
            button.isUserInteractionEnabled = false
            button.accessibilityElementsHidden = true
            dock.addSubview(slot)
        }
        addSubview(dock)
        // From the screen's bottom with the keyboard down, not the safe area's, which the browser
        // raises over its bar. The keyboard picks the field up once it reaches it, and sets it
        // back there going away.
        keyboardLayoutGuide.usesBottomSafeArea = false
        let riding = dock.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        riding.priority = .defaultHigh
        NSLayoutConstraint.activate([
            dock.leadingAnchor.constraint(equalTo: leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: trailingAnchor),
            riding,
            dock.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -M.followUpRestLift),
            dock.heightAnchor.constraint(equalToConstant: M.followUpHeight+M.followUpBottomGap),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

        back.frame = CGRect(x: M.backInset, y: -M.backPeek, width: size.width-2*M.backInset, height: 90)
        back.backgroundColor = Self.color(0xC7C7CB)
        back.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        back.opacity = 0
        for shadow in [shadowWide, shadowNear] {
            shadow.shadowColor = Self.color(0x343232)
            shadow.shadowOpacity = 0
        }
        shadowWide.shadowRadius = 17; shadowWide.shadowOffset = CGSize(width: 0, height: 10)
        shadowNear.shadowRadius = 1.5; shadowNear.shadowOffset = CGSize(width: 0, height: 1)
        card.masksToBounds = true
        card.backgroundColor = UIColor.systemBackground.cgColor
        card.addSublayer(pageReplica.layer)
        for layer in [back, shadowWide, shadowNear, card] { group.addSublayer(layer) }
        content.layer.addSublayer(group)

        summaryHost.safeAreaRegions = []
        summaryHost.view.backgroundColor = .clear
        summaryHost.view.isHidden = true
        // The card stays over the summary as it grows back over it. Its layers are sorted by depth
        // with the summary's, and the card is tipped, so it's brought well forward; there's no
        // perspective out here for that to show.
        content.layer.addSublayer(group)
        group.zPosition = 2000

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        scroll.addGestureRecognizer(tap)
        // Around the field too, under and beside it.
        let dockTap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        dockTap.delegate = self
        dock.addGestureRecognizer(dockTap)
        cardElement.accessibilityLabel = title
        cardElement.accessibilityHint = "Returns to the page."
        cardElement.accessibilityTraits = .button
        scroll.accessibilityElements = [cardElement, summaryHost.view!]

        let link = CADisplayLink(target: ticker, selector: #selector(FrameTicker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // The browser parks this view while closed. Move it only once the new scene is in the
        // same window, avoiding a detach/reattach and SwiftUI environment rebuild at each end.
        content.addSubview(summaryHost.view)
        content.layer.addSublayer(group)
    }

    private static func color(_ hex: Int, alpha: CGFloat = 1) -> CGColor {
        UIColor(red: CGFloat(hex >> 16 & 0xFF)/255, green: CGFloat(hex >> 8 & 0xFF)/255,
                blue: CGFloat(hex & 0xFF)/255, alpha: alpha).cgColor
    }

    private var width: Double { Double(size.width) }
    private var height: Double { Double(size.height) }
    private var cardHeight: Double { width*M.cardAspect }
    /// The summary's top in the content, under the revealed card.
    private var summaryTop: Double { M.revealTop+cardHeight*M.revealScale*cos(M.restTilt*degrees)+M.textGap }
    /// How far the summary has sunk back as the card grows back over it.
    private func closeRecede(_ t: Double) -> Double { 1-M.closeRecede*clamp(M.close(t-(closeT ?? t)), 0, 1.2) }

    /// Moves the clock on, never back: frames run on when they'll show, and touches on when they come.
    @discardableResult private func tick(to time: CFTimeInterval? = nil) -> Double {
        now = max(now, (time ?? manualTime ?? CACurrentMediaTime())-clock0)
        return now
    }

    // MARK: Starting

    /// Follows a pinch in on the page from here, the point under the fingers staying under them.
    func beginPinch(at point: CGPoint) {
        let t = tick()
        mode = .pinch; path = .pinch; t0 = t
        anchor = point
        orbitT0 = t; orbitStop = nil
        pinchHistory = []
        grabScale = 1; grabOffsets = nil
        log?.event("pinch", "from \(Int(point.x)), \(Int(point.y))")
        prepareHaptics()
        follow(scale: 1, centroid: point, t)
        render(t)
    }

    func updatePinch(scale: CGFloat, centroid: CGPoint) {
        guard mode == .pinch else { return }
        let t = tick()
        follow(scale: Double(scale), centroid: centroid, t)
    }

    /// Growing back into the page, or springing back to it, a pinch can catch it.
    var canGrab: Bool { mode == .closing || mode == .cancel }

    /// Caught by a pinch on the way back to the page: it carries on from wherever it is, at its
    /// size, the point under the fingers staying under them.
    func grab(at centroid: CGPoint) {
        guard canGrab else { return }
        let t = tick()
        log?.event("grab", String(format: "while %@ %.2f s in, at scale %.3f", mode == .closing ? "closing" : "springing back",
                                  t-(closeT ?? t0), value(.scale, t)))
        let swing = swingOffsets(t)
        let s = value(.scale, t), x = value(.x, t)+swing.x, top = value(.top, t)+swing.y
        let cropTop = value(.cropTop, t), cropH = value(.cropH, t), tilt = value(.rotation, t)
        let middle = top+cropH*s*cos(tilt*degrees)/2
        anchor = CGPoint(x: (Double(centroid.x)-width/2-x)/s+width/2, y: (Double(centroid.y)-middle)/s+cropTop+cropH/2)
        let shape = pinchShape(s)
        grabScale = s
        grabOffsets = (t, cropTop-shape.cropTop, cropH-shape.cropH, value(.radius, t)-shape.radius, tilt-shape.tilt)
        // The glows carry on round from where they are.
        let angle = orbitAngle(t)
        orbitT0 = t-(angle-Double.pi)/(2*Double.pi)*M.orbitPeriod; orbitStop = nil
        mode = .pinch; path = .pinch; t0 = t
        swingT0 = nil; closeT = nil; revealT = nil; pendingReveal = nil; recallT = nil
        // Its request was let go as it grew back; let go again, it shows the summary it had or asks again.
        task = nil; readyT = .infinity
        pinchHistory = []
        follow(scale: 1, centroid: centroid, t)
        render(t)
    }

    /// The page through the touches, as the pinch sees it, while it's being grabbed.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        canGrab ? nil : super.hitTest(point, with: event)
    }

    /// The page at the fingers' scale, giving past its limits, with the point they started on
    /// under them, cropping, rounding and tipping towards the card as it shrinks.
    private func follow(scale: Double, centroid: CGPoint, _ t: Double, recording: Bool = true) {
        self.fingers = (scale, centroid)
        // The touches' own time, not the clock, which runs on to the next frame and would bunch them up.
        let touched = (manualTime ?? CACurrentMediaTime())-clock0
        let fingers = scale*grabScale
        let s = fingers > 1 ? 1+(M.pinchMaxScale-1)*(1-exp(-(fingers-1)/(M.pinchMaxScale-1)))
            : fingers < M.pinchMinScale ? M.pinchMinScale*exp(-(M.pinchMinScale-fingers)/M.pinchMinScale) : fingers
        var shape = pinchShape(s)
        if let grabOffsets {
            let left = 1-M.grabBlend(t-grabOffsets.t)
            shape.cropTop += grabOffsets.cropTop*left; shape.cropH += grabOffsets.cropH*left
            shape.radius += grabOffsets.radius*left; shape.tilt += grabOffsets.tilt*left
            if left < 1e-3 { self.grabOffsets = nil }
        }
        let (cropTop, cropH, tilt) = (shape.cropTop, shape.cropH, shape.tilt)
        let x = Double(centroid.x)-(Double(anchor.x)-width/2)*s-width/2
        let middle = Double(centroid.y)-(Double(anchor.y)-cropTop-cropH/2)*s
        let top = middle-cropH*s*cos(tilt*degrees)/2
        set(.cropTop, cropTop, t); set(.cropH, cropH, t); set(.rotation, tilt, t); set(.radius, shape.radius, t)
        set(.scale, s, t); set(.x, x, t); set(.top, top, t)
        guard recording else { return }
        pinchHistory.append((touched, s, x, top))
        pinchHistory.removeAll { touched-$0.t > M.velocityWindow }
    }

    /// How the page is cropped, rounded and tipped at a pinch's scale, more like the card the smaller it is.
    private func pinchShape(_ s: Double) -> (cropTop: Double, cropH: Double, radius: Double, tilt: Double) {
        let k = pow(clamp((1-s)/(1-M.loadScale)), M.pinchEasing)
        return (lerp(0, M.cropTop, k), lerp(height, cardHeight, k),
                lerp(M.pinchRadius, M.cardRadius, k)*min(1, k/M.pinchRounding), lerp(0, M.restTilt, k))
    }

    /// Let go small enough, or shrinking quickly enough, it flies to the card at the speed it was
    /// going; otherwise it springs back to the page.
    func endPinch(cancelled: Bool) {
        guard mode == .pinch else { return }
        let t = tick()
        var velocity = (scale: 0.0, x: 0.0, top: 0.0)
        if let first = pinchHistory.first, let last = pinchHistory.last, last.t-first.t > 0.008 {
            let dt = last.t-first.t
            velocity = (clamp((last.scale-first.scale)/dt, -M.maxScaleSpeed, M.maxScaleSpeed),
                        clamp((last.x-first.x)/dt, -M.maxMoveSpeed, M.maxMoveSpeed),
                        clamp((last.top-first.top)/dt, -M.maxMoveSpeed, M.maxMoveSpeed))
        }
        let scale = value(.scale, t)
        let commits = !cancelled && (velocity.scale < -M.commitSpeed || (scale < M.commitScale && velocity.scale < M.commitSpeed))
        log?.event("let go", String(format: "scale %.3f, speed %.2f/s, moving %.0f, %.0f pt/s, %@", scale, velocity.scale,
                                    velocity.x, velocity.top, commits ? "summarising" : cancelled ? "cancelled" : "springing back"))
        if commits {
            startSummary()
            startCard(.pinch, t, velocity: velocity)
        } else {
            mode = .cancel; t0 = t
            tweens[.scale] = Tween(from: scale, to: 1, t0: t, curve: .release(M.cancel, velocity: velocity.scale))
            tweens[.x] = Tween(from: value(.x, t), to: 0, t0: t, curve: .release(M.cancel, velocity: velocity.x))
            tweens[.top] = Tween(from: value(.top, t), to: 0, t0: t, curve: .release(M.cancel, velocity: velocity.top))
            for (key, to) in [(Key.cropTop, 0.0), (.cropH, height), (.radius, 0), (.rotation, 0)] {
                tween(key, to: to, .spring(M.cancel), t)
            }
            stopHum()
        }
    }

    /// Summarise in More: the whole page shrinks into the card as the bar drops away.
    func startFromMenu() {
        let t = tick()
        path = .menu
        log?.event("menu")
        set(.cropTop, 0, t); set(.cropH, height, t); set(.radius, 0, t); set(.rotation, 0, t)
        set(.scale, 1, t); set(.x, 0, t); set(.top, 0, t)
        orbitT0 = t; orbitStop = nil
        prepareHaptics()
        startSummary()
        startCard(.menu, t)
        render(t)
    }

    private func startSummary() {
        guard task == nil else { return }
        // Caught on its way back, or summarised before with the page unchanged, it has the summary
        // already; a failed one is asked for again.
        if let known = summaryFailed ? memorised : reveal.summary ?? memorised { recall(known); return }
        guard let makeSummary else { return }
        startHum()
        let asked = log?.now
        task = Task { [weak self] in
            let summary: PageSummary, failed: Bool
            do {
                try await Task.sleep(for: .seconds(M.requestDelay))
                summary = try await makeSummary(); failed = false
            } catch {
                if Task.isCancelled { return }
                summary = .failure(error); failed = true
            }
            guard !Task.isCancelled, let self else { return }
            log?.event("summary", String(format: "%@after %.2f s", failed ? "failed " : "", (log?.now ?? 0)-(asked ?? 0)))
            summaryFailed = failed
            if !failed { onSummary?(summary) }
            summaryArrived(summary)
        }
    }

    private func summaryArrived(_ summary: PageSummary) {
        guard mode != .closing, mode != .done else { return }
        reveal.summary = summary
        measureSummary()
        summaryHost.view.isHidden = false
        readyT = tick()
        log?.event("laid out", String(format: "%.0f pt tall", summaryHeight))
    }

    /// A summary already known shows at once: `startCard` flies the card straight to where it
    /// shows it, and the text comes forward as it fades in.
    private func recall(_ summary: PageSummary) {
        let t = tick(), started = CACurrentMediaTime()
        if reveal.summary != summary || !reveal.followUps.isEmpty || summaryHeight == 0 {
            reveal.summary = summary
            reveal.followUps = []; followUpReveals = []
            measureSummary()
        }
        summaryFailed = false
        summaryHost.view.isHidden = false
        recallT = t
        log?.event("summary recalled", String(format: "%.0f pt tall, laid out in %.1f ms", summaryHeight,
                                              (CACurrentMediaTime()-started)*1000))
    }

    /// Measured with what's changed in place, which the hosting controller only takes up on its next update.
    private func measureSummary() {
        summaryHost.rootView = SummaryBlocks(reveal: reveal)
        summaryHost.view.setNeedsLayout()
        summaryHost.view.layoutIfNeeded()
        summaryHeight = summaryHost.sizeThatFits(in: CGSize(width: size.width, height: .greatestFiniteMagnitude)).height
    }

    // MARK: The card

    private func set(_ key: Key, _ value: Double, _ t: Double) { tweens[key] = Tween(from: value, to: value, t0: t, curve: .none) }
    private func tween(_ key: Key, to: Double, _ curve: Tween.Curve, _ t: Double) {
        tweens[key] = Tween(from: value(key, t), to: to, t0: t, curve: curve)
    }
    private func value(_ key: Key, _ t: Double) -> Double { tweens[key]?.value(at: t) ?? 0 }

    /// Into the card: from the page on More's springs, or from wherever the fingers left it on
    /// `release`, at the speed they were going, so a hard pinch shoots past and springs back.
    private func startCard(_ path: Path, _ t: Double, velocity: (scale: Double, x: Double, top: Double)? = nil) {
        mode = .card; t0 = t; swingT0 = t; revealT = nil; closeT = nil
        swingDirection = Bool.random() ? 1 : -1
        hideBar(t)
        // With the summary already here, it goes straight to where it shows it.
        let recalled = recallT != nil
        let scale = recalled ? M.revealScale : M.loadScale, top = recalled ? M.revealTop : M.loadTop
        let crop = velocity == nil ? M.menuCrop : M.placeCrop
        tween(.cropTop, to: M.cropTop, .spring(crop), t)
        tween(.cropH, to: cardHeight, .spring(crop), t)
        tween(.radius, to: M.cardRadius, .spring(crop), t)
        tween(.rotation, to: M.restTilt, .spring(crop), t)
        if let velocity {
            tweens[.scale] = Tween(from: value(.scale, t), to: scale, t0: t, curve: .release(M.releaseScale, velocity: velocity.scale))
            tweens[.x] = Tween(from: value(.x, t), to: 0, t0: t, curve: .release(M.releaseMove, velocity: velocity.x))
            tweens[.top] = Tween(from: value(.top, t), to: top, t0: t, curve: .release(M.releaseMove, velocity: velocity.top))
        } else {
            tween(.scale, to: scale, .spring(M.menuShrink), t)
            tween(.x, to: 0, .spring(M.menuShrink), t)
            tween(.top, to: top, .spring(M.menuShrink), t)
        }
        if recalled {
            // Shown from the start, so it never swings.
            revealT = t; pendingReveal = nil
            stopOrbit(t)
            restFollowUp(t, after: nil)
        }
    }

    /// The glows carry on to the left, then stop there.
    private func stopOrbit(_ t: Double) {
        let a = orbitAngle(t), turn = 2*Double.pi
        orbitStop = (t, a, Double.pi+turn*ceil((a-Double.pi+1e-6)/turn))
    }

    private func swingPhase(_ t: Double) -> Double { 2*Double.pi*(t-(swingT0 ?? t))/M.swingPeriod }

    private func swingOffsets(_ t: Double) -> (x: Double, rz: Double, y: Double) {
        guard swingT0 != nil, !reducesMotion else { return (0, 0, 0) }
        var phase = swingPhase(t), amount = 1.0
        if let revealT, t >= revealT {
            phase = swingPhase(revealT)
            amount = 1-M.reveal(t-revealT)
        }
        if let closeT, t >= closeT { amount *= 1-M.close(t-closeT) }
        let s = sin(phase)*swingDirection
        return (M.swingX*s*amount, M.swingTilt*s*amount, M.swingY*cos(2*phase)*amount)
    }

    private func maybeReveal(_ t: Double) {
        guard mode == .card, revealT == nil, closeT == nil, t >= readyT, let swingT0 else { return }
        if !reducesMotion {
            // The swing passes its middle every half period: reveal there, unless it only just did.
            let half = M.swingPeriod/2, previous = swingT0+floor((t-swingT0)/half)*half
            if t-previous > M.syncTolerance { pendingReveal = previous+half; return }
        }
        revealSummary(t)
    }

    private func revealSummary(_ t: Double) {
        revealT = t; pendingReveal = nil
        log?.event("reveal")
        tween(.scale, to: M.revealScale, .spring(M.reveal), t)
        tween(.top, to: M.revealTop, .spring(M.reveal), t)
        stopOrbit(t)
        stopHum()
        playRevealHaptic()
        if !reveal.followUps.isEmpty { reveal.followUps = []; followUpReveals = []; measureSummary() }
        restFollowUp(t, after: reveal.blockCount)
    }

    /// Grows the card back into the page, from wherever it shows, as the summary fades and sinks
    /// back and the bar springs back.
    func close() {
        guard mode == .card else { return }
        let t = tick()
        log?.event("close", String(format: "%@, scrolled %.0f pt, summary %.0f pt, scale %.3f, %@",
                                   revealT == nil ? "before the summary" : "summary shown \(String(format: "%.1f", t-(revealT ?? t))) s",
                                   scroll.contentOffset.y, summaryHeight, value(.scale, t), describePage?() ?? ""))
        mode = .closing; closeT = t
        task?.cancel()
        stopHum()
        endSend()
        followUpTask?.cancel(); followUpTask = nil
        followUp.isUserInteractionEnabled = false
        stopDictating(keep: false)
        followUp.resignFirstResponder()
        closeScroll = Double(scroll.contentOffset.y)
        scroll.contentInset = .zero
        scroll.contentOffset = .zero
        set(.top, value(.top, t)-closeScroll, t)
        for (key, to) in [(Key.scale, 1.0), (.x, 0), (.top, 0), (.cropTop, 0), (.cropH, height), (.radius, 0), (.rotation, 0)] {
            tween(key, to: to, .spring(M.close), t)
        }
        showBar(t)
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// Done at once, as when the window changes size.
    func finish() {
        guard mode != .done else { return }
        let ending = phase(now)
        mode = .done
        endSend()
        stopDictating(keep: false)
        followUp.resignFirstResponder()
        link?.invalidate(); link = nil
        task?.cancel()
        stopHum()
        // Releasing the engine also tears down its audio session, including synchronous XPC.
        // Keep it alive through the stop on a worker so that cannot hold up the live page.
        if let engine = haptics {
            let transfer = HapticEngineTransfer(engine: engine)
            haptics = nil
            Task.detached(priority: .utility) { try? await transfer.engine.stop() }
        }
        onBar?(0)
        let started = CACurrentMediaTime()
        onFinish?()
        log?.event("finish", String(format: "after %@, cleanup %.1f ms", ending, (CACurrentMediaTime()-started)*1000))
        log?.finish()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard mode == .card else { return false }
        close()
        return true
    }

    /// A tap anywhere but the field lets the keyboard go, and does only that; without it, a tap
    /// on the card returns to the page. A swipe isn't a tap, so it scrolls, and a swipe down
    /// lets the keyboard go interactively as before.
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        if followUp.isFirstResponder { followUp.resignFirstResponder(); return }
        if tap.view === scroll, cardArea.contains(tap.location(in: content)) { close() }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Once focused, presses on the field are the text's, for the cursor and selection.
        if gestureRecognizer === followUpPress { return mode == .card && followUp.isUserInteractionEnabled && !followUp.isFirstResponder }
        return mode == .card
    }

    /// Taps on the follow-up field are its own, not the card's.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === followUpPress || gestureRecognizer === micHold { return true }
        guard let view = touch.view else { return true }
        return ![followUp, plusSlot, micSlot].contains { view.isDescendant(of: $0) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === followUpPress
    }

    /// A finger landing on the field focuses it at once, without waiting for it to lift.
    @objc private func pressedFollowUp(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, !followUp.isFirstResponder else { return }
        log?.event("follow-up pressed")
        followUp.becomeFirstResponder()
    }

    // MARK: The follow-up field

    private static let askPlaceholder = "Ask follow up about page"

    /// The field and, focused, the plus and microphone either side of it.
    private func layOutFollowUpRow() {
        let side = Double(SummaryBlocks.sideSpacing), space = followUpRowOpen ? M.followUpAccessory : 0
        let height = M.followUpHeight, middle = height/2
        followUp.bounds = CGRect(x: 0, y: 0, width: width-2*side-2*space, height: height)
        followUp.center = CGPoint(x: side+space, y: middle)
        // The plus's glyph starts where the text did; the microphone's ends at the text's right.
        plusSlot.frame = CGRect(x: side-8, y: 0, width: M.followUpAccessory, height: height)
        micSlot.frame = CGRect(x: width-side-M.followUpAccessory+8, y: 0, width: M.followUpAccessory, height: height)
        for button in [plusButton, micButton] {
            button.bounds = CGRect(x: 0, y: 0, width: M.followUpAccessory, height: height)
            button.center = CGPoint(x: M.followUpAccessory/2, y: middle)
        }
        micWave.bounds = micButton.bounds
        for glyph in [plusGlyph, micGlyph] {
            glyph.bounds = CGRect(x: 0, y: 0, width: M.accessoryIconSize, height: M.accessoryIconSize)
        }
        plusGlyph.center = CGPoint(x: M.followUpAccessory/2, y: middle)
        for glyph in [micGlyph, micWave] as [UIView] { glyph.center = CGPoint(x: M.followUpAccessory/2, y: middle) }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { setFollowUpEditing(true) }

    func textFieldDidEndEditing(_ textField: UITextField) { setFollowUpEditing(false) }

    /// Focused, the field moves over for the plus as it and the microphone fade in, as Find's Ask
    /// button comes in; unfocused, all of it goes back.
    private func setFollowUpEditing(_ editing: Bool) {
        guard editing != followUpEditing else { return }
        followUpEditing = editing
        if !editing { stopDictating(keep: true) }
        followUpRowOpening?.cancel()
        followUpRowOpening = nil
        if editing, window != nil, !reducesMotion {
            let opening = DispatchWorkItem { [weak self] in
                guard let self, followUpEditing else { return }
                followUpRowOpening = nil
                setFollowUpRow(open: true)
            }
            followUpRowOpening = opening
            accessoryTap.prepare()
            DispatchQueue.main.asyncAfter(deadline: .now()+M.followUpRowDelay, execute: opening)
        } else {
            setFollowUpRow(open: editing)
        }
    }

    private func setFollowUpRow(open: Bool) {
        guard open != followUpRowOpen else { return }
        followUpRowOpen = open
        let editing = open
        for button in [plusButton, micButton] as [UIView] {
            button.isUserInteractionEnabled = editing
            button.accessibilityElementsHidden = !editing
        }
        guard window != nil, !reducesMotion else {
            layOutFollowUpRow()
            for (slot, button) in [(plusSlot, plusButton as UIView), (micSlot, micButton)] {
                BlurCrossfade.stop(in: slot)
                button.alpha = editing ? 1 : 0
                button.transform = .identity
            }
            return
        }
        UIView.animate(springDuration: M.followUpRowSpring.duration, bounce: M.followUpRowSpring.bounce,
                       initialSpringVelocity: 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layOutFollowUpRow()
        }
        BlurCrossfade.swap(from: editing ? nil : plusButton, to: editing ? plusButton : nil, style: .symbol)
        BlurCrossfade.swap(from: editing ? nil : micButton, to: editing ? micButton : nil, style: .symbol)
    }

    // MARK: Dictating

    /// Holding the microphone listens as holding New Page does, the microphone swapped for the
    /// voice's red waveform, with the same hum; letting go transcribes on device into the field.
    @objc private func holdMicrophone(_ hold: UILongPressGestureRecognizer) {
        switch hold.state {
        case .began:
            guard followUpRowOpen, mode == .card, let voice, voice.begin() else { return }
            log?.event("dictation started")
            setMicListening(true)
        case .ended:
            guard let voice, voice.isRecording else { return }
            let transcription = voice.finish()
            setMicListening(false)
            dictating?.cancel()
            dictating = Task { [weak self] in
                let text = await transcription.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled, let self, !text.isEmpty, mode == .card else { return }
                insertDictation(text)
            }
        case .cancelled, .failed:
            stopDictating(keep: false)
        default: break
        }
    }

    /// Into the field after what's typed, ready to send.
    private func insertDictation(_ text: String) {
        let typed = followUp.text ?? ""
        let joined = typed.isEmpty ? text : typed.hasSuffix(" ") ? typed+text : typed+" "+text
        followUp.text = joined
        if followUp.isFirstResponder {
            let end = followUp.endOfDocument
            followUp.selectedTextRange = followUp.textRange(from: end, to: end)
        }
        log?.event("dictation inserted")
    }

    /// Stops listening; `keep` lets a transcription under way still land.
    private func stopDictating(keep: Bool) {
        if let voice, voice.isRecording {
            if keep {
                let transcription = voice.finish()
                dictating = Task { [weak self] in
                    let text = await transcription.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !Task.isCancelled, let self, !text.isEmpty, mode == .card else { return }
                    insertDictation(text)
                }
            } else {
                voice.cancel()
            }
            setMicListening(false)
        }
        if !keep { dictating?.cancel(); dictating = nil }
    }

    /// The microphone swapped for the waveform while it listens, and back, as New Page's plus.
    private func setMicListening(_ listening: Bool) {
        micWave.level = listening ? { [weak voice] in voice?.level ?? 0 } : nil
        micWave.listen(listening)
        micButton.accessibilityLabel = listening ? "Listening" : "Dictate"
        let previous: UIView = listening ? micGlyph : micWave, next: UIView = listening ? micWave : micGlyph
        guard window != nil, !reducesMotion else {
            BlurCrossfade.stop(in: micButton)
            previous.alpha = 0
            next.alpha = 1
            return
        }
        BlurCrossfade.swap(from: previous, to: next, style: .symbol)
    }

    private func setFollowUpPlaceholder(_ text: String) {
        followUp.attributedPlaceholder = NSAttributedString(string: text, attributes: [
            .font: SummaryBlocks.font,
            .foregroundColor: UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 0.35),
        ])
    }

    /// At rest under the end of what's been revealed, unfocused, ready to tap; it fades in as one
    /// more block after the `after` blocks revealed from `t`, or, with none, shows as it is.
    private func restFollowUp(_ t: Double, after blocks: Int?) {
        followUpShown = (t, blocks)
        followUp.text = nil
        followUp.isUserInteractionEnabled = true
    }

    /// The bottom inset that keeps the summary's last line clear of the field: under the field,
    /// the keyboard as it will be, or the bottom of the screen.
    private var bottomInset: Double {
        max(0, max(keyboardHeight, M.followUpRestLift)+M.followUpBottomGap+M.followUpHeight+fadeShape.clearance-SummaryBlocks.trailingSpace)
    }

    /// The field's top on screen, where it shows, riding on the keyboard.
    private var followUpTop: Double { Double(dock.layer.presentation()?.frame.minY ?? dock.frame.minY) }

    /// Where the summary scrolls a question's bubble to: under the last few lines before it, so
    /// they stay in sight above it, rather than at the very top with nothing above.
    private func sendTarget(_ asked: SummaryFollowUp) -> Double {
        let lines = Double(SendMotion.contextLines)*Double(SummaryBlocks.font.lineHeight+SummaryBlocks.lineSpacing)
        return max(0, asked.bubbleTop-Double(SummaryBlocks.paragraphSpacing)-lines-sendTop)
    }

    /// A finger takes the summary from a question's flight, from where it's going.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scroll.layer.removeAnimation(forKey: "send.bounds")
    }

    #if DEBUG
    /// For replays: focuses the field as a tap on it would.
    func focusFollowUpField() { _ = followUp.becomeFirstResponder() }
    /// For replays: tries a fade, drawn at once.
    func tryFade(_ shape: SummaryFade) { fadeShape = shape; render(tick()) }
    /// For replays: scrolls to the top.
    func scrollSummaryToTop() { scroll.setContentOffset(.zero, animated: false) }
    /// For replays: scrolls so the summary's last line sits at the bottom of the screen, under the field.
    func scrollTextUnderField() {
        let end = summaryTop+Double(summaryHeight)-Double(SummaryBlocks.trailingSpace)
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, end-height)), animated: false)
    }
    /// For replays: types `question` into the field and sends it, as Return would.
    func sendFollowUp(_ question: String) { followUp.text = question; sendFollowUp() }
    /// For replays: the scroll as it is, and the furthest it goes.
    var followUpScroll: (offset: Double, max: Double) {
        (Double(scroll.contentOffset.y), Double(scroll.contentSize.height+scroll.contentInset.bottom)-height)
    }
    /// For replays: scrolls as far down as it goes.
    func scrollToSummaryEnd(less: Double = 0) {
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, followUpScroll.max-less)), animated: false)
    }
    #endif

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendFollowUp()
        return false
    }

    /// The question lifts off the field and sweeps up into a blue bubble, as in the ChatGPT app, as
    /// the keyboard goes, the last few lines before it left in sight above and room under it for
    /// the answer. It
    /// shimmers there while the model answers it to the summary's hum.
    private func sendFollowUp() {
        let question = (followUp.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .card, followUpTask == nil, !question.isEmpty, let summary = reveal.summary, let answerFollowUp else { return }
        let t = tick()
        log?.event("follow-up asked")
        let history = reveal.followUps.compactMap { asked in
            asked.answer.map { PageAssistant.Turn(question: asked.question, answer: $0.joined(separator: "\n\n")) }
        }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let drawn = SendBubble.render(question, screen: size.width, scale: max(1, scale))
        let asked = SummaryFollowUp(question: question, textSize: drawn.size)
        // Where the typed text sits in the field, on screen, and where the bubble's text will, in the content.
        let shown = Double(scroll.layer.presentation()?.bounds.minY ?? scroll.contentOffset.y)
        let field = followUpTop+M.followUpHeight/2-Double(SummaryBlocks.font.lineHeight)/2
        asked.bubbleTop = summaryTop+Double(summaryHeight)-Double(SummaryBlocks.endSpacing)
        let bubble = SendBubble.size(text: drawn.size)
        let to = CGPoint(x: size.width-SendBubble.edgeInset-bubble.width+SendBubble.horizontalPadding,
                         y: asked.bubbleTop+Double(SendBubble.verticalPadding))
        asked.flying = !reducesMotion
        // The field stays, empty, until the answer has come.
        followUp.text = nil
        followUp.isUserInteractionEnabled = false
        reveal.followUps.append(asked)
        measureSummary()
        // Grows the content first, so there's room to scroll the bubble up.
        render(t)
        let target = sendTarget(asked)
        // The question is always the last thing, what it follows never under it. Scrolled up, with
        // the summary's end below the field, the flight starts from where that end sits just
        // above the field instead (a jump, as in ChatGPT), and the two rise together, the text
        // carried in its place in the content by the scroll alone.
        let start = min(target, max(shown, Double(to.y)-field))
        let from = CGPoint(x: SummaryBlocks.sideSpacing, y: start+field)
        scroll.layer.removeAllAnimations()
        scroll.contentOffset.y = CGFloat(target)
        if !reducesMotion {
            let flight = SendFlight(from: from, to: to, scrollFrom: start, scrollTo: target)
            let ghost = SendGhost(mask: drawn.image, textSize: drawn.size, scale: max(1, scale))
            // Over the field and the summary's fade, so it lifts off the field where it shows.
            layer.addSublayer(ghost.layer)
            ghost.fly(flight, startInk: followUp.textColor ?? .label, scroll: scroll.layer, onScreen: true)
            sending = (flight, t, asked, ghost)
            // On the render server before the keyboard's teardown holds up the main thread.
            CATransaction.flush()
        }
        followUp.resignFirstResponder()
        startHum()
        followUpTask = Task { [weak self] in
            let answer: [String]
            do {
                answer = try await answerFollowUp(question, summary, history)
            } catch {
                if Task.isCancelled { return }
                answer = ["Rise couldn’t answer that. \(error.localizedDescription)"]
            }
            guard !Task.isCancelled, let self else { return }
            followUpAnswered(asked, answer)
        }
    }

    /// The top of what's left in sight above a question that has flown up: just under the status bar.
    private var sendTop: Double { max(Double(safeAreaInsets.top), 20)+SendMotion.topGap }

    /// Landed: the bubble takes over from its copy, in the same frame.
    private func stepSend(_ t: Double) {
        guard let sending, t-sending.t0 >= sending.flight.duration else { return }
        endSend()
    }

    /// Hands over to the bubble, or, closing, drops the copy and the scroll where they are.
    private func endSend() {
        guard let sending else { return }
        self.sending = nil
        sending.followUp.flying = false
        summaryHost.view.setNeedsLayout()
        summaryHost.view.layoutIfNeeded()
        sending.ghost.layer.removeFromSuperlayer()
        if mode != .card { scroll.layer.removeAllAnimations() }
    }

    /// The answer fades in and sharpens under its question's bubble as the summary did, with the
    /// same thud, in the room left under it; the field comes back under it.
    private func followUpAnswered(_ asked: SummaryFollowUp, _ answer: [String]) {
        guard mode == .card, reveal.followUps.contains(where: { $0 === asked }) else { return }
        let t = tick()
        log?.event("follow-up answered")
        followUpTask = nil
        asked.answer = answer
        measureSummary()
        followUpReveals.append((asked, t))
        stopHum()
        playRevealHaptic()
        followUp.isUserInteractionEnabled = true
        render(t)
    }

    private func stepFollowUpReveals(_ t: Double) {
        followUpReveals.removeAll { asked, t0 in
            let elapsed = t-t0
            let settled = M.textDelay+M.stagger*Double(asked.answer?.count ?? 0)+6*max(M.blurTau, M.fadeTau)
            asked.elapsed = elapsed > settled ? .infinity : elapsed
            return elapsed > settled
        }
    }

    /// The field rides on the keyboard by its layout guide. The summary makes room for it and
    /// stays where it is as the keyboard comes up, or, scrolled to its end, stays at its end, its
    /// last line rising with the field. Going away, it comes back only as far as it has to to
    /// stay within its end. Both in the keyboard's own animation (its duration and curve). A
    /// question just sent scrolls on its own flight instead.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard mode == .card, let screen = window?.screen, let info = note.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let frame = convert(end, from: screen.coordinateSpace)
        let current = Double(scroll.contentOffset.y), before = Double(scroll.contentInset.bottom)
        let atEnd = current >= maxScroll(inset: before)-1
        keyboardHeight = frame.minY < bounds.maxY ? Double(bounds.maxY-frame.minY) : 0
        let inset = bottomInset
        // UIKit pulls the scroll back within its end as soon as the content shrinks or the inset
        // does, so whichever grows goes first: the content gives up the answer's room as the
        // keyboard takes it, and before the inset had grown that clamped the scroll, a jump up.
        let grows = inset >= before
        if grows { scroll.contentInset.bottom = CGFloat(inset) }
        layOutContent(inset: inset)
        let follows = sending == nil && !scroll.isDragging && !scroll.isDecelerating
        let furthest = maxScroll(inset: inset)
        let target = grows && atEnd ? furthest : min(current, furthest)
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        UIView.animate(withDuration: duration, delay: 0,
                       options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]) {
            // Within the new end before the inset shrinks to it, so it isn't clamped there at once.
            if follows, target != current { self.scroll.contentOffset.y = CGFloat(target) }
            self.scroll.contentInset.bottom = CGFloat(inset)
        }
    }

    /// The field at the bottom of the screen. It fades in after what was just revealed, comes
    /// forward with a recalled summary, and sinks back with the summary on closing.
    private func renderFollowUp(_ t: Double, fadingOut: Double, forward: (scale: Double, alpha: Double)?) {
        guard revealT != nil, let shown = followUpShown, mode == .card || mode == .closing else { dock.isHidden = true; return }
        dock.isHidden = false
        layOutFollowUpRow()
        let left = Double(followUp.center.x)
        // About the middle of the screen, as the summary does.
        let centerY = followUpTop+M.followUpHeight/2
        func scaled(_ scale: Double) -> CGAffineTransform {
            let x = width/2+scale*(left-width/2), y = height/2+scale*(centerY-height/2)
            return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x-left, ty: y-centerY)
        }
        var alpha = 1-fadingOut
        if mode == .closing {
            followUp.transform = scaled(closeRecede(t))
        } else if let forward {
            followUp.transform = scaled(forward.scale)
            alpha *= forward.alpha
        } else {
            followUp.transform = .identity
            // One more block after those just revealed.
            if let blocks = shown.after, !reducesMotion {
                let elapsed = t-shown.t0-M.textDelay-M.stagger*Double(blocks)
                alpha *= elapsed <= 0 ? 0 : 1-exp(-elapsed/M.fadeTau)
            }
        }
        followUp.alpha = alpha
    }

    /// The summary fades out over `followUpFade` just above the field, wherever it scrolls.
    private func fadeSummary(over view: UIView) {
        // Closing, the fade stays where it was, on the summary as it sinks back with the field;
        // dropped at once, the text under the field showed in full for the close.
        if mode == .closing { return }
        guard mode == .card, revealT != nil, followUpShown != nil else { view.layer.mask = nil; return }
        let shownScroll = Double(scroll.layer.presentation()?.bounds.minY ?? scroll.contentOffset.y)
        let top = Double(view.frame.minY)-shownScroll, tall = max(1, Double(view.bounds.height))
        let shape = fadeShape, steps = shape.steps
        // Placed outright each frame, never eased there by an implicit animation: one that ran
        // after a long jump in the scroll (a question sent from far up) left the fade a quarter
        // of a second behind, hiding the bubble and the text above it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if fadeShapeChanged {
            fadeShapeChanged = false
            summaryFade.colors = [UIColor.black.cgColor]+steps.map { UIColor(white: 0, alpha: $0.alpha).cgColor }+[UIColor.clear.cgColor]
        }
        // From where the fade starts down to where the text is wholly gone, then held gone.
        let clear = (followUpTop+M.followUpFadeInto-shape.hold-top)/tall, fade = shape.height/tall
        summaryFade.frame = view.bounds
        summaryFade.locations = [0]+steps.map { NSNumber(value: clear-fade+$0.at*fade) }+[1]
        if view.layer.mask !== summaryFade { view.layer.mask = summaryFade }
    }

    // MARK: The bar

    private func hideBar(_ t: Double) { bar = (true, t, currentBar(t)) }
    private func showBar(_ t: Double) { bar = (false, t, currentBar(t)) }
    private func currentBar(_ t: Double) -> Double {
        guard let bar else { return 0 }
        let elapsed = t-bar.t0
        if bar.hide { return lerp(bar.from, 1, easeOut(elapsed/M.barExit, 1)) }
        return bar.from*(1-SummariseSpring(2*Double.pi/M.barResponse, 1-M.barBounce)(elapsed))
    }

    // MARK: Haptics

    /// Makes and starts the haptic engine away from the main thread as the page is picked up,
    /// since that takes a moment that would otherwise hold up the pinch's first frames.
    private func prepareHaptics() {
        guard !preparingHaptics else { return }
        preparingHaptics = true
        Task.detached { [weak self] in
            guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, let engine = try? CHHapticEngine() else { return }
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            guard (try? await engine.start()) != nil else { return }
            let transfer = HapticEngineTransfer(engine: engine)
            let accepted = await MainActor.run {
                guard let self, self.mode != .done else { return false }
                self.log?.event("haptics ready")
                self.haptics = transfer.engine
                self.hapticsReady = true
                self.playHum()
                return true
            }
            // The scene may have ended while the engine was starting. Stop it here, rather
            // than creating and releasing an audio session on the main actor's rejection path.
            if !accepted { try? await transfer.engine.stop() }
        }
    }

    private func startHum() {
        wantsHum = true
        playHum()
    }

    private func playHum() {
        guard wantsHum, hum == nil, hapticsReady, let haptics else { return }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.22),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0),
        ], relativeTime: 0, duration: 30)
        guard let player = try? haptics.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: [])) else { return }
        player.loopEnabled = true
        try? player.start(atTime: CHHapticTimeImmediate)
        hum = player
    }

    private func stopHum() {
        wantsHum = false
        try? hum?.stop(atTime: CHHapticTimeImmediate)
        hum = nil
    }

    /// One short, strong, dull thud as the summary appears, ending the hum.
    private func playRevealHaptic() { playTransient(intensity: 1, sharpness: 0.12) }

    private func playTransient(intensity: Float, sharpness: Float) {
        guard hapticsReady, let haptics else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)
        try? haptics.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: CHHapticTimeImmediate)
    }

    // MARK: Frames

    private func nextFrame() {
        guard let link, manualTime == nil else { return }
        let started = CACurrentMediaTime(), phase = phase(now)
        advance(to: link.targetTimestamp)
        log?.frame(phase: phase, vsync: link.timestamp, target: link.targetTimestamp, started: started, ended: CACurrentMediaTime())
    }

    /// What it's doing, for the log.
    private func phase(_ t: Double) -> String {
        switch mode {
        case .pinch: "pinch"
        case .cancel: "cancel"
        case .closing: "close"
        case .done: "done"
        case .card:
            if let revealT, t-revealT < 2.5 { "reveal" } else if t-t0 < 1.5 { "flight" } else { revealT == nil ? "loading" : "card" }
        }
    }

    /// Steps and renders for the given media time; also how tests drive it.
    func advance(to time: CFTimeInterval) {
        guard mode != .done else { return }
        if manualTime != nil { manualTime = time }
        let t = tick(to: time)
        step(t)
        guard mode != .done else { return }
        render(t)
    }

    private func step(_ t: Double) {
        // Caught, it comes to the pinch's shape even while the fingers rest.
        if mode == .pinch, grabOffsets != nil { follow(scale: fingers.scale, centroid: fingers.centroid, t, recording: false) }
        if mode == .cancel, t-t0 > 7/(M.cancel.w*M.cancel.z) { finish(); return }
        if mode == .card {
            if let pendingReveal { if t >= pendingReveal { revealSummary(t) } } else { maybeReveal(t) }
            stepSend(t)
            stepFollowUpReveals(t)
        }
        // Done once it has grown back.
        if mode == .closing, let closeT, t-closeT > 7/(M.close.w*M.close.z) {
            finish()
        }
    }

    private func orbitAngle(_ t: Double) -> Double {
        guard let orbitT0 else { return Double.pi }
        if let orbitStop, t >= orbitStop.t0 {
            let k = clamp((t-orbitStop.t0)/M.settle), e = 1-pow(1-k, 3)
            return lerp(orbitStop.a0, orbitStop.a1, e)
        }
        return Double.pi+2*Double.pi*(t-orbitT0)/M.orbitPeriod
    }

    private func perspective(_ distance: Double) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1/distance
        return transform
    }

    private func rotationX(_ angle: Double) -> CATransform3D { CATransform3DMakeRotation(angle*degrees, 1, 0, 0) }

    private func render(_ t: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        renderBackdrop(t)
        let w = width, h = height
        var overPage = false
        cardArea = .null

        switch mode {
        case .done: break
        case .pinch, .cancel, .card, .closing:
            let closing = mode == .closing
            let cropTop = value(.cropTop, t), cropH = value(.cropH, t), radius = value(.radius, t)
            let s = value(.scale, t), top = value(.top, t), tilt = value(.rotation, t)
            let swing = swingOffsets(t)
            let shown = cropH*s*cos(tilt*degrees)
            let cx = w/2+value(.x, t)+swing.x, cy = top+shown/2+swing.y
            group.bounds = CGRect(x: 0, y: 0, width: w, height: cropH)
            group.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            group.position = CGPoint(x: cx, y: cy)
            var transform = CATransform3DMakeScale(s, s, 1)
            transform = CATransform3DConcat(transform, CATransform3DMakeRotation(swing.rz*degrees, 0, 0, 1))
            transform = CATransform3DConcat(transform, rotationX(tilt))
            group.transform = CATransform3DConcat(transform, perspective(M.perspective))
            // The page, showing from `cropTop` down.
            card.frame = CGRect(x: 0, y: 0, width: w, height: cropH)
            card.cornerRadius = radius
            pageReplica.layer.frame = CGRect(x: 0, y: -cropTop, width: w, height: h)
            if let closeT, closing {
                overPage = t-closeT > 0.15
            } else {
                // Over the page's own top until it moves clear of the status bar.
                overPage = top+swing.y < 20
            }
            // The shadow comes in as the page shrinks away from the screen's edges.
            let shadow = M.shadow*(closing ? 1-clamp((t-(closeT ?? t))/0.2) : clamp((1-s)/(1-M.revealScale)))
            let path = UIBezierPath(roundedRect: card.frame, cornerRadius: radius).cgPath
            for layer in [shadowWide, shadowNear] { layer.frame = group.bounds; layer.shadowPath = path }
            shadowWide.shadowOpacity = Float(shadow); shadowNear.shadowOpacity = Float(shadow*0.8)

            // The card behind fades in once the card has settled.
            let cardT = swingT0.map { t-$0 } ?? 0
            let fadingOut = closing ? clamp((t-(closeT ?? t))/M.contentsOut) : 0
            back.cornerRadius = radius
            back.opacity = Float(clamp((cardT-M.backDelay)/M.backDuration)*(1-fadingOut))
            let backShown = M.backPeek*s
            cardArea = CGRect(x: cx-w*s/2, y: cy-shown/2-backShown, width: w*s, height: shown+backShown)
            renderSummary(t, fadingOut: fadingOut)
        }
        cardElement.accessibilityFrameInContainerSpace = scroll.convert(cardArea.isNull ? .zero : cardArea, from: content)
        onBar?(currentBar(t))
        if overPage != isOverPage {
            isOverPage = overPage
            let started = CACurrentMediaTime()
            onStatusBar?()
            log?.event("status bar", String(format: "over the %@, %.1f ms", overPage ? "page" : "backdrop", (CACurrentMediaTime()-started)*1000))
        }
    }

    /// The summary's blocks fade in and sharpen in turn, scrolling with the card. Closing, they
    /// fade and sink back in place as the page comes forward over them.
    private func renderSummary(_ t: Double, fadingOut: Double) {
        let revealed = revealT != nil
        let view = summaryHost.view!
        view.bounds.size = CGSize(width: size.width, height: summaryHeight)
        view.center = CGPoint(x: size.width/2, y: summaryTop+summaryHeight/2)
        // A recalled summary comes forward, as closing sinks it back, about the middle of the screen.
        var forward: (scale: Double, alpha: Double)?
        if let recallT, mode == .card {
            let k = clamp(M.close(t-recallT)), alpha = reducesMotion ? 1 : clamp((t-recallT)/M.recallFade)
            if k < 1 || alpha < 1 { forward = (reducesMotion ? 1 : 1-M.closeRecede*(1-k), alpha) }
        }
        if mode == .closing {
            let recede = closeRecede(t)
            // Scaled about the middle of the screen, from where it showed when the card was tapped.
            let dy = (1-recede)*(height/2-Double(view.center.y))-recede*closeScroll
            view.transform = CGAffineTransform(a: recede, b: 0, c: 0, d: recede, tx: 0, ty: dy)
        } else if let forward {
            let dy = (1-forward.scale)*(Double(scroll.contentOffset.y)+height/2-Double(view.center.y))
            view.transform = CGAffineTransform(a: forward.scale, b: 0, c: 0, d: forward.scale, tx: 0, ty: dy)
        } else {
            view.transform = .identity
        }
        view.alpha = (1-fadingOut)*(forward?.alpha ?? 1)
        let elapsed = revealed ? t-(revealT ?? t) : -1
        // Past the last block's settling, it stays as it is; a recalled summary is settled already.
        let settled = M.textDelay+M.stagger*Double(reveal.blockCount)+6*max(M.blurTau, M.fadeTau)
        let shown = recallT != nil || elapsed > settled ? Double.infinity : elapsed
        if reveal.elapsed != shown { reveal.elapsed = shown; reveal.reducesMotion = reducesMotion }
        scroll.isScrollEnabled = revealed && mode == .card
        // Clear of the field from the first summary on, not only once the keyboard has moved.
        let inset = bottomInset
        if Double(scroll.contentInset.bottom) != inset { scroll.contentInset.bottom = CGFloat(inset) }
        layOutContent(inset: inset)
        renderFollowUp(t, fadingOut: fadingOut, forward: forward)
        fadeSummary(over: view)
    }

    /// How far down the content goes: to the summary's end, and far enough for the latest
    /// question's bubble to stay where it was scrolled to with the screen under it free for the
    /// answer, so a short answer doesn't jump it back.
    private func contentEnd(inset: Double) -> Double {
        var end = summaryTop+Double(summaryHeight)
        if let asked = reveal.followUps.last { end = max(end, sendTarget(asked)+height-inset) }
        return end
    }

    /// The furthest it scrolls: the summary's last line just clear of the field, never further.
    private func maxScroll(inset: Double) -> Double { max(0, contentEnd(inset: inset)+inset-height) }

    private func layOutContent(inset: Double) {
        let scrolls = revealT != nil && mode == .card
        let contentHeight = scrolls ? max(height-inset, contentEnd(inset: inset)) : height
        if content.bounds.height != contentHeight {
            content.frame = CGRect(x: 0, y: 0, width: size.width, height: contentHeight)
            scroll.contentSize = content.bounds.size
        }
    }

    private func renderBackdrop(_ t: Double) {
        let a = orbitAngle(t), w = width, h = height
        // The measured paths: the cool glow circles wide, the warm one opposite and flatter.
        coolGlow.position = CGPoint(x: (0.5+0.34*cos(a))*w, y: (0.41+0.22*sin(a))*h)
        warmGlow.position = CGPoint(x: (0.5+0.31*cos(a+Double.pi))*w, y: (0.44+0.11*sin(a+Double.pi))*h)
        var coolAlpha = 1.0, warmAlpha = 1.0
        if let revealT, mode == .card {
            coolAlpha = lerp(1, M.coolGlowRest, easeOut((t-revealT)/M.settle, 1))
            warmAlpha = 1-easeOut((t-revealT)/M.warmGlowFade, 0.6)
        }
        coolGlow.opacity = Float(coolAlpha); warmGlow.opacity = Float(warmAlpha)
    }

    /// Drawn once, as blurring them takes a moment: early, so the first summary doesn't wait.
    static func prepareGlows() { _ = coolGlowImage; _ = warmGlowImage }
    // Sampled from Assets/AppIcon/Rise.icon/Assets/Rise.png: mint/blue and cream/blush.
    private static let coolGlowImage = glow(size: M.coolGlowSize, inner: (197, 242, 239), outer: (206, 231, 251))
    private static let warmGlowImage = glow(size: M.warmGlowSize, inner: (254, 234, 202), outer: (254, 208, 232))

    /// A soft elliptical glow, as `radial-gradient(closest-side, …)` under `blur(40px)` in the playground.
    private static func glow(size: Double, inner: (Double, Double, Double), outer: (Double, Double, Double)) -> CGImage? {
        let blur = M.glowBlur, margin = 3*blur
        let canvas = CGSize(width: size+2*margin, height: size*0.85+2*margin)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let shape = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            let c = context.cgContext
            let rgb = { (color: (Double, Double, Double), alpha: Double) in
                CGColor(srgbRed: color.0/255, green: color.1/255, blue: color.2/255, alpha: alpha*0.55)
            }
            // Fading the outer colour itself out, as browsers blend premultiplied.
            let colors = [rgb(inner, 1), rgb(inner, 1), rgb(outer, 0.7), rgb(outer, 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                            locations: [0, 0.28, 0.62, 1]) else { return }
            c.translateBy(x: canvas.width/2, y: canvas.height/2)
            c.scaleBy(x: 1, y: 0.85)
            c.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: size/2, options: [])
        }
        guard let input = CIImage(image: shape) else { return nil }
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: input.extent)
        return glowContext.createCGImage(blurred, from: input.extent)
    }
    private static let glowContext = CIContext()
}

/// How far into the reveal the summary is, for its blocks.
@Observable final class SummaryReveal {
    var summary: PageSummary?
    /// Seconds since the reveal; negative before it.
    var elapsed = -1.0
    var reducesMotion = false
    /// Questions asked under the summary, in turn.
    var followUps: [SummaryFollowUp] = []
    var blockCount: Int { summary?.paragraphs.count ?? 0 }
}

/// A question asked under the summary, and its answer once it comes.
@Observable final class SummaryFollowUp {
    let question: String
    /// Its text's size in the bubble, as its flying copy was drawn.
    let textSize: CGSize
    var answer: [String]?
    /// Seconds since the answer's reveal; negative before it.
    var elapsed = -1.0
    /// Its copy is still flying to the bubble, which waits hidden in its place.
    var flying = false
    /// The bubble's top in the summary's content.
    var bubbleTop = 0.0
    init(question: String, textSize: CGSize) { self.question = question; self.textSize = textSize }
}

/// The summary's two paragraphs, then each follow-up's question and answer. Each paragraph fades
/// in from a heavy blur, a little after the one before.
struct SummaryBlocks: View {
    let reveal: SummaryReveal
    static let font = UIFont.systemFont(ofSize: 17)
    /// 22-point lines.
    static let lineSpacing = 22-font.lineHeight
    static let ink = Color(red: 28/255, green: 28/255, blue: 30/255)
    static let sideSpacing: CGFloat = 24
    static let paragraphSpacing: CGFloat = 18
    static let endSpacing: CGFloat = 64
    /// Between a question's bubble, which sits a paragraph's spacing under the text before it, and its answer.
    static let questionSpacing: CGFloat = 24

    /// Below the last paragraph's text.
    static var trailingSpace: Double { Double(endSpacing+paragraphSpacing) }

    var body: some View {
        if let summary = reveal.summary {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(summary.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    SummaryParagraph(text: paragraph)
                        .modifier(BlockReveal(reveal: reveal, followUp: nil, index: index))
                        .padding(.bottom, Self.paragraphSpacing)
                }
                ForEach(reveal.followUps.indices, id: \.self) { index in
                    FollowUpBlocks(reveal: reveal, followUp: reveal.followUps[index])
                }
            }
            .padding(.horizontal, Self.sideSpacing)
            .padding(.bottom, Self.endSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SummaryParagraph: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font(SummaryBlocks.font))
            .lineSpacing(SummaryBlocks.lineSpacing)
            .foregroundStyle(SummaryBlocks.ink.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A question in its blue bubble on the right, shimmering as in Find's Ask until its answer comes,
/// then the answer revealed under it as the summary was.
private struct FollowUpBlocks: View {
    let reveal: SummaryReveal
    let followUp: SummaryFollowUp

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                QuestionText(question: followUp.question, asking: followUp.answer == nil, reducesMotion: reveal.reducesMotion)
                    // As its flying copy was drawn, so it lands on the same lines.
                    .frame(width: followUp.textSize.width, height: followUp.textSize.height, alignment: .topLeading)
                    .padding(.horizontal, SendBubble.horizontalPadding)
                    .padding(.vertical, SendBubble.verticalPadding)
                    .background(Color(SendBubble.fill), in: RoundedRectangle(cornerRadius: SendBubble.radius, style: .continuous))
                    .opacity(followUp.flying ? 0 : 1)
            }
            // Out past the paragraphs' edge, to `SendBubble.edgeInset` from the screen's.
            .padding(.trailing, SendBubble.edgeInset-SummaryBlocks.sideSpacing)
            .padding(.bottom, SummaryBlocks.questionSpacing)
            if let answer = followUp.answer {
                ForEach(Array(answer.enumerated()), id: \.offset) { index, paragraph in
                    SummaryParagraph(text: paragraph)
                        .modifier(BlockReveal(reveal: reveal, followUp: followUp, index: index))
                        .padding(.bottom, SummaryBlocks.paragraphSpacing)
                }
            }
        }
    }
}

/// The bubble's blue, with a deeper band sweeping across its glyphs once a second while it's being answered.
private struct QuestionText: View {
    let question: String
    let asking: Bool
    let reducesMotion: Bool
    private static let band = 80.0
    private static let shimmer = Color(SendBubble.shimmer)

    private var text: some View { SendBubble.text(question) }

    var body: some View {
        text
            .foregroundStyle(Color(SendBubble.ink))
            .overlay {
                TimelineView(.animation(paused: !asking || reducesMotion)) { context in
                    GeometryReader { geometry in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                        LinearGradient(colors: [Self.shimmer.opacity(0), Self.shimmer, Self.shimmer.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.band)
                            .offset(x: -Self.band+phase*(geometry.size.width+Self.band))
                    }
                }
                .mask(text)
                // Only its opacity eases out as the answer comes. Animating the whole overlay also
                // moved it with the answer's layout landing under the bubble: a clipped copy of
                // the question, the band's, slid up from there as it faded.
                .animation(.easeOut(duration: 0.15)) { $0.opacity(asking && !reducesMotion ? 1 : 0) }
                .accessibilityHidden(true)
            }
    }
}

/// Fades in and sharpens from `textBlur`, each with its own time constant, after the blocks before.
private struct BlockReveal: ViewModifier {
    let reveal: SummaryReveal
    let followUp: SummaryFollowUp?
    let index: Int

    func body(content: Content) -> some View {
        let t = (followUp?.elapsed ?? reveal.elapsed)-SummariseMotion.textDelay-Double(index)*SummariseMotion.stagger
        let opacity = t <= 0 ? 0 : 1-exp(-t/SummariseMotion.fadeTau)
        let blur = reveal.reducesMotion ? 0 : t <= 0 ? SummariseMotion.textBlur : SummariseMotion.textBlur*exp(-t/SummariseMotion.blurTau)
        content
            .opacity(opacity)
            .blur(radius: blur > 0.05 ? blur : 0)
    }
}
