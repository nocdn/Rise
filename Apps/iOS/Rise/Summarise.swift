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
    // pinch's own for its size, and how soon after it's let go the summary it had shows again.
    static let grabBlend = SummariseSpring(2*Double.pi/0.3, 1)
    static let reshow = 0.5

    // Pulled on past the summary's end, a follow-up field rises out of the bottom of the screen,
    // small at first and growing, a light tick every `followUpTick` points of the pull. At
    // `followUpPull` (the overscroll as shown, after UIKit's rubber band) it clicks, lets go of the
    // finger, and springs to full width under the last paragraph as the keyboard comes up.
    static let followUpPull = 96.0
    static let followUpTick = 12.0
    /// It rises this many times as fast as the summary, so it comes out from under the screen's edge.
    static let followUpLead = 1.4
    static let followUpPullScale = (from: 0.5, to: 0.8)
    static let followUpHeight = 48.0
    /// From the last paragraph's text to the field's top.
    static let followUpGap = 12.0
    /// Clicked, it flies up into place, then slides to the side as its text lines up with the paragraphs.
    static let followUpPlace = SummariseSpring(15, 0.6)
    static let followUpSlide = SummariseSpring(12, 0.85)
    static let followUpSlideDelay = 0.06
    /// The summary scrolls up to keep it above the keyboard.
    static let followUpScroll = SummariseSpring(14, 1)
    /// Between the field and the keyboard.
    static let followUpKeyboardGap = 16.0
    /// An answer scrolls into sight with its question at least this far down the screen.
    static let followUpAnswerTop = 110.0
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
            let c2 = (v0+r1)/(r1-r2), c1 = -1-c2
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
    /// Answers a question asked under the summary, after the ones before it.
    var answerFollowUp: (@MainActor (_ question: String, _ summary: PageSummary, _ history: [PageAssistant.Turn]) async throws -> [String])?
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
    /// The follow-up field under the summary, pulled out of the bottom of the screen.
    private let followUp = UITextField()
    /// Clicked into place: when, and where it was in the content as it clicked.
    private var followUpPlaced: (t0: Double, pose: FollowUpPose)?
    /// The field's text's middle, from its left, and its scale.
    private struct FollowUpPose { var centerY: Double, left: Double, scale: Double }
    /// Asking the model about a question sent from the field, and when its answer was revealed.
    private var followUpTask: Task<Void, Never>?
    private var followUpReveals: [(followUp: SummaryFollowUp, t0: Double)] = []
    private var followUpStep = 0
    /// The summary scrolling to keep the field above the keyboard, which a touch takes over.
    private var followUpScroll: (from: Double, to: Double, velocity: Double, t0: Double)?
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
        // Short summaries can still be pulled past their end, for the follow-up field.
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
        followUp.isHidden = true
        followUp.isUserInteractionEnabled = false
        followUp.delegate = self
        // Pulled out, it grows from its text's left.
        followUp.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        setFollowUpPlaceholder(Self.pullPlaceholder)
        content.addSubview(followUp)
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
        cardElement.accessibilityLabel = title
        cardElement.accessibilityHint = "Returns to the page."
        cardElement.accessibilityTraits = .button
        scroll.accessibilityElements = [cardElement, summaryHost.view!, followUp]

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
        // Over the summary's bottom padding, where it settles, so it takes the taps there.
        content.addSubview(followUp)
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
        swingT0 = nil; closeT = nil; revealT = nil; pendingReveal = nil
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
        guard task == nil, let makeSummary else { return }
        // Caught on its way back, it shows the summary it had again once it has landed.
        if reveal.summary != nil, !summaryFailed { readyT = tick()+M.reshow; log?.event("summary again"); return }
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
        let crop = velocity == nil ? M.menuCrop : M.placeCrop
        tween(.cropTop, to: M.cropTop, .spring(crop), t)
        tween(.cropH, to: cardHeight, .spring(crop), t)
        tween(.radius, to: M.cardRadius, .spring(crop), t)
        tween(.rotation, to: M.restTilt, .spring(crop), t)
        if let velocity {
            tweens[.scale] = Tween(from: value(.scale, t), to: M.loadScale, t0: t, curve: .release(M.releaseScale, velocity: velocity.scale))
            tweens[.x] = Tween(from: value(.x, t), to: 0, t0: t, curve: .release(M.releaseMove, velocity: velocity.x))
            tweens[.top] = Tween(from: value(.top, t), to: M.loadTop, t0: t, curve: .release(M.releaseMove, velocity: velocity.top))
        } else {
            tween(.scale, to: M.loadScale, .spring(M.menuShrink), t)
            tween(.x, to: 0, .spring(M.menuShrink), t)
            tween(.top, to: M.loadTop, .spring(M.menuShrink), t)
        }
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
        // The glows carry on to the left, then stop there.
        let a = orbitAngle(t), turn = 2*Double.pi
        orbitStop = (t, a, Double.pi+turn*ceil((a-Double.pi+1e-6)/turn))
        stopHum()
        playRevealHaptic()
        // Shown again after being caught, it starts afresh without the questions asked before.
        if !reveal.followUps.isEmpty { reveal.followUps = []; followUpReveals = []; measureSummary() }
        resetFollowUp()
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
        followUpScroll = nil
        followUpTask?.cancel(); followUpTask = nil
        followUp.isUserInteractionEnabled = false
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

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        if cardArea.contains(tap.location(in: content)) { close() }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { mode == .card }

    // MARK: The follow-up field

    private static let pullPlaceholder = "Keep pulling to ask follow-up"
    private static let askPlaceholder = "Ask follow up about page"
    private static let pullPlaceholderWidth = Double((pullPlaceholder as NSString).size(withAttributes: [.font: SummaryBlocks.font]).width)

    private func setFollowUpPlaceholder(_ text: String) {
        followUp.attributedPlaceholder = NSAttributedString(string: text, attributes: [
            .font: SummaryBlocks.font,
            .foregroundColor: UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 0.35),
        ])
    }

    /// Back under the bottom of the screen, to be pulled out again.
    private func resetFollowUp() {
        followUpPlaced = nil; followUpStep = 0
        followUp.text = nil
        followUp.isUserInteractionEnabled = false
        setFollowUpPlaceholder(Self.pullPlaceholder)
    }

    /// The furthest the summary scrolls.
    private var scrollEnd: Double { max(0, Double(scroll.contentSize.height+scroll.contentInset.bottom)-height) }

    /// How far the summary is pulled past its end, as it shows.
    private var pulledPast: Double { Double(scroll.contentOffset.y)-scrollEnd }

    /// Where the field settles in the content: under the last paragraph, its text lined up with theirs.
    private var followUpRest: FollowUpPose {
        FollowUpPose(centerY: summaryTop+Double(summaryHeight)-SummaryBlocks.trailingSpace+M.followUpGap+M.followUpHeight/2,
                     left: Double(SummaryBlocks.sideSpacing), scale: 1)
    }

    /// The field pulled this far: its text rising out of the middle of the bottom of the screen a
    /// little ahead of the summary, and growing as it does.
    private func pullPose(_ pulled: Double) -> FollowUpPose {
        let scale = lerp(M.followUpPullScale.from, M.followUpPullScale.to, easeOut(pulled/M.followUpPull, 0.5))
        let onScreen = height+M.followUpHeight*scale/2-M.followUpLead*pulled
        return FollowUpPose(centerY: Double(scroll.contentOffset.y)+onScreen, left: (width-Self.pullPlaceholderWidth*scale)/2, scale: scale)
    }

    /// Clicked: up into place and to full size, then across to the paragraphs' edge a moment later.
    private func placedPose(_ placed: (t0: Double, pose: FollowUpPose), _ t: Double) -> FollowUpPose {
        let rest = followUpRest, elapsed = t-placed.t0
        return FollowUpPose(centerY: M.followUpPlace.value(from: placed.pose.centerY, to: rest.centerY, velocity: 0, at: elapsed),
                            left: M.followUpSlide.value(from: placed.pose.left, to: rest.left, velocity: 0, at: elapsed-M.followUpSlideDelay),
                            scale: M.followUpPlace.value(from: placed.pose.scale, to: rest.scale, velocity: 0, at: elapsed))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard mode == .card, revealT != nil, followUpPlaced == nil, followUpTask == nil else { return }
        let pulled = pulledPast
        let step = pulled > 0 ? Int(pulled/M.followUpTick) : 0
        if scroll.isTracking, pulled >= M.followUpPull {
            placeFollowUp()
            return
        }
        // Light ticks on the way out, a little firmer as it nears the click.
        if step > followUpStep, scroll.isTracking {
            let near = Float(clamp(pulled/M.followUpPull))
            playTransient(intensity: 0.25+0.2*near, sharpness: 0.45)
        }
        followUpStep = step
        renderFollowUp(tick(), fadingOut: 0)
    }

    /// Pulled far enough: it clicks, lets go of the finger, and flies into place under the last
    /// paragraph as the keyboard comes up.
    private func placeFollowUp() {
        let t = tick()
        followUpPlaced = (t, pullPose(pulledPast))
        log?.event("follow-up")
        playTransient(intensity: 1, sharpness: 0.7)
        // Ending the drag starts the scroll view's own bounce back, which the field's scroll replaces.
        scroll.panGestureRecognizer.isEnabled = false
        scroll.panGestureRecognizer.isEnabled = true
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        UIView.transition(with: followUp, duration: 0.18, options: .transitionCrossDissolve) {
            self.setFollowUpPlaceholder(Self.askPlaceholder)
        }
        followUp.isUserInteractionEnabled = true
        // Makes room for it in the content, then scrolls to it; the keyboard moves that on.
        render(t)
        scrollToFollowUp(t)
        followUp.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendFollowUp()
        return false
    }

    /// The question takes the field's place in the summary, shimmering, while the model answers
    /// it to the summary's hum.
    private func sendFollowUp() {
        let question = (followUp.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .card, followUpTask == nil, !question.isEmpty, let summary = reveal.summary, let answerFollowUp else { return }
        let t = tick()
        log?.event("follow-up asked")
        let history = reveal.followUps.compactMap { asked in
            asked.answer.map { PageAssistant.Turn(question: asked.question, answer: $0.joined(separator: "\n\n")) }
        }
        let asked = SummaryFollowUp(question: question)
        let questionTop = followUpRest.centerY-M.followUpHeight/2
        followUpPlaced = nil
        followUp.text = nil
        followUp.isUserInteractionEnabled = false
        followUp.isHidden = true
        followUp.resignFirstResponder()
        reveal.followUps.append(asked)
        measureSummary()
        render(t)
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
            followUpAnswered(asked, answer, questionTop: questionTop)
        }
    }

    /// The answer fades in and sharpens under its question as the summary did, with the same thud,
    /// and the field can be pulled out again under it.
    private func followUpAnswered(_ asked: SummaryFollowUp, _ answer: [String], questionTop: Double) {
        guard mode == .card, reveal.followUps.contains(where: { $0 === asked }) else { return }
        let t = tick()
        log?.event("follow-up answered")
        followUpTask = nil
        asked.answer = answer
        measureSummary()
        followUpReveals.append((asked, t))
        stopHum()
        playRevealHaptic()
        resetFollowUp()
        render(t)
        // Brings the answer into sight, keeping its question on screen.
        let target = min(scrollEnd, questionTop-M.followUpAnswerTop)
        if !scroll.isTracking, target > Double(scroll.contentOffset.y) { scroll(to: target, t) }
    }

    private func stepFollowUpReveals(_ t: Double) {
        followUpReveals.removeAll { asked, t0 in
            let elapsed = t-t0
            let settled = M.textDelay+M.stagger*Double(asked.answer?.count ?? 0)+6*max(M.blurTau, M.fadeTau)
            asked.elapsed = elapsed > settled ? .infinity : elapsed
            return elapsed > settled
        }
    }

    /// Scrolls to the end, where the field is.
    private func scrollToFollowUp(_ t: Double, onlyBack: Bool = false) {
        scroll(to: onlyBack ? min(Double(scroll.contentOffset.y), scrollEnd) : scrollEnd, t)
    }

    /// Scrolls on a spring, carrying on at the speed it's scrolling already.
    private func scroll(to target: Double, _ t: Double) {
        let current = Double(scroll.contentOffset.y)
        var velocity = 0.0
        if let scrolling = followUpScroll {
            let at = { M.followUpScroll.value(from: scrolling.from, to: scrolling.to, velocity: scrolling.velocity, at: $0-scrolling.t0) }
            velocity = (at(t)-at(t-1/240.0))*240
        }
        guard target != current || velocity != 0 else { followUpScroll = nil; return }
        followUpScroll = (current, target, velocity, t)
    }

    private func stepFollowUpScroll(_ t: Double) {
        guard let scrolling = followUpScroll else { return }
        if scroll.isTracking { followUpScroll = nil; return }
        let spring = M.followUpScroll
        scroll.contentOffset.y = CGFloat(spring.value(from: scrolling.from, to: scrolling.to, velocity: scrolling.velocity, at: t-scrolling.t0))
        if t-scrolling.t0 > 7/(spring.w*spring.z) { followUpScroll = nil }
    }

    /// The summary makes room for the keyboard under the field, and scrolls to keep it in sight.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard mode == .card, let screen = window?.screen,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let frame = convert(end, from: screen.coordinateSpace)
        keyboardHeight = frame.minY < bounds.maxY ? Double(bounds.maxY-frame.minY) : 0
        scroll.contentInset.bottom = CGFloat(max(0, keyboardHeight-(Double(SummaryBlocks.endSpacing)-M.followUpKeyboardGap)))
        guard !scroll.isDragging, !scroll.isDecelerating else { return }
        scrollToFollowUp(tick(), onlyBack: !followUp.isFirstResponder || keyboardHeight == 0)
    }

    private func renderFollowUp(_ t: Double, fadingOut: Double) {
        guard revealT != nil, mode == .card || (mode == .closing && followUpPlaced != nil) else { followUp.isHidden = true; return }
        let pose: FollowUpPose
        if let placed = followUpPlaced {
            pose = placedPose(placed, t)
        } else {
            let pulled = pulledPast
            guard pulled > 0, followUpTask == nil else { followUp.isHidden = true; return }
            pose = pullPose(pulled)
        }
        followUp.isHidden = false
        followUp.bounds = CGRect(x: 0, y: 0, width: width-2*Double(SummaryBlocks.sideSpacing), height: M.followUpHeight)
        followUp.center = CGPoint(x: pose.left, y: pose.centerY)
        var transform = CGAffineTransform(scaleX: pose.scale, y: pose.scale)
        if mode == .closing {
            // Sinks back with the summary, about the middle of the screen.
            let recede = closeRecede(t)
            let x = width/2+recede*(pose.left-width/2), y = height/2+recede*(pose.centerY-closeScroll-height/2)
            transform = CGAffineTransform(a: pose.scale*recede, b: 0, c: 0, d: pose.scale*recede, tx: x-pose.left, ty: y-pose.centerY)
        }
        followUp.transform = transform
        followUp.alpha = 1-fadingOut
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
            stepFollowUpScroll(t)
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
        if mode == .closing {
            let recede = closeRecede(t)
            // Scaled about the middle of the screen, from where it showed when the card was tapped.
            let dy = (1-recede)*(height/2-Double(view.center.y))-recede*closeScroll
            view.transform = CGAffineTransform(a: recede, b: 0, c: 0, d: recede, tx: 0, ty: dy)
        } else {
            view.transform = .identity
        }
        view.alpha = 1-fadingOut
        let elapsed = revealed ? t-(revealT ?? t) : -1
        // Past the last block's settling, it stays as it is.
        let settled = M.textDelay+M.stagger*Double(reveal.blockCount)+6*max(M.blurTau, M.fadeTau)
        let shown = elapsed > settled ? Double.infinity : elapsed
        if reveal.elapsed != shown { reveal.elapsed = shown; reveal.reducesMotion = reducesMotion }
        let scrolls = revealed && mode == .card
        scroll.isScrollEnabled = scrolls
        let end = followUpPlaced == nil ? summaryTop+summaryHeight : followUpRest.centerY+M.followUpHeight/2+SummaryBlocks.endSpacing
        let contentHeight = scrolls ? max(size.height, end) : size.height
        if content.bounds.height != contentHeight {
            content.frame = CGRect(x: 0, y: 0, width: size.width, height: contentHeight)
            scroll.contentSize = content.bounds.size
        }
        renderFollowUp(t, fadingOut: fadingOut)
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
    var answer: [String]?
    /// Seconds since the answer's reveal; negative before it.
    var elapsed = -1.0
    init(question: String) { self.question = question }
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
    /// Above a question, so its text sits where the follow-up field's did.
    static let questionLead = CGFloat(SummariseMotion.followUpGap+(SummariseMotion.followUpHeight-font.lineHeight)/2)-paragraphSpacing
    static let questionSpacing: CGFloat = 14

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

/// A question, shimmering as in Find's Ask until its answer comes, then the answer revealed as the summary was.
private struct FollowUpBlocks: View {
    let reveal: SummaryReveal
    let followUp: SummaryFollowUp

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuestionText(question: followUp.question, asking: followUp.answer == nil, reducesMotion: reveal.reducesMotion)
                .padding(.top, SummaryBlocks.questionLead)
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

/// Muted, with a dark band sweeping across its glyphs once a second while it's being answered.
private struct QuestionText: View {
    let question: String
    let asking: Bool
    let reducesMotion: Bool
    private static let band = 80.0

    private var text: some View {
        Text(question)
            .font(Font(SummaryBlocks.font))
            .lineSpacing(SummaryBlocks.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        text
            .foregroundStyle(SummaryBlocks.ink.opacity(0.5))
            .overlay {
                TimelineView(.animation(paused: !asking || reducesMotion)) { context in
                    GeometryReader { geometry in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                        LinearGradient(colors: [SummaryBlocks.ink.opacity(0), SummaryBlocks.ink, SummaryBlocks.ink.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.band)
                            .offset(x: -Self.band+phase*(geometry.size.width+Self.band))
                    }
                }
                .mask(text)
                .opacity(asking && !reducesMotion ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: asking)
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
