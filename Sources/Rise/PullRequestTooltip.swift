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
/// The file count opens the changed files; it and the diff size show the split of the lines hovered.
final class PullRequestMetaRow: CardLinkRow {
    static let height: CGFloat = 20
    var details: PullRequestDetails? { didSet { needsDisplay = true } }
    /// "#12" on GitHub, "!12" on GitLab.
    var reference = "" { didSet { needsDisplay = true } }
    /// Where the lines added and removed and the squares were last drawn.
    private(set) var statsRect = NSRect.zero
    /// The pointer went onto the diff size, or off it.
    var onStatsHover: ((Bool) -> Void)?
    private(set) var statsHovered = false { didSet { if statsHovered != oldValue { onStatsHover?(statsHovered) } } }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hoverStats(event) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); hoverStats(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); statsHovered = false }
    override func viewDidHide() { super.viewDidHide(); statsHovered = false }
    private func hoverStats(_ event: NSEvent) { statsHovered = statsRect.contains(convert(event.locationInWindow, from: nil)) }

    override func draw(_ dirtyRect: NSRect) {
        guard let details else { placeLink(.zero); statsRect = .zero; return }
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
        statsRect = NSRect(x: floor(x), y: 0, width: bounds.width-floor(x), height: Self.height)
    }
    private static func icon(_ data: String, size: CGFloat, color: NSColor) -> NSImage {
        let icon = TablerIcon.image(data, size: size)
        return NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect); color.set(); rect.fill(using: .sourceAtop); return true
        }
    }
}

