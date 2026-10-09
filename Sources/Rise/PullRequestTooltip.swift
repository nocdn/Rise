import AppKit

/// Kumo's SkeletonLine: an 8 pt bar with a soft band sweeping across it, each line at its
/// own random width, pace and start, so a stack of them never moves in lockstep.
final class SkeletonLine: NSView {
    static let height: CGFloat = 8
    private let shimmer = CAGradientLayer()
    let widthFraction = CGFloat.random(in: 0.3...1)
    private let duration = Double.random(in: 1.3...1.7), delay = Double.random(in: 0...0.5)
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 2; layer?.masksToBounds = true
        shimmer.startPoint = CGPoint(x: 0, y: 0.5); shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(shimmer)
        applyTheme(dark: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyTheme(dark: Bool) {
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor(hex: 0xF3F4F6)).cgColor
        let band = dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.08)
        shimmer.colors = [band.withAlphaComponent(0), band, band.withAlphaComponent(0)].map(\.cgColor)
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shimmer.frame = bounds
        CATransaction.commit()
        restart()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restart() }
    override func viewDidUnhide() { super.viewDidUnhide(); restart() }
    /// `translateX(-100%)` to `translateX(100%)`, ease-in-out, forever, after the line's delay.
    private func restart() {
        shimmer.removeAllAnimations()
        guard window != nil, !isHiddenOrHasHiddenAncestor, bounds.width > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -bounds.width; sweep.toValue = bounds.width
        sweep.duration = duration; sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.beginTime = shimmer.convertTime(CACurrentMediaTime(), from: nil)+delay
        shimmer.add(sweep, forKey: "shimmer")
    }
}

/// GitHub's colors for a pull request's status and diff size, in light and dark.
enum PullRequestPalette {
    /// Each pill is one saturated color at low opacity. Over the light card it lands on the
    /// soft tints the pills were designed with; over the dark card the same values give a
    /// matching dark tint.
    static func tint(_ state: PullRequestDetails.State) -> (color: NSColor, opacity: CGFloat) {
        switch state {
        case .open: return (NSColor(hex: 0x6CFFA7), 0.12)   // #E9FBF0 over #FAFAFA
        case .closed: return (NSColor(hex: 0xFF895A), 0.15) // #FBE9E2, for #FFE9E2
        case .merged: return (NSColor(hex: 0xAAA3FF), 0.15) // #EEEDFB, for #EEEDFF
        case .draft: return (NSColor(hex: 0x8C959F), 0.18)
        }
    }
    static func badge(_ state: PullRequestDetails.State, dark: Bool) -> NSColor {
        let tint = tint(state)
        return tint.color.withAlphaComponent(tint.opacity)
    }
    /// Deep text on the light tints. On the dark ones deep text would all but vanish
    /// (contrast under 2), so the pill's own color is the text there.
    static func badgeText(_ state: PullRequestDetails.State, dark: Bool) -> NSColor {
        if dark { return state == .draft ? NSColor(hex: 0xAEB6BE) : tint(state).color }
        switch state {
        case .open: return NSColor(hex: 0x017C1E)
        case .merged: return NSColor(hex: 0x634BBE)
        case .closed: return NSColor(hex: 0xB02F07)
        case .draft: return NSColor(hex: 0x59636E)
        }
    }
    static func added(dark: Bool) -> NSColor { NSColor(hex: dark ? 0x3FB950 : 0x1A7F37) }
    static func deleted(dark: Bool) -> NSColor { NSColor(hex: dark ? 0xF85149 : 0xD1242F) }
    static func emptyBlock(dark: Bool) -> NSColor { dark ? NSColor.white.withAlphaComponent(0.14) : NSColor(hex: 0xD1D9E0) }
    /// GitHub's five diff squares: the real counts when fewer than five lines changed,
    /// otherwise the share of additions and deletions, each kept visible when present.
    static func blocks(additions: Int, deletions: Int) -> (added: Int, deleted: Int) {
        let total = additions+deletions
        guard total > 0 else { return (0, 0) }
        if total < 5 { return (additions, deletions) }
        var added = min(5, max(additions > 0 ? 1 : 0, Int((Double(additions)/Double(total)*5).rounded())))
        var deleted = 5-added
        if deletions > 0 && deleted == 0 { added -= 1; deleted = 1 }
        return (added, deleted)
    }
}

