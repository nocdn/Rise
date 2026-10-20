import AppKit

/// The pull request card's file count, hovered: a small card off its bottom right corner with the
/// lines added and removed in code, tests, mocks and generated files, then in all, as T3 Code
/// shows them. It comes out of that corner as a pinned tab's card comes out of its tile, and
/// takes no clicks, so the card under it keeps the pointer.
@MainActor final class ChangeBreakdownCard: FlippedView {
    static let inset = NSSize(width: 12, height: 10)
    static let rowHeight: CGFloat = 18, rowGap: CGFloat = 4, columnGap: CGFloat = 16, countGap: CGFloat = 10
    static let dividerGap: CGFloat = 6
    /// Off the file count's bottom right corner, across and down.
    static let gap: CGFloat = 4
    static let labelFont = NSFont.systemFont(ofSize: 13)
    static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let loadingText = "Loading breakdown"

    private let panel = Surface(radius: FindBar.radius)
    private let rows = Rows()
    private(set) var isShown = false
    /// The count's bottom right corner, in the card's own coordinates.
    private var growsFrom = CGPoint.zero
    private var exits = 0

    init() {
        super.init(frame: .zero)
        isHidden = true
        wantsLayer = true; layer?.masksToBounds = false; clipsToBounds = false
        // The pull request card's surface, smaller.
        panel.layer?.cornerCurve = .continuous; panel.layer?.borderWidth = 0.5
        panel.layer?.shadowColor = NSColor.black.cgColor; panel.layer?.shadowOpacity = 0.12
        panel.layer?.shadowRadius = 10; panel.layer?.shadowOffset = NSSize(width: 0, height: -3)
        panel.clipsToBounds = false
        panel.addSubview(rows); addSubview(panel)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Its top left corner just off `link`'s bottom right one (the file count, in the superview),
    /// kept inside `area`. Nothing shows with no split and none on the way.
    func show(_ breakdown: ChangeBreakdown?, loading: Bool, total: ChangeBreakdown.Lines, below link: NSRect, in area: NSRect,
              theme: RiseTheme, background: NSColor, text: NSColor) {
        guard breakdown != nil || loading else { hide(); return }
        rows.breakdown = breakdown; rows.total = total; rows.theme = theme; rows.text = text
        panel.fill = background; panel.layer?.borderColor = theme.border.cgColor
        let size = rows.size
        let width = size.width+2*Self.inset.width, height = size.height+2*Self.inset.height
        let x = max(area.minX+8, min(link.maxX+Self.gap, area.maxX-8-width))
        let y = min(link.maxY+Self.gap, area.maxY-8-height)
        let appearing = !isShown
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = NSRect(x: x, y: y, width: width, height: height)
        panel.frame = bounds
        rows.frame = NSRect(x: Self.inset.width, y: Self.inset.height, width: size.width, height: size.height)
        CATransaction.commit()
        rows.needsDisplay = true
        growsFrom = CGPoint(x: link.maxX-x, y: link.maxY-y)
        guard appearing else { return }
        isShown = true; exits += 1; isHidden = false
        CardMotionAnimator.cancelOut(self)
        CardMotionAnimator.animateIn(self, CardMotion.selected, tab: growsFrom)
    }
    /// Back into the count's corner, or at once.
    func hide(animated: Bool = true) {
        guard isShown else { return }
        isShown = false
        guard animated else { CardMotionAnimator.cancelOut(self); isHidden = true; return }
        let exit = exits
        CardMotionAnimator.animateOut(self, CardMotion.selected, tab: growsFrom) { [weak self] in
            if let self, !self.isShown, self.exits == exit { self.isHidden = true }
        }
    }

    /// Kind, lines added and lines removed, a row each, then a line and the total when there's
    /// more than one kind; a lone kind is the total already.
    final class Rows: FlippedView {
        var breakdown: ChangeBreakdown?, total = ChangeBreakdown.Lines(), theme = RiseTheme.neutral, text = NSColor.labelColor
        private var dark: Bool { theme == .dark }
        private var lines: [(String, ChangeBreakdown.Lines)] {
            guard let breakdown else { return [] }
            return ChangeBreakdown.Kind.allCases.compactMap { breakdown[$0].isEmpty ? nil : ($0.title, breakdown[$0]) }
        }
        private var showsTotal: Bool { lines.count != 1 }
        /// What's drawn: the kinds, and the total when it says something they don't.
        private var shown: [(String, ChangeBreakdown.Lines)] { showsTotal ? lines+[("Total", total)] : lines }
        private func label(_ string: String, color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: ChangeBreakdownCard.labelFont, .foregroundColor: color])
        }
        private func count(_ string: String, color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: ChangeBreakdownCard.countFont, .foregroundColor: color])
        }
        private func added(_ lines: ChangeBreakdown.Lines) -> NSAttributedString { count("+\(lines.additions)", color: PullRequestPalette.added(dark: dark)) }
        private func removed(_ lines: ChangeBreakdown.Lines) -> NSAttributedString { count("−\(lines.deletions)", color: PullRequestPalette.deleted(dark: dark)) }
        private var columns: (label: CGFloat, added: CGFloat, removed: CGFloat) {
            let all = shown
            return (ceil(all.map { label($0.0, color: text).size().width }.max() ?? 0),
                    ceil(all.map { added($0.1).size().width }.max() ?? 0), ceil(all.map { removed($0.1).size().width }.max() ?? 0))
        }
        var size: NSSize {
            guard breakdown != nil else { return NSSize(width: ceil(label(ChangeBreakdownCard.loadingText, color: text).size().width), height: ChangeBreakdownCard.rowHeight) }
            let columns = columns, card = ChangeBreakdownCard.self
            let kinds = CGFloat(lines.count), rows = CGFloat(shown.count)
            return NSSize(width: columns.label+card.columnGap+columns.added+card.countGap+columns.removed,
                          height: rows*card.rowHeight+max(0, kinds-1)*card.rowGap+(showsTotal && kinds > 0 ? 2*card.dividerGap+1 : 0))
        }
        override func draw(_ dirtyRect: NSRect) {
            let card = ChangeBreakdownCard.self
            func centred(_ string: NSAttributedString, x: CGFloat, y: CGFloat) {
                string.draw(at: NSPoint(x: x, y: y+(card.rowHeight-string.size().height)/2))
            }
            guard breakdown != nil else { centred(label(card.loadingText, color: theme.muted), x: 0, y: 0); return }
            let columns = columns, addedRight = columns.label+card.columnGap+columns.added, removedRight = bounds.width
            var y: CGFloat = 0
            func row(_ name: String, _ lines: ChangeBreakdown.Lines) {
                centred(label(name, color: text), x: 0, y: y)
                let plus = added(lines), minus = removed(lines)
                centred(plus, x: addedRight-ceil(plus.size().width), y: y)
                centred(minus, x: removedRight-ceil(minus.size().width), y: y)
            }
            for (index, (name, lines)) in lines.enumerated() {
                row(name, lines); y += card.rowHeight+(index < self.lines.count-1 ? card.rowGap : 0)
            }
            guard showsTotal else { return }
            if !lines.isEmpty {
                y += card.dividerGap
                theme.text.withAlphaComponent(dark ? 0.14 : 0.1).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
                y += 1+card.dividerGap
            }
            row("Total", total)
        }
    }
}