/// The hover card for a GitHub pull request or GitLab merge request tab, or a link to one on a
/// page: title, status and diff size, then a short description that streams in like the find
/// bar's answers. It shares the find bar's surface, its height spring and its word reveal.
@MainActor final class PullRequestTooltip: FlippedView {
    struct Content {
        var title: String
        var reference: String
        var details: PullRequestDetails?
        var summary: String
        var phase: PullRequestSummaries.Phase
        /// What writing the description took in, for the menu.
        var inputTokens: Int? = nil
        /// The title and description as edited in the card.
        var custom = PullRequestSummaries.Custom()
        /// The split of the lines by kind of file is on its way.
        var breakdownPending = false
        /// As it shows: the edits in place of the request's own while they're shown.
        var shown: Content {
            guard custom.shown else { return self }
            var shown = self
            if let title = custom.title { shown.title = title }
            if let summary = custom.summary { shown.summary = summary; shown.phase = .done }
            return shown
        }
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
    let titleLabel = CardTitleField(wrappingLabelWithString: "")
    let meta = PullRequestMetaRow()
    private let pipelineRow = PipelineRow()
    private let mergeRow = MergeCheckRow()
    private var skeleton = SkeletonLine()
    /// The find bar's ⋯ after an answer, with its menu: Regenerate, Copy and the input tokens.
    let moreButton = MenuButton()
    private var menuOpen = false
    let summaryView = TokenTextView()
    private var stream = TokenStream(), paintedFrom = 0, laidOut = ""
    private var height = MotionSpring(0), top = MotionSpring(0)
    private var link: CADisplayLink?, lastTick: CFTimeInterval?
    private var theme = RiseTheme.neutral
    private var current: Content?
    /// Beside a tab the card hangs from the tab's top, growing down; above a link it stands on
    /// the link, growing up, so it never covers it.
    enum Placement: Equatable { case beside(top: CGFloat, maxBottom: CGFloat), above(bottom: CGFloat, minTop: CGFloat) }
    private var placement = Placement.beside(top: 0, maxBottom: 0)
    /// A link's card is as wide as the link, within limits; a tab's is the find bar's width.
    private var preferredWidth: CGFloat?
    private var exits = 0
    private(set) var key: String?
    /// With no title, the card is its description alone, as a link's summary is: the space above
    /// it is the space below, the skeleton line centred between them while it's written. It
    /// isn't edited in place, and has no edits to show.
    private var hasTitle: Bool { !(current?.title.isEmpty ?? false) || editing?.field == .title }
    /// The pointer went into the card, or left it.
    var onPointer: ((Bool) -> Void)?
    /// The file count was clicked.
    var onOpenFiles: (() -> Void)?
    /// The file count was hovered, so its split of the lines is wanted.
    var onWantsBreakdown: (() -> Void)?
    /// Under the file count or the diff size while it's hovered.
    let breakdownCard = ChangeBreakdownCard()
    private var breakdownDelay: DispatchWorkItem?
    /// What the split last came out of: the file count, off its bottom right corner, or the
    /// diff size, off its bottom left one.
    private var breakdownFromStats = false
    /// The pipeline's number was clicked.
    var onOpenPipeline: ((Pipeline) -> Void)?
    /// The merge status was clicked.
    var onOpenMergeChecks: (() -> Void)?
    /// Regenerate was picked in the ⋯ menu.
    var onRegenerate: (() -> Void)?
    /// The title or description was edited (nil for the one that wasn't), for the card's `key`.
    var onEdit: ((_ key: String, _ title: String?, _ summary: String?) -> Void)?
    /// Custom Content was checked or unchecked in the ⋯ menu.
    var onShowCustom: ((_ key: String, _ shown: Bool) -> Void)?
    /// The request as it came, before any edits were put in its place.
    private var source: Content?
    private enum Field { case title, summary }
    /// What's being edited in place, as a tab's title is: its text before, and the height it keeps
    /// at least until editing ends, so deleting text doesn't shrink the card under the typing.
    /// `moreRow` is whether the ⋯ had a row of its own then, kept while the description is edited.
    private var editing: (field: Field, before: String, floor: CGFloat, moreRow: Bool)?
    private weak var responderBeforeEditing: NSResponder?
    var isEditing: Bool { editing != nil }
    /// Words of the description are still waiting to play in.
    var isRevealingSummary: Bool { stream.isRevealing }

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
        // Double-clicked, the title is edited in place, as a tab's is.
        titleLabel.isSelectable = false; titleLabel.focusRingType = .none; titleLabel.delegate = self
        titleLabel.onDoubleClick = { [weak self] in self?.beginEditing(.title) }
        summaryView.isEditable = false; summaryView.isSelectable = true; summaryView.drawsBackground = false
        // Words only sharpen into place here; sliding sideways reads as jitter in a small card.
        summaryView.tokenLayout.travels = false
        summaryView.isRichText = true; summaryView.textContainerInset = .zero
        summaryView.textContainer?.lineFragmentPadding = 0; summaryView.textContainer?.widthTracksTextView = false
        summaryView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        summaryView.focusRingType = .none; summaryView.delegate = self
        summaryView.onDoubleClick = { [weak self] in self?.beginEditing(.summary) }
        summaryView.handCursorRect = { [weak self] in
            guard let self, !self.moreButton.isHidden else { return nil }
            return self.summaryView.convert(self.moreButton.bounds, from: self.moreButton)
        }
        [titleLabel, meta, pipelineRow, mergeRow, skeleton, summaryView, moreButton].forEach(content.addSubview)
        moreButton.makeMenu = { [weak self] in self?.makeMoreMenu() }
        // The menu takes the pointer while it's open; leaving is judged once it closes.
        moreButton.menuWillOpen = { [weak self] in self?.menuOpen = true }
        moreButton.menuDidClose = { [weak self] in self?.menuOpen = false; self?.checkPointerLeft() }
        mergeRow.onOpen = { [weak self] in self?.onOpenMergeChecks?() }
        meta.onOpen = { [weak self] in self?.onOpenFiles?() }
        meta.onLinkHover = { [weak self] _ in self?.breakdownHoverChanged() }
        meta.onStatsHover = { [weak self] _ in self?.breakdownHoverChanged() }
        pipelineRow.onOpen = { [weak self] in if let pipeline = self?.current?.details?.pipeline { self?.onOpenPipeline?(pipeline) } }
        panel.addSubview(content); addSubview(panel)
        height.configure(response: FindMotion.swapResponse, bounce: 0)
        top.configure(response: FindMotion.swapResponse, bounce: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || key == nil ? nil : super.hitTest(point) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    // The menu takes the pointer while it's open; leaving is judged once it closes.
    // While editing, the card stays until editing ends.
    override func mouseExited(with event: NSEvent) { if !menuOpen && editing == nil { onPointer?(false) } }
    private func checkPointerLeft() {
        guard key != nil, let window else { return }
        if !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { onPointer?(false) }
    }

    func makeMoreMenu() -> NSMenu {
        let menu = NSMenu()
        let regenerate = NSMenuItem(title: "Regenerate", action: #selector(regenerateFromMenu), keyEquivalent: "")
        let copy = NSMenuItem(title: "Copy", action: #selector(copyFromMenu), keyEquivalent: "")
        // Checked while the edits show; unchecked, the request's own title and description come back.
        let custom = NSMenuItem(title: "Custom Content", action: #selector(toggleCustomFromMenu), keyEquivalent: "")
        custom.state = source?.custom.shown == true ? .on : .off
        custom.isEnabled = source?.custom.exists == true
        menu.autoenablesItems = false
        (hasTitle ? [regenerate, copy, custom] : [regenerate, copy]).forEach { $0.target = self; menu.addItem($0) }
        if current?.phase == .done, let count = current?.inputTokens {
            menu.addItem(.separator())
            let usage = NSMenuItem(title: count.formatted(.number.locale(Locale(identifier: "en_US"))) + " tok", action: nil, keyEquivalent: "")
            usage.isEnabled = false
            menu.addItem(usage)
        }
        return menu
    }
    @objc private func regenerateFromMenu() { onRegenerate?() }
    @objc private func toggleCustomFromMenu() {
        guard let key, let source, source.custom.exists else { return }
        onShowCustom?(key, !source.custom.shown)
    }
    /// The description, as the find bar's Copy takes its answer.
    @objc private func copyFromMenu() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setString(current?.summary ?? laidOut, forType: .string)
    }

    // MARK: Editing

    /// The title or description, double-clicked once it's written, edits in place with all of it
    /// selected, as a tab's title does: no border, just a caret.
    private func beginEditing(_ field: Field) {
        guard key != nil, editing == nil, showsMore, hasTitle, let window else { return }
        let before = field == .title ? (current?.title ?? "") : (hasSummaryText ? summaryView.string : "")
        editing = (field, before, field == .title ? titleHeight : (hasSummaryText ? summaryHeight : lineHeight), moreNeedsRow)
        responderBeforeEditing = window.firstResponder
        onPointer?(true)
        switch field {
        case .title:
            titleLabel.attributedStringValue = NSAttributedString(string: before, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: theme.text])
            titleLabel.maximumNumberOfLines = 0
            titleLabel.isEditable = true; titleLabel.isSelectable = true
            window.makeFirstResponder(titleLabel)
            if let editor = titleLabel.currentEditor() as? NSTextView {
                editor.insertionPointColor = theme.text; editor.drawsBackground = false
                editor.selectedTextAttributes = summaryView.selectedTextAttributes
                editor.selectAll(nil)
            }
        case .summary:
            stream.revealAll(at: CACurrentMediaTime()); paint()
            if let manager = summaryView.layoutManager, let length = summaryView.textStorage?.length, length > 0 {
                manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
            }
            summaryView.typingAttributes = [.font: Self.summaryFont, .foregroundColor: summaryColor]
            summaryView.insertionPointColor = theme.text
            summaryView.isEditable = true
            window.makeFirstResponder(summaryView)
            summaryView.selectAll(nil)
        }
        retarget(); render()
    }
    /// Return keeps the edit, Escape leaves it as it was; closing the card or moving to another
    /// request keeps it too.
    private func endEditing(saving: Bool) {
        guard let (field, before, _, _) = editing, let key else { return }
        let text: String
        switch field {
        case .title: text = (titleLabel.currentEditor()?.string ?? titleLabel.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        case .summary: text = summaryView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        editing = nil
        switch field {
        case .title:
            titleLabel.abortEditing(); titleLabel.isEditable = false; titleLabel.isSelectable = false
            titleLabel.maximumNumberOfLines = 3
        case .summary:
            summaryView.isEditable = false; summaryView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        // Focus goes back where it was, unless a click elsewhere already moved it.
        if let window, window.firstResponder === summaryView || window.firstResponder === window || (window.firstResponder as? NSTextView)?.isFieldEditor == true {
            window.makeFirstResponder(responderBeforeEditing)
        }
        // An empty title isn't one; the request's own stays.
        let changed = saving && text != before.trimmingCharacters(in: .whitespacesAndNewlines) && !(field == .title && text.isEmpty)
        if changed { onEdit?(key, field == .title ? text : nil, field == .summary ? text : nil) }
        else if let source {
            // As it was: the shown text back in place, and the card back to its height.
            let shown = source.shown
            if field == .title { titleLabel.attributedStringValue = Self.title(shown.title, color: theme.text, muted: fadedTitle) }
            else { resetSummary(shown) }
            retarget(); animate()
        }
        checkPointerLeft()
    }
    private func editedTextChanged() { retarget(); animate() }

    /// Shows the card beside a tab at once, or glides an open one over to it.
    /// `glides` continues from where a card that just closed was, rather than appearing in place.
    /// `pops` unfolds it from its edge nearest what it's about, as Arc's link previews open.
    /// `fromTab` comes and goes with the hover cards' motion (Develop ▸ Card Motion Tester),
    /// out of its tab, or out of `growsFrom` when given, as the Calendar and Gmail cards do.
    func present(key: String, content next: Content, left: CGFloat, placement: Placement, theme: RiseTheme,
                 width: CGFloat? = nil, glides: Bool = false, pops: Bool = false, fromTab: Bool = false, growsFrom: NSPoint? = nil) {
        let appearing = self.key == nil
        let switching = key != self.key
        if switching { endEditing(saving: true); breakdownDelay?.cancel(); breakdownCard.hide(animated: false) }
        if appearing {
            exits += 1; layer?.removeAnimation(forKey: "card.exit.opacity"); layer?.removeAnimation(forKey: "card.exit.transform")
            CardMotionAnimator.cancelOut(self)
        }
        self.key = key; self.theme = theme; isHidden = false
        frame.origin.x = left; self.placement = placement; preferredWidth = width
        self.fromTab = fromTab; tabPoint = growsFrom
        applyTheme()
        // Opened on what it shows, edits and all, so a saved description shows whole rather than playing in.
        if switching { resetSummary(next.shown) }
        update(next)
        if appearing { height.settle(); if !glides { top.settle() }; render() }
        if appearing && pops { popIn() }
        if appearing && fromTab && !glides { CardMotionAnimator.animateIn(self, CardMotion.selected, tab: tabOrigin) }
        animate()
    }
    private var fromTab = false, tabPoint: NSPoint?
    /// Where the card comes out of its tab, in its own coordinates: its left edge level with the
    /// tab's middle, or the point it was given.
    private var tabOrigin: CGPoint {
        var anchorTop = frame.minY
        if case .beside(let top, _) = placement { anchorTop = top }
        let point = tabPoint ?? NSPoint(x: frame.minX, y: anchorTop+TabAppearance.height/2)
        return CGPoint(x: point.x-frame.minX, y: point.y-frame.minY)
    }
    /// A moment on the file count or the diff size shows the split, asked for the first time it's wanted.
    private func breakdownHoverChanged() {
        breakdownDelay?.cancel(); breakdownDelay = nil
        guard meta.linkHovered || meta.statsHovered else { breakdownCard.hide(); return }
        let fromStats = meta.statsHovered
        let show = DispatchWorkItem { [weak self] in
            guard let self, self.key != nil, fromStats ? self.meta.statsHovered : self.meta.linkHovered else { return }
            self.onWantsBreakdown?()
            self.breakdownFromStats = fromStats
            self.showBreakdown()
        }
        breakdownDelay = show
        DispatchQueue.main.asyncAfter(deadline: .now()+Self.breakdownDelay, execute: show)
    }
    static let breakdownDelay: TimeInterval = 0.15
    private func showBreakdown() {
        guard key != nil, let details = current?.details, let host = superview else { breakdownCard.hide(animated: false); return }
        if breakdownCard.superview !== host || host.subviews.last !== breakdownCard { host.addSubview(breakdownCard, positioned: .above, relativeTo: nil) }
        breakdownCard.appearance = theme.appearance
        breakdownCard.show(details.breakdown, loading: source?.breakdownPending == true,
                           total: ChangeBreakdown.Lines(additions: details.additions, deletions: details.deletions),
                           below: host.convert(breakdownFromStats ? meta.statsRect : meta.linkRect, from: meta),
                           from: breakdownFromStats ? .bottomLeft : .bottomRight,
                           in: host.bounds, theme: theme, background: background, text: summaryColor)
    }
    /// New details or more of the description for the card's pull request.
    func update(_ incoming: Content) {
        let showedCustom = source?.custom.shown == true
        source = incoming
        let next = incoming.shown
        // What's being typed stays as it is until editing ends.
        let editingSummary = editing?.field == .summary
        // Regenerate starts the description over rather than carrying on from the old one, and the
        // edits and the request's own description replace each other whole.
        if key != nil, !editingSummary, (next.summary.isEmpty && current?.summary.isEmpty == false)
            || showedCustom != incoming.custom.shown || (incoming.custom.shown && next.summary != laidOut) {
            resetSummary(next)
        }
        current = next
        if editing?.field != .title { titleLabel.attributedStringValue = Self.title(next.title, color: theme.text, muted: fadedTitle) }
        meta.details = next.details; meta.reference = next.reference; pipelineRow.pipeline = next.details?.pipeline; mergeRow.mergeCheck = next.details?.mergeCheck
        if breakdownCard.isShown { showBreakdown() }
        fitWidth()
        if !editingSummary, next.summary != laidOut || next.phase == .done {
            stream.receive(next.summary)
            if next.phase == .done { stream.finish() }
            layOutSummary()
        }
        retarget(); animate()
    }
    private func fitWidth() {
        let row = max(StatusLinkRow.width(current?.details?.pipeline.map(PipelineRow.number)), StatusLinkRow.width(current?.details?.mergeCheck.map(MergeCheckRow.text)))
        // Room beside the last status row for the ⋯.
        let width = max(preferredWidth ?? Self.width, min(Self.maximumWidth, ceil(row)+2*Self.inset.width+1+Self.moreRoom))
        guard width != cardWidth else { return }
        cardWidth = width
        summaryView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
    }
    /// Gone at once, like a tooltip, or with `fades`, folding back into its edge by the link as
    /// Arc's previews do, fading as it goes.
    /// Plays the way in again beside a tab, for the motion tester.
    func replayMotion() {
        guard fromTab, key != nil, !isHidden else { return }
        CardMotionAnimator.animateIn(self, CardMotion.selected, tab: tabOrigin)
    }
    /// Beside a tab it goes with the hover cards' motion unless `immediately`.
    func dismiss(fades: Bool = false, immediately: Bool = false) {
        guard key != nil else { return }
        breakdownDelay?.cancel(); breakdownCard.hide(animated: !immediately)
        endEditing(saving: true)
        key = nil; link?.invalidate(); link = nil
        stream.revealAll(at: CACurrentMediaTime()); paint()
        height.settle(); top.settle()
        if fromTab, !fades, !immediately {
            let exit = exits
            CardMotionAnimator.animateOut(self, CardMotion.selected, tab: tabOrigin) { [weak self] in
                if let self, self.key == nil, self.exits == exit { self.isHidden = true }
            }
            return
        }
        guard fades, let layer, window != nil, !isHidden else { isHidden = true; return }
        exits += 1
        let exit = exits
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.exits == exit else { return }
            self.isHidden = true
            layer.removeAnimation(forKey: "card.exit.opacity"); layer.removeAnimation(forKey: "card.exit.transform")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1; fade.toValue = 0
        fade.duration = Self.foldDuration
        var animations: [(CAAnimation, String)] = [(fade, "card.exit.opacity")]
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // A card still unfolding folds from the height it has reached.
            let reached = max(0.001, layer.presentation()?.transform.m22 ?? 1)
            let toward: CGFloat = if case .above = placement { 1 } else { -1 }
            let steps = Int(ceil(Self.foldDuration*120))
            let values = (0...steps).map { step -> NSValue in
                let time = Self.foldDuration*Double(step)/Double(steps)
                let fold = CGFloat(1-Self.foldGrowth(time)), settle = CGFloat(1-Self.foldSettle(time))
                return NSValue(caTransform3D: pivot(1, y: max(0.001, fold*reached), shift: toward*Self.foldSag*(settle-fold)))
            }
            let collapse = CAKeyframeAnimation(keyPath: "transform")
            collapse.values = values; collapse.duration = Self.foldDuration; collapse.calculationMode = .linear
            collapse.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            animations.append((collapse, "card.exit.transform"))
        }
        for (animation, key) in animations {
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: key)
        }
        layer.removeAnimation(forKey: "card.pop.opacity"); layer.removeAnimation(forKey: "card.pop.transform")
        CATransaction.commit()
    }
    /// Arc's close, fitted the same way: the card folds back into its edge by the link in about
    /// 0.14 s, accelerating, while that edge sags towards the link by up to 7.5 points and
    /// comes back as the card goes. Arc keeps it opaque; here it also fades out on the way.
    static let foldGrowth = ClosedSpring(response: 0.458, damping: 0.3109)
    static let foldSettle = ClosedSpring(response: 0.5026, damping: 0.2)
    static let foldSag: CGFloat = 213.63
    /// Until the fold reaches nothing.
    static let foldDuration: Double = {
        var time = 0.0
        while foldGrowth(time) < 0.999 { time += 0.0005 }
        return time
    }()
    /// Arc's link preview, fitted to its edges in two screen recordings (within about half a
    /// point): the card grows from nothing at its edge by the link on one spring, overshooting
    /// its height by about 2%, its content squashed rather than cropped, with no fade and no
    /// change in width. That edge sags towards the link by a fixed 24.5 points times the gap
    /// between the growth and a second, softer spring that starts 41 ms later: about 7.5
    /// points at first, then a point the other way as the card overshoots.
    static let unfoldGrowth = ClosedSpring(response: 0.3647, damping: 0.7935)
    static let unfoldSettle = ClosedSpring(response: 0.3823, damping: 0.6944)
    static let unfoldLag = 0.0408, unfoldSag: CGFloat = 24.46, unfoldDuration = 0.8
    /// A scale about the middle of the card's edge nearest what it shows (the link, when it's
    /// above one), then a nudge along y.
    private func pivot(_ scale: CGFloat, y yScale: CGFloat? = nil, shift: CGFloat = 0) -> CATransform3D {
        guard let layer else { return CATransform3DIdentity }
        let size = layer.bounds.size, anchor = layer.anchorPoint
        let edge: CGFloat = if case .above = placement { 1 } else { 0 }
        let point = CGPoint(x: (0.5-anchor.x)*size.width, y: (edge-anchor.y)*size.height)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-point.x, -point.y, 0), CATransform3DMakeScale(scale, yScale ?? scale, 1)),
                                   CATransform3DMakeTranslation(point.x, point.y+shift, 0))
    }
    private func popIn() {
        guard let layer, window != nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = Self.unfoldDuration
            layer.add(fade, forKey: "card.pop.opacity"); return
        }
        // Towards the link: down when the card is above it, up when it's below.
        let toward: CGFloat = if case .above = placement { 1 } else { -1 }
        let steps = Int(Self.unfoldDuration*120)
        let values = (0...steps).map { step -> NSValue in
            let time = Self.unfoldDuration*Double(step)/Double(steps)
            let growth = CGFloat(Self.unfoldGrowth(time)), settle = CGFloat(Self.unfoldSettle(time-Self.unfoldLag))
            return NSValue(caTransform3D: pivot(1, y: max(0.001, growth), shift: toward*Self.unfoldSag*(growth-settle)))
        }
        let unfold = CAKeyframeAnimation(keyPath: "transform")
        unfold.values = values; unfold.duration = Self.unfoldDuration; unfold.calculationMode = .linear
        unfold.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        layer.add(unfold, forKey: "card.pop.transform")
    }
    /// `type(`, scope, `):` (or `)!:`) at the start of a conventional commit title.
    private static let conventionalPrefix = try! NSRegularExpression(pattern: #"\G([A-Za-z]+\()([^()]+)(\)!?:)"#)
    /// `type:` (or `type!:`) with no scope. Only the usual types, so a title such as "Update: …" stays as it is.
    private static let scopelessPrefix = try! NSRegularExpression(
        pattern: #"\G(?:feat|fix|chore|docs|style|refactor|perf|test|tests|build|ci|revert|deps|release|hotfix)!?:"#, options: .caseInsensitive)
    /// GitLab's draft markers (`Draft:`, `[Draft]`, `(Draft)`, `Draft -`) and the older `WIP:`.
    private static let draftPrefix = try! NSRegularExpression(pattern: #"^\s*(?:\[(?:draft|wip)\]|\((?:draft|wip)\)|(?:draft|wip)\s*:|draft\s+-)\s*"#, options: .caseInsensitive)
    /// A draft marker and a conventional commit title's `type(` and `):`, or its whole `type:` when
    /// it has no scope, recede (lighter and a weight down) so the scope and the change stand out.
    static func title(_ title: String, color: NSColor, muted: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium), faded = NSFont.systemFont(ofSize: 14, weight: .regular)
        let result = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        let all = NSRange(location: 0, length: (title as NSString).length)
        // A draft marker recedes whole, and a conventional type right after it still fades.
        var start = 0
        if let draft = draftPrefix.firstMatch(in: title, range: all) {
            result.addAttributes([.font: faded, .foregroundColor: muted], range: draft.range); start = NSMaxRange(draft.range)
        }
        let rest = NSRange(location: start, length: all.length-start)
        if let match = conventionalPrefix.firstMatch(in: title, range: rest) {
            for group in [1, 3] { result.addAttributes([.font: faded, .foregroundColor: muted], range: match.range(at: group)) }
        } else if let match = scopelessPrefix.firstMatch(in: title, range: rest) {
            result.addAttributes([.font: faded, .foregroundColor: muted], range: match.range)
        }
        return result
    }
    func applyTheme() {
        panel.fill = background; KeroLitEdge.apply(to: panel, theme: theme)
        // A dark page swallows a light shadow; it needs more weight to read at all.
        panel.layer?.shadowOpacity = theme == .dark ? 0.45 : 0.12
        titleLabel.textColor = theme.text
        meta.dark = theme == .dark; meta.muted = theme.muted
        moreButton.contentTintColor = theme.muted; moreButton.hoverColor = theme.text.withAlphaComponent(0.07)
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

    private var hasSummaryText: Bool { !laidOut.isEmpty || editing?.field == .summary }
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
    /// The ⋯ once the model has answered (or failed to), at the same moment as the status rows.
    private var showsMore: Bool {
        switch current?.phase {
        case .done: return stream.hiddenFrom == nil
        case .failed: return true
        default: return false
        }
    }
    private var shownMore = false
    static let moreSize = NSSize(width: 22, height: 20), moreRoom: CGFloat = 26
    /// Without status rows the ⋯ sits at the end of the description's last line, or on a row of
    /// its own when the line runs too close to the edge.
    private var moreNeedsRow: Bool {
        guard showsMore, !showsPipeline else { return false }
        // While the description is edited the ⋯ steps aside, and its row stays as it was.
        if let editing, editing.field == .summary { return editing.moreRow }
        guard hasSummaryText, let manager = summaryView.layoutManager, let container = summaryView.textContainer else { return true }
        manager.ensureLayout(for: container)
        let glyphs = manager.numberOfGlyphs
        guard glyphs > 0 else { return true }
        let last = manager.lineFragmentUsedRect(forGlyphAt: glyphs-1, effectiveRange: nil)
        return last.maxX > textWidth-Self.moreRoom
    }
    private var showsSkeleton: Bool { !hasSummaryText && (current?.phase == .idle || current?.phase == .generating) }
    private var titleHeight: CGFloat {
        guard hasTitle else { return 0 }
        let bounds = NSRect(x: 0, y: 0, width: textWidth+2*Self.labelPadding, height: 1000)
        if let editing, editing.field == .title, let typed = titleLabel.currentEditor()?.string, let cell = titleLabel.cell?.copy() as? NSCell {
            cell.stringValue = typed.isEmpty ? " " : typed
            return max(editing.floor, ceil(cell.cellSize(forBounds: bounds).height))
        }
        return ceil(titleLabel.cell?.cellSize(forBounds: bounds).height ?? 18)
    }
    /// The description's height as far as its words show: while they play in, the card grows a
    /// line at a time with them rather than ahead to all the text that has arrived, keeping three
    /// quarters of a line of room under the newest so a new line has somewhere to start. Until the first word
    /// shows, it holds the skeleton's one line; done, it fits the text.
    private var summaryHeight: CGFloat {
        guard let container = summaryView.textContainer, let manager = summaryView.layoutManager else { return 0 }
        manager.ensureLayout(for: container)
        let used = ceil(manager.usedRect(for: container).height)
        if let editing, editing.field == .summary { return max(editing.floor, used) }
        guard stream.isRevealing else { return used }
        guard let newest = stream.newest, NSMaxRange(newest) <= (summaryView.textStorage?.length ?? 0) else { return min(used, lineHeight) }
        let glyph = manager.glyphIndexForCharacter(at: NSMaxRange(newest)-1)
        return min(used, ceil(manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxY+lineHeight*0.75))
    }
    private var contentHeight: CGFloat {
        var height = Self.inset.height+titleHeight
        if current?.details != nil { height += Self.titleGap+PullRequestMetaRow.height }
        let gap = hasTitle ? Self.summaryGap : 0
        if hasSummaryText { height += gap+summaryHeight } else if showsSkeleton { height += gap+lineHeight }
        if showsPipeline {
            let rows = [current?.details?.pipeline != nil, current?.details?.mergeCheck != nil].filter { $0 }.count
            height += Self.pipelineGap+CGFloat(rows)*StatusLinkRow.height+CGFloat(rows-1)*Self.mergeGap
        }
        if moreNeedsRow { height += Self.pipelineGap+StatusLinkRow.height }
        return height+Self.inset.height
    }
    private func retarget() {
        shownPipeline = showsPipeline; shownMore = showsMore
        height.target = contentHeight
        switch placement {
        case .beside(let anchorTop, let maxBottom): top.target = max(8, min(anchorTop, maxBottom-height.target))
        case .above(let bottom, let minTop): top.target = max(minTop, bottom-height.target)
        }
    }
    private func render() {
        // Above a link the bottom edge stays put while the card grows.
        var cardTop = top.value
        if case .above(let bottom, let minTop) = placement { cardTop = max(minTop, bottom-height.value) }
        frame = NSRect(x: frame.minX, y: cardTop, width: cardWidth, height: max(0, height.value))
        panel.frame = bounds; content.frame = panel.bounds
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: FindBar.radius, continuous: true)
        // Laid out at full height and revealed as the card grows, like the find bar's answer.
        var y = Self.inset.height
        titleLabel.isHidden = !hasTitle
        titleLabel.frame = NSRect(x: Self.inset.width-Self.labelPadding, y: y, width: textWidth+2*Self.labelPadding, height: titleHeight); y += titleHeight
        meta.isHidden = current?.details == nil
        if !meta.isHidden {
            y += Self.titleGap
            meta.frame = NSRect(x: Self.inset.width-Self.metaNudge, y: y, width: textWidth+Self.metaNudge, height: PullRequestMetaRow.height)
            y += PullRequestMetaRow.height
        }
        if hasTitle { y += Self.summaryGap }
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
        // The ⋯ at the right, level with the last status row, the description's last line, or its own row.
        moreButton.isHidden = !showsMore || editing?.field == .summary
        if !moreButton.isHidden {
            let lastRow = [mergeRow, pipelineRow].first { !$0.isHidden }
            var midY: CGFloat
            if let lastRow { midY = lastRow.frame.midY }
            else if moreNeedsRow { midY = (hasSummaryText ? summaryView.frame.maxY : y-Self.pipelineGap)+Self.pipelineGap+StatusLinkRow.height/2 }
            else {
                let manager = summaryView.layoutManager!
                let last = manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs-1, effectiveRange: nil)
                midY = summaryView.frame.minY+last.midY
            }
            midY = round(midY)
            moreButton.frame = NSRect(x: cardWidth-Self.inset.width-18, y: midY-Self.moreSize.height/2,
                                      width: Self.moreSize.width, height: Self.moreSize.height)
        }
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
        // A word on a new line makes room for it.
        if stream.step(at: now) { retarget() }
        paint()
        if showsPipeline != shownPipeline || showsMore != shownMore { retarget() }
        let resting = height.isResting(within: 0.05) && top.isResting(within: 0.05) && !stream.needsFrames
        if resting { link.invalidate(); self.link = nil; height.settle(); top.settle() }
        render()
    }
}

extension PullRequestTooltip: NSTextFieldDelegate, NSTextViewDelegate {
    func controlTextDidChange(_ notification: Notification) { editedTextChanged() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): endEditing(saving: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endEditing(saving: false); return true
        default: return false
        }
    }
    /// Clicking elsewhere keeps the title's edit.
    func controlTextDidEndEditing(_ notification: Notification) { if editing?.field == .title { endEditing(saving: true) } }
    func textDidChange(_ notification: Notification) { editedTextChanged() }
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === summaryView, editing?.field == .summary else { return false }
        switch selector {
        // Return keeps the edit; Shift-Return starts a new line.
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            endEditing(saving: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endEditing(saving: false); return true
        default: return false
        }
    }
    /// Clicking elsewhere keeps the description's edit.
    func textDidEndEditing(_ notification: Notification) { if editing?.field == .summary { endEditing(saving: true) } }
}

/// The card's title: a label until it's double-clicked, then edited in place.
final class CardTitleField: NSTextField {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !isEditable, let onDoubleClick { onDoubleClick(); return }
        super.mouseDown(with: event)
    }
}