extension PullRequestDetails.State {
    var title: String {
        switch self { case .open: "Open"; case .draft: "Draft"; case .merged: "Merged"; case .closed: "Closed" }
    }
    /// Tabler's git icons, matching GitHub's own status glyphs.
    var icon: String {
        let nodes = "M4 18a2 2 0 1 0 4 0a2 2 0 1 0 -4 0M4 6a2 2 0 1 0 4 0a2 2 0 1 0 -4 0M16 18a2 2 0 1 0 4 0a2 2 0 1 0 -4 0M6 8v8"
        switch self {
        case .open: return nodes+"M11 6h5a2 2 0 0 1 2 2v8M14 9l-3 -3l3 -3"
        case .draft: return nodes+"M18 11h.01M18 6h.01"
        case .closed: return nodes+"M18 11v5M16 4l4 4m0 -4l-4 4"
        case .merged: return "M5 18a2 2 0 1 0 4 0a2 2 0 1 0 -4 0M5 6a2 2 0 1 0 4 0a2 2 0 1 0 -4 0M15 12a2 2 0 1 0 4 0a2 2 0 1 0 -4 0M7 8v8M7 8a4 4 0 0 0 4 4h4"
        }
    }
}

/// The status badge, the number and file count, lines added and removed, and diff squares.
/// The file count opens the changed files.
final class PullRequestMetaRow: CardLinkRow {
    static let height: CGFloat = 20
    var details: PullRequestDetails? { didSet { needsDisplay = true } }
    /// "#12" on GitHub, "!12" on GitLab.
    var reference = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let details else { placeLink(.zero); return }
        let midY = Self.height/2
        let badgeFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let ink = PullRequestPalette.badgeText(details.state, dark: dark)
        let badgeText = NSAttributedString(string: details.state.title, attributes: [.font: badgeFont, .foregroundColor: ink])
        let iconSize: CGFloat = 12
        let badgeWidth = ceil(7+iconSize+4+badgeText.size().width+8)
        PullRequestPalette.badge(details.state, dark: dark).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: badgeWidth, height: Self.height), xRadius: Self.height/2, yRadius: Self.height/2).fill()
        Self.icon(details.state.icon, size: iconSize, color: ink)
            .draw(in: NSRect(x: 7, y: midY-iconSize/2, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        badgeText.draw(at: NSPoint(x: 7+iconSize+4, y: midY-badgeText.size().height/2))

        // The number and file count sit between the stats' old 12 pt and the title's 14 pt.
        let font = NSFont.systemFont(ofSize: 13), strong = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let files = "\(details.changedFiles) file\(details.changedFiles == 1 ? "" : "s")"
        let added = NSAttributedString(string: "+\(details.additions)", attributes: [.font: strong, .foregroundColor: PullRequestPalette.added(dark: dark)])
        let deleted = NSAttributedString(string: "−\(details.deletions)", attributes: [.font: strong, .foregroundColor: PullRequestPalette.deleted(dark: dark)])
        let blocksWidth: CGFloat = 5*8+4*2
        // The diff size keeps to the right edge. When space runs out, the wording shortens
        // first, then the squares go.
        let number = NSAttributedString(string: "\(reference) · ", attributes: [.font: font, .foregroundColor: muted])
        var link = NSAttributedString(string: "\(files) changed", attributes: [.font: font, .foregroundColor: linkColor])
        func width(blocks: Bool) -> CGFloat { badgeWidth+8+number.size().width+link.size().width+12+added.size().width+4+deleted.size().width+(blocks ? 6+blocksWidth : 0) }
        if width(blocks: true) > bounds.width { link = NSAttributedString(string: files, attributes: [.font: font, .foregroundColor: linkColor]) }
        let showsBlocks = width(blocks: true) <= bounds.width
        number.draw(at: NSPoint(x: badgeWidth+8, y: midY-number.size().height/2))
        let linkX = badgeWidth+8+number.size().width
        link.draw(at: NSPoint(x: linkX, y: midY-link.size().height/2))
        placeLink(NSRect(x: linkX, y: 0, width: ceil(link.size().width), height: Self.height))
        var x = bounds.width-(showsBlocks ? blocksWidth : 0)
        if showsBlocks {
            let blocks = PullRequestPalette.blocks(additions: details.additions, deletions: details.deletions)
            for index in 0..<5 {
                let color = index < blocks.added ? PullRequestPalette.added(dark: dark)
                    : index < blocks.added+blocks.deleted ? PullRequestPalette.deleted(dark: dark) : PullRequestPalette.emptyBlock(dark: dark)
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x+CGFloat(index)*10, y: midY-4, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
            }
            x -= 6
        }
        for (text, gap) in [(deleted, CGFloat(0)), (added, 4)] {
            x -= gap+ceil(text.size().width)
            text.draw(at: NSPoint(x: x, y: midY-text.size().height/2))
        }
    }
    private static func icon(_ data: String, size: CGFloat, color: NSColor) -> NSImage {
        let icon = TablerIcon.image(data, size: size)
        return NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect); color.set(); rect.fill(using: .sourceAtop); return true
        }
    }
}

