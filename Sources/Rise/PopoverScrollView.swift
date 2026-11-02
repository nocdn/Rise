import AppKit

/// Shortens only the scroll indicator's track, leaving the document viewport
/// and its full scrolling range unchanged inside a rounded popover or card.
class PopoverScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollerInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
}
