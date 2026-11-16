import UIKit
import CoreImage

/// TextKit keeps selection and line breaks native; the desktop scheduler colors each arriving word.
final class AskAnswerView: UITextView {
    private let tokenLayout = AskTokenLayout()
    private var stream = TokenStream()
    private var link: CADisplayLink?
    private lazy var ticker = FrameTicker { [weak self] in self?.tick() }
    private var notifiedHeight: CGFloat = 0
    var onHeightChanged: (() -> Void)?
    private(set) var answer = ""
    /// The text's size, scaled with Dynamic Type; Find's answers are 15 points.
    var fontSize: CGFloat = 15
    /// How far each word slides in from as it arrives; 0 has it fade and sharpen where it lands.
    var entranceTravel: CGFloat {
        get { tokenLayout.travel }
        set { tokenLayout.travel = newValue }
    }

    init() {
        let storage = NSTextStorage(), container = NSTextContainer(size: .zero)
        storage.addLayoutManager(tokenLayout)
        tokenLayout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        backgroundColor = .clear
        isEditable = false
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        accessibilityLabel = "Page answer"
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        link?.invalidate(); link = nil
        stream = TokenStream(); answer = ""; text = ""
        tokenLayout.entrances = []
        notifiedHeight = 0
        onHeightChanged?()
    }

    func show(_ answer: String, finished: Bool = false) {
        self.answer = answer
        stream.receive(answer)
        if finished { stream.finish() }
        let color = UIColor.label.resolvedColor(with: traitCollection)
        stream.base = OKLab(color)
        textStorage.setAttributedString(Self.styled(stream.text, color: color, size: fontSize))
        // The view that draws the text grows to the new text now, at once: left for the next
        // layout, it grew inside the sheet's own growth animation, from its old size, cutting
        // off the newest lines until it caught up.
        UIView.performWithoutAnimation { layoutIfNeeded() }
        stream.place(in: text as NSString, at: CACurrentMediaTime())
        if UIAccessibility.isReduceMotionEnabled { stream.revealAll(at: CACurrentMediaTime()) }
        paint()
        notifyHeightChange()
        if stream.needsFrames, link == nil, window != nil {
            let display = CADisplayLink(target: ticker, selector: #selector(FrameTicker.tick))
            display.add(to: .main, forMode: .common); link = display
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { link?.invalidate(); link = nil }
    }

    /// Measure the last revealed line in the complete layout, so queued words keep their
    /// wrapping but do not reserve space in the sheet before they become visible.
    /// Measuring lays out more of the text, which resizes the view drawing it: never animated,
    /// though a sheet growing to fit measures it inside its own animation, as that view would
    /// otherwise grow from its old size, cutting off the newest lines until it caught up.
    func revealedHeight(for width: CGFloat) -> CGFloat {
        guard width > 0, let newest = stream.newest, NSMaxRange(newest) <= textStorage.length else { return 0 }
        var height: CGFloat = 0
        UIView.performWithoutAnimation {
            let size = CGSize(width: width, height: .greatestFiniteMagnitude)
            if textContainer.size != size { textContainer.size = size }
            tokenLayout.ensureLayout(forCharacterRange: newest)
            let glyphs = tokenLayout.glyphRange(forCharacterRange: newest, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            height = ceil(tokenLayout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs)-1, effectiveRange: nil).maxY)
            layoutIfNeeded()
        }
        return height
    }

    private func notifyHeightChange() {
        let height = revealedHeight(for: bounds.width)
        guard height != notifiedHeight else { return }
        notifiedHeight = height
        onHeightChanged?()
    }

    private func tick() { advance(at: CACurrentMediaTime()) }

    /// Both display frames and deterministic motion checks use the same reveal clock.
    func advance(at time: CFTimeInterval) {
        _ = stream.step(at: time)
        if UIAccessibility.isReduceMotionEnabled { stream.revealAll(at: time) }
        paint()
        notifyHeightChange()
        if let newest = stream.newest { scrollRangeToVisible(newest) }
        if !stream.needsFrames { link?.invalidate(); link = nil }
    }

    private func paint() {
        let all = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: UIColor.label, range: all)
        if let hidden = stream.hiddenFrom, hidden < all.length {
            textStorage.addAttribute(.foregroundColor, value: UIColor.clear,
                range: NSRange(location: hidden, length: all.length-hidden))
        }
        for tint in stream.tints where NSMaxRange(tint.range) <= all.length {
            textStorage.addAttribute(.foregroundColor, value: tint.color.color, range: tint.range)
        }
        textStorage.endEditing()
        tokenLayout.reducesMotion = UIAccessibility.isReduceMotionEnabled
        tokenLayout.displayScale = traitCollection.displayScale
        tokenLayout.entrances = stream.entrances
        setNeedsDisplay()
    }