/// The hover card for a GitHub pull request or GitLab merge request tab: title, status and diff size, then a short
/// description that streams in like the find bar's answers. It shares the find bar's
/// surface, its height spring and its word reveal.
@MainActor final class PullRequestTooltip: FlippedView {
    struct Content {
        var title: String
        var reference: String
        var details: PullRequestDetails?
        var summary: String
        var phase: PullRequestSummaries.Phase
    }
    /// As wide as the find bar, so the status row fits on one line; wider, up to the maximum,
    /// when a merge request's pipeline and merge checks need it to stay on one line too.
    static let width = FindBar.width, maximumWidth: CGFloat = 520
    static let inset = NSSize(width: 14, height: 12)
    static let titleGap: CGFloat = 8, summaryGap: CGFloat = 10, pipelineGap: CGFloat = 10, mergeGap: CGFloat = 6
    /// A pill reads as indented beside plain text; nudging its row left lines the badge up
    /// with the title and description optically.
    static let metaNudge: CGFloat = 3
    static let summaryFont = NSFont.systemFont(ofSize: 13)
    /// A label's cell insets its text by 2 pt; undo that so the title lines up with the description.
    static let labelPadding: CGFloat = 2

    private let panel = Surface(radius: FindBar.radius)
    private let content = FlippedView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let meta = PullRequestMetaRow()
    private let pipelineRow = PipelineRow()
    private let mergeRow = MergeCheckRow()
    private var skeleton = SkeletonLine()
    private let summaryView = TokenTextView()
    private var stream = TokenStream(), paintedFrom = 0, laidOut = ""
    private var height = MotionSpring(0), top = MotionSpring(0)
    private var link: CADisplayLink?, lastTick: CFTimeInterval?
    private var theme = RiseTheme.neutral
    private var current: Content?
    private var anchorTop: CGFloat = 0, maxBottom: CGFloat = 0
    private(set) var key: String?
    /// The pointer went into the card, or left it.
    var onPointer: ((Bool) -> Void)?
    /// The file count was clicked.
    var onOpenFiles: (() -> Void)?
    /// The pipeline's number was clicked.
    var onOpenPipeline: ((Pipeline) -> Void)?
    /// The merge status was clicked.
    var onOpenMergeChecks: (() -> Void)?

