import AppKit
import RiseCore

/// One sidebar entry for two pages; each half keeps the existing tab actions.
@MainActor final class SplitTabRow: Surface {
    let group: SplitTabGroup
    let left: TabRow
    let right: TabRow
    let divider = Surface()
    private var selected = false
    private var theme = RiseTheme.neutral
    var dragFill: NSColor? { didSet { update(selected: selected, theme: theme) } }
    var rowHeight: CGFloat {
        left.showsSubtitle || right.showsSubtitle ? TabAppearance.subtitleRowHeight + 8 : TabAppearance.height
    }
    init(group: SplitTabGroup, left: TabRow, right: TabRow) {
        self.group = group; self.left = left; self.right = right
        super.init(radius: TabAppearance.radius)
        layer?.cornerCurve = .continuous
        addSubview(left); addSubview(right); addSubview(divider)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(selected: Bool, theme: RiseTheme) {
        self.selected = selected; self.theme = theme
        fill = selected ? TabAppearance.selectedFill(theme) : dragFill ?? .clear
        layer?.borderWidth = selected ? 0.5 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(theme == .dark ? 0.08 : 0.7).cgColor
        divider.fill = theme.text.withAlphaComponent(0.15)
        divider.isHidden = selected
        setAccessibilityLabel("Split tabs: \(left.titleField.stringValue) and \(right.titleField.stringValue)" + (selected ? ", selected" : ""))
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        let width = (bounds.width-12)/2
        left.frame = NSRect(x: 4, y: 4, width: width, height: bounds.height-8)
        right.frame = NSRect(x: left.frame.maxX+4, y: 4, width: width, height: bounds.height-8)
        divider.frame = NSRect(x: bounds.midX-0.25, y: (bounds.height-16)/2, width: 0.5, height: 16)
    }
}