    private static func styled(_ text: String, color: UIColor, size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                               failurePolicy: .returnPartiallyParsedIfPossible)
        guard let markdown = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: size)),
                                                                  .foregroundColor: color])
        }
        for run in markdown.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = UIFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.emphasized), let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            if intent.contains(.code) { font = .monospacedSystemFont(ofSize: size-1, weight: .regular) }
            var attributes: [NSAttributedString.Key: Any] = [.font: UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: font),
                .foregroundColor: color, .paragraphStyle: paragraph]
            if let url = run.link { attributes[.link] = url }
            result.append(NSAttributedString(string: String(markdown[run.range].characters), attributes: attributes))
        }
        return result
    }
}

/// A weak callback target avoids a display link retaining its answer view after the sheet closes.
@MainActor final class FrameTicker: NSObject {
    private let frame: () -> Void
    init(_ frame: @escaping () -> Void) { self.frame = frame }
    @objc func tick() { frame() }
}

private final class AskTokenLayout: NSLayoutManager {
    var reducesMotion = false
    var displayScale: CGFloat = 2
    var travel: CGFloat = TokenMotion.travel
    var entrances: [TokenStream.Entrance] = []
    // Created when a token first blurs in: making one costs about 30 ms, which at launch
    // held up the browser for every panel built with an answer view.
    private lazy var imageContext = CIContext(options: [.cacheIntermediates: false])

    override func drawGlyphs(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard !reducesMotion, !entrances.isEmpty else {
            super.drawGlyphs(forGlyphRange: range, at: origin); return
        }
        var cursor = range.location
        for effect in entrances.reversed() {
            guard NSMaxRange(effect.range) <= (textStorage?.length ?? 0) else { continue }
            let glyphs = NSIntersectionRange(range, glyphRange(forCharacterRange: effect.range, actualCharacterRange: nil))
            guard glyphs.length > 0 else { continue }
            if cursor < glyphs.location {
                super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: glyphs.location-cursor), at: origin)
            }
            drawEntrance(glyphs, origin: origin, progress: effect.progress)
            cursor = NSMaxRange(glyphs)
        }
        if cursor < NSMaxRange(range) {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: NSMaxRange(range)-cursor), at: origin)
        }
    }

    private func drawEntrance(_ glyphs: NSRange, origin: CGPoint, progress: Double) {
        guard let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
        let rect = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -4)
        guard rect.width > 0, rect.height > 0 else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = displayScale
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            super.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: origin.x-rect.minX, y: origin.y-rect.minY))
        }
        guard let source = image.cgImage else { return }
        let input = CIImage(cgImage: source)
        let blur = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: TokenMotion.blur*(1-progress)*format.scale])
        if let output = imageContext.createCGImage(blur, from: input.extent) {
            UIImage(cgImage: output, scale: format.scale, orientation: .up)
                .draw(in: rect.offsetBy(dx: travel*(1-progress), dy: 0))
        } else { image.draw(in: rect) }
    }
}