    private(set) var cardWidth = PullRequestTooltip.width
    private var textWidth: CGFloat { cardWidth-2*Self.inset.width }
    /// The selected tab's fill in the light themes, a touch lighter than the find bar.
    private var background: NSColor { theme == .dark ? theme.popup : TabAppearance.selectedFill(theme) }
    private var fadedTitle: NSColor { theme.muted.blended(withFraction: 0.2, of: background) ?? theme.muted }
    private var summaryColor: NSColor { theme.text.blended(withFraction: 0.1, of: background) ?? theme.text }
    private var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: Self.summaryFont))+2 }

    init() {
        super.init(frame: .zero)
        isHidden = true
        // The card is exactly the panel's size, so it must not clip the shadow around it.
        wantsLayer = true; layer?.masksToBounds = false; clipsToBounds = false
        panel.layer?.cornerCurve = .continuous; panel.layer?.borderWidth = 0.5
        panel.layer?.shadowColor = NSColor.black.cgColor; panel.layer?.shadowOpacity = 0.12
        panel.layer?.shadowRadius = 10; panel.layer?.shadowOffset = NSSize(width: 0, height: -3)
        // Giving a layer a corner radius turns clipping back on, which would cut the shadow
        // off; the inner content view does the clipping instead.
        panel.clipsToBounds = false
        content.wantsLayer = true; content.layer?.masksToBounds = true
        content.layer?.cornerRadius = FindBar.radius; content.layer?.cornerCurve = .continuous
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.maximumNumberOfLines = 3; titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.isSelectable = true
        // Selecting keeps the faded `type(` and `):`; otherwise the field editor restyles the title plainly.
        titleLabel.allowsEditingTextAttributes = true
        summaryView.isEditable = false; summaryView.isSelectable = true; summaryView.drawsBackground = false
        // Words only sharpen into place here; sliding sideways reads as jitter in a small card.
        summaryView.tokenLayout.travels = false
        summaryView.isRichText = true; summaryView.textContainerInset = .zero
        summaryView.textContainer?.lineFragmentPadding = 0; summaryView.textContainer?.widthTracksTextView = false
        summaryView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        [titleLabel, meta, pipelineRow, mergeRow, skeleton, summaryView].forEach(content.addSubview)
        mergeRow.onOpen = { [weak self] in self?.onOpenMergeChecks?() }
        meta.onOpen = { [weak self] in self?.onOpenFiles?() }
        pipelineRow.onOpen = { [weak self] in if let pipeline = self?.current?.details?.pipeline { self?.onOpenPipeline?(pipeline) } }
        panel.addSubview(content); addSubview(panel)
        height.configure(response: FindMotion.swapResponse, bounce: 0)
        top.configure(response: FindMotion.swapResponse, bounce: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }

    /// Shows the card beside a tab at once, or glides an open one over to it.
    /// `glides` continues from where a card that just closed was, rather than appearing in place.
    func present(key: String, content next: Content, left: CGFloat, anchorTop: CGFloat, maxBottom: CGFloat, theme: RiseTheme, glides: Bool = false) {
        let appearing = self.key == nil
        let switching = key != self.key
        self.key = key; self.theme = theme; isHidden = false
        frame.origin.x = left; self.anchorTop = anchorTop; self.maxBottom = maxBottom
        applyTheme()
        if switching { resetSummary(next) }
        update(next)
        if appearing { height.settle(); if !glides { top.settle() }; render() }
        animate()
    }
    /// New details or more of the description for the card's pull request.
    func update(_ next: Content) {
        current = next
        titleLabel.attributedStringValue = Self.title(next.title, color: theme.text, muted: fadedTitle)
        meta.details = next.details; meta.reference = next.reference; pipelineRow.pipeline = next.details?.pipeline; mergeRow.mergeCheck = next.details?.mergeCheck
        fitWidth()
        if next.summary != laidOut || next.phase == .done {
            stream.receive(next.summary)
            if next.phase == .done { stream.finish() }
            layOutSummary()
        }
        retarget(); animate()
    }
    private func fitWidth() {
        let row = max(StatusLinkRow.width(current?.details?.pipeline.map(PipelineRow.number)), StatusLinkRow.width(current?.details?.mergeCheck.map(MergeCheckRow.text)))
        let width = max(Self.width, min(Self.maximumWidth, ceil(row)+2*Self.inset.width+1))
        guard width != cardWidth else { return }
        cardWidth = width
        summaryView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
    }
    /// Gone at once, like a tooltip.
    func dismiss() {
        guard key != nil else { return }
        key = nil; link?.invalidate(); link = nil
        stream.revealAll(at: CACurrentMediaTime()); paint()
        height.settle(); top.settle(); isHidden = true
    }
    /// `type(`, scope, `):` (or `)!:`) at the start of a conventional commit title.
    private static let conventionalPrefix = try! NSRegularExpression(pattern: #"\G([A-Za-z]+\()([^()]+)(\)!?:)"#)
    /// GitLab's draft markers (`Draft:`, `[Draft]`, `(Draft)`, `Draft -`) and the older `WIP:`.
    private static let draftPrefix = try! NSRegularExpression(pattern: #"^\s*(?:\[(?:draft|wip)\]|\((?:draft|wip)\)|(?:draft|wip)\s*:|draft\s+-)\s*"#, options: .caseInsensitive)
    /// A draft marker and a conventional commit title's `type(` and `):` recede (lighter and a
    /// weight down) so the scope and the change stand out.
    static func title(_ title: String, color: NSColor, muted: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium), faded = NSFont.systemFont(ofSize: 14, weight: .regular)
        let result = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        let all = NSRange(location: 0, length: (title as NSString).length)
        // A draft marker recedes whole, and a conventional type right after it still fades.
        var start = 0
        if let draft = draftPrefix.firstMatch(in: title, range: all) {
            result.addAttributes([.font: faded, .foregroundColor: muted], range: draft.range); start = NSMaxRange(draft.range)
        }
        if let match = conventionalPrefix.firstMatch(in: title, range: NSRange(location: start, length: all.length-start)) {
            for group in [1, 3] { result.addAttributes([.font: faded, .foregroundColor: muted], range: match.range(at: group)) }
        }
        return result
    }
    func applyTheme() {
        panel.fill = background; panel.layer?.borderColor = theme.border.cgColor
        // A dark page swallows a light shadow; it needs more weight to read at all.
        panel.layer?.shadowOpacity = theme == .dark ? 0.45 : 0.12
        titleLabel.textColor = theme.text
        meta.dark = theme == .dark; meta.muted = theme.muted
        pipelineRow.dark = theme == .dark; pipelineRow.muted = theme.muted
        mergeRow.dark = theme == .dark; mergeRow.muted = theme.muted; mergeRow.cutout = background
        skeleton.applyTheme(dark: theme == .dark)
    }

    // MARK: Description

    /// A saved description shows whole; one being written plays out word by word.
    private func resetSummary(_ next: Content) {
        stream = TokenStream(); laidOut = ""; paintedFrom = 0
        summaryView.textStorage?.setAttributedString(NSAttributedString())
        summaryView.tokenLayout.setEntrances([])
        skeleton.removeFromSuperview(); skeleton = SkeletonLine(); content.addSubview(skeleton)
        skeleton.applyTheme(dark: theme == .dark)
        if next.phase == .done && !next.summary.isEmpty {
            laidOut = next.summary
            summaryView.textStorage?.setAttributedString(FindBar.styled(next.summary, color: summaryColor))
        }
    }
    private func layOutSummary() {
        let text = stream.text
        guard !stream.isEmpty, text != laidOut else { paint(); return }
        laidOut = text
        summaryView.textStorage?.setAttributedString(FindBar.styled(text, color: summaryColor))
        stream.base = OKLab(summaryColor)
        stream.place(in: summaryView.string as NSString, at: CACurrentMediaTime())
        paintedFrom = 0; paint()
    }
    /// Colors the words fading in and hides the ones not shown yet, as the find bar does.
    private func paint() {
        guard let manager = summaryView.layoutManager else { return }
        let length = summaryView.textStorage?.length ?? 0
        if paintedFrom < length {
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: paintedFrom, length: length-paintedFrom))
        }
        paintedFrom = length
        if let hidden = stream.hiddenFrom, hidden < length {
            manager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: NSRange(location: hidden, length: length-hidden))
            paintedFrom = hidden
        }
        for tint in stream.tints where NSMaxRange(tint.range) <= length {
            manager.addTemporaryAttribute(.foregroundColor, value: tint.color.color, forCharacterRange: tint.range)
            paintedFrom = min(paintedFrom, tint.range.location)
        }
        summaryView.tokenLayout.setEntrances(stream.entrances)
    }

    // MARK: Layout and motion

    private var hasSummaryText: Bool { !laidOut.isEmpty }
    /// The pipeline and merge checks come in under the description once it has finished playing out.
    private var showsPipeline: Bool {
        guard current?.details?.pipeline != nil || current?.details?.mergeCheck != nil else { return false }
        switch current?.phase {
        case .done: return stream.hiddenFrom == nil
        case .failed: return true
        default: return false
        }
    }
    private var shownPipeline = false
    private var showsSkeleton: Bool { !hasSummaryText && (current?.phase == .idle || current?.phase == .generating) }
    private var titleHeight: CGFloat {
        ceil(titleLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth+2*Self.labelPadding, height: 1000)).height ?? 18)
    }
    private var summaryHeight: CGFloat {
        guard let container = summaryView.textContainer, let manager = summaryView.layoutManager else { return 0 }
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
    private var contentHeight: CGFloat {
        var height = Self.inset.height+titleHeight
        if current?.details != nil { height += Self.titleGap+PullRequestMetaRow.height }
        if hasSummaryText { height += Self.summaryGap+summaryHeight } else if showsSkeleton { height += Self.summaryGap+lineHeight }
        if showsPipeline {
            let rows = [current?.details?.pipeline != nil, current?.details?.mergeCheck != nil].filter { $0 }.count
            height += Self.pipelineGap+CGFloat(rows)*StatusLinkRow.height+CGFloat(rows-1)*Self.mergeGap
        }
        return height+Self.inset.height
    }
    private func retarget() {
        shownPipeline = showsPipeline
        height.target = contentHeight
        top.target = max(8, min(anchorTop, maxBottom-height.target))
    }
    private func render() {
        frame = NSRect(x: frame.minX, y: top.value, width: cardWidth, height: max(0, height.value))
        panel.frame = bounds; content.frame = panel.bounds
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: FindBar.radius, continuous: true)
        // Laid out at full height and revealed as the card grows, like the find bar's answer.
        var y = Self.inset.height
        titleLabel.frame = NSRect(x: Self.inset.width-Self.labelPadding, y: y, width: textWidth+2*Self.labelPadding, height: titleHeight); y += titleHeight
        meta.isHidden = current?.details == nil
        if !meta.isHidden {
            y += Self.titleGap
            meta.frame = NSRect(x: Self.inset.width-Self.metaNudge, y: y, width: textWidth+Self.metaNudge, height: PullRequestMetaRow.height)
            y += PullRequestMetaRow.height
        }
        y += Self.summaryGap
        skeleton.isHidden = !showsSkeleton
        skeleton.frame = NSRect(x: Self.inset.width, y: y+(lineHeight-SkeletonLine.height)/2,
                                width: round(textWidth*skeleton.widthFraction), height: SkeletonLine.height)
        summaryView.isHidden = !hasSummaryText
        summaryView.selectedTextAttributes = [.backgroundColor: theme == .dark ? NSColor(hex: 0x2F2F2F) : NSColor(hex: 0xE0E0E0)]
        summaryView.frame = NSRect(x: Self.inset.width, y: y, width: textWidth, height: summaryHeight)
        if hasSummaryText { y += summaryHeight } else if showsSkeleton { y += lineHeight }
        // The pipeline, then the merge status under it. A ring reads a touch indented beside text.
        y += Self.pipelineGap
        pipelineRow.isHidden = !showsPipeline || current?.details?.pipeline == nil
        pipelineRow.frame = NSRect(x: Self.inset.width-1, y: y, width: textWidth+1, height: StatusLinkRow.height)
        if !pipelineRow.isHidden { y += StatusLinkRow.height+Self.mergeGap }
        mergeRow.isHidden = !showsPipeline || current?.details?.mergeCheck == nil
        mergeRow.frame = NSRect(x: Self.inset.width-1, y: y, width: textWidth+1, height: StatusLinkRow.height)
    }
    private func animate() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { settle(); return }
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    private func settle() {
        stream.revealAll(at: CACurrentMediaTime()); paint()
        height.settle(); top.settle()
        render()
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        height.step(dt); top.step(dt)
        _ = stream.step(at: now); paint()
        if showsPipeline != shownPipeline { retarget() }
        let resting = height.isResting(within: 0.05) && top.isResting(within: 0.05) && !stream.needsFrames
        if resting { link.invalidate(); self.link = nil; height.settle(); top.settle() }
        render()
    }
}

