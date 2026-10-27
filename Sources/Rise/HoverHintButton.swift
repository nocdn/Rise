import AppKit

/// An image button using the same native hover hint as custom-drawn chrome buttons.
final class HoverHintButton: ChromeButton {
    init(image: NSImage, text: String, shortcut: String, action: @escaping () -> Void) {
        super.init(symbol: "questionmark", title: text, action: action)
        self.image = image
        setHoverHint(text, shortcut: shortcut)
    }
    required init?(coder: NSCoder) { fatalError() }
}
