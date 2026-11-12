import AppKit

/// The AI chat panel's measurements and colors, taken from Dia's chat panel at 2× (see
/// `docs/AIChat.md`): answers in 15 pt on 25 pt lines, questions in 14 pt on 24, typed in 16,
/// content 20 pt in from the panel's left, the question's bubble and the attached pages 11 pt in
/// from its right, and a composer 8 pt in from the panel's sides and bottom. The panel itself
/// opens and closes on DevTools' springs.
enum AIChatStyle {
    /// Dia's default width and the narrowest it can be dragged to.
    static let defaultWidth: CGFloat = 480, minimumWidth: CGFloat = 320
    static let widthKey = "Rise.AIChatWidth"
    static let headerHeight: CGFloat = 48, headerIconMid: CGFloat = 26
    /// Text from the panel's left; bubbles and page chips from its right.
    static let leading: CGFloat = 20, trailing: CGFloat = 11, textTrailing: CGFloat = 20
    /// From the header's bottom to the first message.
    static let contentTop: CGFloat = 15
    static let fontSize: CGFloat = 15, lineHeight: CGFloat = 25, paragraphSpacing: CGFloat = 14
    static let bubbleRadius: CGFloat = 17, bubblePadding = NSSize(width: 16, height: 10.75)
    static let bubbleFontSize: CGFloat = 14, bubbleLineHeight: CGFloat = 24
    static let inputFontSize: CGFloat = 16, inputLineHeight: CGFloat = 24
    /// The caret in the composer, centred on its 24 pt line as Dia's is.
    static let caretSize = NSSize(width: 2, height: 18)
    /// A question's bubble is at most this much of the composer's width.
    static let bubbleWidthFraction: CGFloat = 0.75
    static let chipSize = NSSize(width: 184, height: 54), chipRadius: CGFloat = 12, chipGap: CGFloat = 12
    static let tileSize = NSSize(width: 30.5, height: 38), tileInset = NSSize(width: 8, height: 8), tileRadius: CGFloat = 6
    /// From a question's bubble to "Thinking…" under it, from that to the answer, and from the
    /// answer's last line to its actions.
    static let thoughtGap: CGFloat = 44, answerGap: CGFloat = 12, actionsGap: CGFloat = 12
    /// Between one exchange and the next question.
    static let turnGap: CGFloat = 36
    static let composerInset: CGFloat = 8, composerRadius: CGFloat = 18
    /// One row with the buttons beside the text, or the text over a row of buttons.
    static let compactHeight: CGFloat = 60, expandedHeight: CGFloat = 100
    /// The middle of the text's first line, and of the buttons' row from the bottom.
    static let rowMid: CGFloat = 30
    /// An attached page's chip and the space under it, above the text.
    static let composerChipRow: CGFloat = 70
    static let composerTextLeading: CGFloat = 24.5
    /// The attached pages from the composer's left, where a sent question's bubble starts too.
    static let composerChipInset: CGFloat = 16
    /// Lines the question can grow to before it scrolls.
    static let maximumInputLines = 8
    static let sendSize: CGFloat = 32

    static func font(_ size: CGFloat = fontSize, weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    /// Lines `lineHeight` tall with the text centred in each, as the web lays out a line box.
    static func paragraph(lineHeight: CGFloat = lineHeight, spacing: CGFloat = 0) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
        paragraph.paragraphSpacing = spacing
        return paragraph
    }
    /// TextKit puts a tall line's extra height above the text; this raises it back to the middle.
    static func baselineOffset(_ font: NSFont, lineHeight: CGFloat = lineHeight) -> CGFloat {
        let natural = font.ascender-font.descender
        return max(0, (lineHeight-natural)/2)
    }
    static func attributes(_ font: NSFont = font(), color: NSColor, lineHeight: CGFloat = lineHeight, spacing: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraph(lineHeight: lineHeight, spacing: spacing),
         .baselineOffset: baselineOffset(font, lineHeight: lineHeight)]
    }
}

/// Dia's colors in Light, and their counterparts in Rise's Dark.
struct AIChatColors: Equatable {
    let panel, text, muted, headerIcon, toolbarIcon, placeholder, bubble, chip, tile, tileBorder: NSColor
    let composer, composerBorder, sendOn, sendOnIcon, sendOff, sendOffIcon, actionIcon, hairline, code, hover: NSColor
    /// A page chip's remove button: muted while the pointer is on the page, and high-contrast
    /// while it's on the button.
    let remove, removeIcon, removeHover, removeHoverIcon: NSColor
    let dark: Bool
    init(_ theme: RiseTheme) {
        dark = theme == .dark
        if dark {
            panel = NSColor(hex: 0x1E1E1E); text = NSColor(hex: 0xE4E4E4); muted = NSColor(hex: 0x8F8F8F)
            headerIcon = NSColor(hex: 0x9A9A9A); toolbarIcon = NSColor(hex: 0x767676); placeholder = NSColor(hex: 0x7C7C7C)
            bubble = NSColor(hex: 0x2E2E30); chip = NSColor.white.withAlphaComponent(0.07)
            tile = NSColor(hex: 0x2A2A2A); tileBorder = NSColor.white.withAlphaComponent(0.08)
            composer = NSColor(hex: 0x262626); composerBorder = NSColor.white.withAlphaComponent(0.09)
            sendOn = NSColor(hex: 0xEDEDED); sendOnIcon = NSColor(hex: 0x1A1A1A)
            sendOff = NSColor(hex: 0x333333); sendOffIcon = NSColor(hex: 0x6E6E6E)
            actionIcon = NSColor(hex: 0x6F6F6F); hairline = NSColor.white.withAlphaComponent(0.08)
            code = NSColor.white.withAlphaComponent(0.08); hover = NSColor.white.withAlphaComponent(0.07)
            remove = NSColor(hex: 0x505050); removeIcon = NSColor(hex: 0xF0F0F0)
            removeHover = NSColor(hex: 0xEDEDED); removeHoverIcon = NSColor(hex: 0x121212)
        } else {
            panel = NSColor(hex: 0xFAFAFA); text = NSColor(hex: 0x252525); muted = NSColor(hex: 0x757575)
            headerIcon = NSColor(hex: 0x7C7C7C); toolbarIcon = NSColor(hex: 0xBCBCBC); placeholder = NSColor(hex: 0x989999)
            bubble = NSColor(hex: 0xF0F1F3); chip = NSColor.black.withAlphaComponent(0.05)
            tile = NSColor(hex: 0xFCFCFC); tileBorder = NSColor(hex: 0xEBEBEB)
            composer = NSColor(hex: 0xFEFFFF); composerBorder = NSColor(hex: 0xEBECEE)
            sendOn = NSColor(hex: 0x262626); sendOnIcon = .white
            sendOff = NSColor(hex: 0xF2F3F3); sendOffIcon = NSColor(hex: 0xB3B4B4)
            actionIcon = NSColor(hex: 0xAEAEAE); hairline = NSColor(hex: 0xE4E4E4)
            code = NSColor.black.withAlphaComponent(0.045); hover = NSColor.black.withAlphaComponent(0.05)
            remove = NSColor(hex: 0xC7C7C7); removeIcon = NSColor(hex: 0x151515)
            removeHover = NSColor(hex: 0x171717); removeHoverIcon = .white
        }
    }
}