/// Hovering a GitHub pull request tab for a moment opens its card, which opens and closes at
/// once like a tooltip. While one is open, or just after it closes, another pull request tab
/// shows its card immediately, gliding the open one over. The pointer can cross from the tab
/// into the card through a safe triangle, to select its text.
@MainActor final class PullRequestHover {
    static let delay = 0.5, grace = 0.35
    let tooltip = PullRequestTooltip()
    let summaries: PullRequestSummaries
    fileprivate var hoveredID: UUID?
    fileprivate(set) var shownID: UUID?
    fileprivate var timer: Timer?
    fileprivate var hiddenAt = -Double.infinity
    /// Where the pointer left the tab, while it heads for the card.
    fileprivate var safeOrigin: NSPoint?
    /// Where the pointer is heading from `safeOrigin`: the card, or back from the card to its tab.
    fileprivate var safeTarget: NSRect?
    /// The row the pointer just left, grown over the gaps to its neighbours, so crossing a gap
    /// to the next pull request tab keeps the card and glides it over.
    fileprivate var leftRow: NSRect?
    fileprivate var insideCard = false
    fileprivate var tracksPointer = false
    init(storageURL: URL) { summaries = PullRequestSummaries(storageURL: storageURL) }
}

@MainActor extension BrowserController {
    func tabHoverChanged(_ id: UUID, hovering: Bool) {
        let hover = pullRequestHover
        if hovering {
            hover.timer?.invalidate()
            guard sidebar.drag == nil, PullRequest(url: tabs.first(where: { $0.id == id })?.url) != nil else {
                hover.hoveredID = nil
                // Crossing another tab on the way to the card doesn't close it.
                if !pointerIsHeadingForCard() { hidePullRequestTooltip() }
                return
            }
            hover.hoveredID = id; hover.safeOrigin = nil; hover.safeTarget = nil; hover.leftRow = nil
            if hover.shownID != nil || CACurrentMediaTime()-hover.hiddenAt < PullRequestHover.grace { showPullRequestTooltip(id); return }
            hover.timer = Timer.scheduledTimer(withTimeInterval: PullRequestHover.delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showPullRequestTooltip(id) }
            }
        } else {
            guard hover.hoveredID == id else { return }
            hover.hoveredID = nil; hover.timer?.invalidate()
            guard hover.shownID != nil else { return }
            hover.safeOrigin = pointerInRoot; hover.safeTarget = nil
            hover.leftRow = sidebar.rows[id].map { $0.convert($0.bounds, to: root).insetBy(dx: 0, dy: -(TabAppearance.spacing+1)) }
            // Crossing to the next row exits this one first; the next row claims the card in the same turn.
            DispatchQueue.main.async { [weak self] in self?.closeCardIfAbandoned() }
        }
    }
    /// The pointer moved while the card is open: off the tab, outside the card and its safe triangle closes it.
    func pullRequestPointerMoved() {
        let hover = pullRequestHover
        guard hover.shownID != nil, hover.safeOrigin != nil else { return }
        closeCardIfAbandoned()
    }
    /// A click or drag on a tab dismisses the card, and the next one waits for the delay again.
    func tabPressed() {
        let hover = pullRequestHover
        hover.timer?.invalidate(); hover.hoveredID = nil
        hidePullRequestTooltip(); hover.hiddenAt = -.infinity
    }
    func showPullRequestTooltip(_ id: UUID) {
        let hover = pullRequestHover
        guard hover.hoveredID == id, isSidebarShown, window?.isVisible == true,
              let tab = tabs.first(where: { $0.id == id }), let pr = PullRequest(url: tab.url),
              let row = sidebar.rows[id], row.window != nil else { return }
        hover.shownID = id
        let title = pr.title(fromTab: tab.title)
        hover.summaries.load(pr, title: title) { [weak tab] in
            guard let webView = tab?.webView, PullRequest(url: webView.url) == pr else { return nil }
            return try? await PageAssistant.snapshot(of: webView).text
        }
        hover.summaries.refreshStatus(pr)
        if hover.tooltip.superview !== root {
            root.addSubview(hover.tooltip, positioned: .below, relativeTo: dismissArea)
            hover.tooltip.onPointer = { [weak self] inside in self?.cardPointerChanged(inside) }
            hover.tooltip.onOpenFiles = { [weak self] in self?.openFromPullRequestCard(.files) }
            hover.tooltip.onOpenPipeline = { [weak self] pipeline in self?.openFromPullRequestCard(.pipeline(pipeline)) }
            hover.tooltip.onOpenMergeChecks = { [weak self] in self?.openFromPullRequestCard(.mergeChecks) }
        }
        // The safe triangle needs every pointer move, not only those over tracked views.
        if !hover.tracksPointer, let window { hover.tracksPointer = !window.acceptsMouseMovedEvents; window.acceptsMouseMovedEvents = true }
        let anchor = row.convert(row.bounds, to: root)
        hover.tooltip.present(key: pr.key, content: tooltipContent(pr, title: title), left: sidebar.frame.maxX+6,
                              anchorTop: anchor.minY, maxBottom: root.bounds.height-8, theme: theme,
                              glides: CACurrentMediaTime()-hover.hiddenAt < PullRequestHover.grace)
    }
    /// The card's tab closed, or stopped being a pull request.
    func refreshPullRequestTooltip() {
        guard let id = pullRequestHover.shownID else { return }
        if PullRequest(url: tabs.first(where: { $0.id == id })?.url) == nil { hidePullRequestTooltip() }
    }
    func hidePullRequestTooltip() {
        let hover = pullRequestHover
        hover.timer?.invalidate(); hover.safeOrigin = nil; hover.safeTarget = nil; hover.leftRow = nil; hover.insideCard = false
        guard hover.shownID != nil else { return }
        hover.shownID = nil; hover.hiddenAt = CACurrentMediaTime()
        updatePeekCovers()
        if hover.tracksPointer { window?.acceptsMouseMovedEvents = false; hover.tracksPointer = false }
        hover.tooltip.dismiss()
    }
    func pullRequestSummaryChanged(_ key: String) {
        let hover = pullRequestHover
        guard hover.tooltip.key == key, let id = hover.shownID, let tab = tabs.first(where: { $0.id == id }),
              let pr = PullRequest(url: tab.url), pr.key == key else { return }
        hover.tooltip.update(tooltipContent(pr, title: pr.title(fromTab: tab.title)))
    }
    enum PullRequestCardLink { case files, pipeline(Pipeline), mergeChecks }
    /// Each goes to the card's tab: the file count on the changed files, the pipeline number
    /// with the pipeline's jobs in a Peek over it, and the merge status scrolled to the merge checks.
    private func openFromPullRequestCard(_ link: PullRequestCardLink) {
        guard let id = pullRequestHover.shownID, let tab = tabs.first(where: { $0.id == id }), let pr = PullRequest(url: tab.url) else { return }
        tabPressed()
        if selectedID != id { select(id) }
        switch link {
        case .pipeline(let pipeline): if let url = pipeline.jobsURL { showPeek(url: url) }
        case .files: if let url = pr.filesURL, tab.url != url { tab.load(url) }
        case .mergeChecks:
            guard let url = pr.overviewURL else { return }
            let web = tab.webView
            let onOverview = web.url.map { $0.path.trimmingCharacters(in: ["/"]) == url.path.trimmingCharacters(in: ["/"]) } ?? false
            if !onOverview { tab.load(url) }
            Task { [weak web] in
                // Wait for the overview to be the page loaded, then let the page find its widget.
                for _ in 0..<150 {
                    guard let web else { return }
                    if web.url.map({ $0.path.trimmingCharacters(in: ["/"]) == url.path.trimmingCharacters(in: ["/"]) }) == true, !web.isLoading { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                _ = try? await web?.evaluateJavaScript(Self.scrollToMergeChecks, contentWorld: .defaultClient)
            }
        }
    }
    /// GitLab draws its merge widget after the page loads; this waits up to 10 s for it, then
    /// scrolls it into the middle of the page.
    static let scrollToMergeChecks = """
    (() => {
      const selectors = ['[data-testid="merge-checks"]', '.mr-state-widget', '.mr-widget-section', '#js-vue-mr-widget'];
      let tries = 0;
      const find = () => {
        const widget = selectors.map(s => document.querySelector(s)).find(e => e && e.getBoundingClientRect().height > 0);
        if (widget) widget.scrollIntoView({ block: 'center', behavior: 'smooth' });
        else if (++tries < 50) setTimeout(find, 200);
      };
      find();
    })();
    """
    private func cardPointerChanged(_ inside: Bool) {
        let hover = pullRequestHover
        hover.insideCard = inside
        // The pages under the card keep their hover tracking otherwise, and would take the
        // card's pointer and cursor for their own links.
        if inside { for tab in tabs { (tab.webView as? LinkCursorWebView)?.isCovered = true }; (peekTab?.webView as? LinkCursorWebView)?.isCovered = true }
        else { updatePeekCovers() }
        if inside { hover.safeOrigin = nil; hover.safeTarget = nil; hover.leftRow = nil; return }
        // Heading back from the card to its tab crosses a gap first; a triangle toward the tab
        // keeps the card from blinking out on the way.
        hover.safeOrigin = pointerInRoot
        hover.safeTarget = hover.shownID.flatMap { sidebar.rows[$0] }.map { $0.convert($0.bounds, to: root) }
        DispatchQueue.main.async { [weak self] in self?.closeCardIfAbandoned() }
    }
    private func closeCardIfAbandoned() {
        let hover = pullRequestHover
        guard hover.shownID != nil, hover.hoveredID == nil, !hover.insideCard, !pointerIsHeadingForCard(),
              !pointerIsOverPullRequestTab else { return }
        hidePullRequestTooltip()
    }
    /// A quick move can land well inside the next row before its tracking area reports the
    /// entry. Over another pull request tab, the card waits for that entry and glides over
    /// instead of closing and popping back open.
    private var pointerIsOverPullRequestTab: Bool {
        guard let point = pointerInRoot, let id = sidebar.tabID(at: sidebar.convert(point, from: root)) else { return false }
        return PullRequest(url: tabs.first(where: { $0.id == id })?.url) != nil
    }
    private var pointerInRoot: NSPoint? {
        guard let window else { return nil }
        return root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }
    /// Inside the card or the gap beside the row just left, or inside the triangle from where
    /// the pointer left (the tab or the card) to the near edge of where it's heading.
    private func pointerIsHeadingForCard() -> Bool {
        let hover = pullRequestHover
        guard hover.shownID != nil, let point = pointerInRoot else { return false }
        let card = hover.tooltip.frame
        if card.contains(point) || hover.leftRow?.contains(point) == true { return true }
        guard let origin = hover.safeOrigin else { return false }
        let target = hover.safeTarget ?? card
        if target.contains(point) || hypot(point.x-origin.x, point.y-origin.y) < 2 { return true }
        let edge = target.minX >= origin.x ? target.minX : target.maxX
        let a = origin, b = NSPoint(x: edge, y: target.minY), c = NSPoint(x: edge, y: target.maxY)
        func side(_ p: NSPoint, _ q: NSPoint, _ r: NSPoint) -> CGFloat { (p.x-r.x)*(q.y-r.y)-(q.x-r.x)*(p.y-r.y) }
        let d1 = side(point, a, b), d2 = side(point, b, c), d3 = side(point, c, a)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }
    private func tooltipContent(_ pr: PullRequest, title: String) -> PullRequestTooltip.Content {
        let entry = pullRequestHover.summaries.entry(for: pr)
        return PullRequestTooltip.Content(title: entry.details?.title ?? title, reference: pr.reference, details: entry.details,
                                          summary: entry.summary, phase: entry.phase)
    }
}
