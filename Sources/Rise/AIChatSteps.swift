import AppKit
import SwiftUI

/// The answer's first line: "Thinking…" while the model thinks, shimmering, and how long it has
/// thought once it answers or calls a tool. Each change plays SwiftUI's numeric text transition,
/// the letters that differ rolling into the new ones, so "Thinking…" turns into "Thought for 5
/// seconds", and back if the model thinks again after its tools, its seconds counting on.
@MainActor @Observable final class AIChatStatus {
    var text = "Thinking…"
    var shimmering = false
    var muted = Color(nsColor: NSColor(hex: 0x757575))
    var bright = Color(nsColor: NSColor(hex: 0x252525))
}

struct AIChatStatusText: View {
    let status: AIChatStatus
    static let font = Font.system(size: 13, weight: .medium)
    var body: some View {
        Text(status.text)
            .font(Self.font)
            .foregroundStyle(status.muted)
            .contentTransition(.numericText())
            .overlay {
                if status.shimmering {
                    AIChatShine(color: status.bright)
                        .mask { Text(status.text).font(Self.font) }
                        .transition(.opacity)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The shimmer the find bar's "Thinking…" had (`InputShimmer`): a bright band 60 pt wide sweeping
/// over the muted text once a second, in 30 steps.
struct AIChatShine: View {
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: InputShimmer.period)/InputShimmer.period
                let stepped = floor(cycle*InputShimmer.steps)/InputShimmer.steps
                let band: CGFloat = 60
                LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band, height: proxy.size.height)
                    .offset(x: -band+(proxy.size.width+band)*stepped)
            }
        }
    }
}

/// The status line in the answer's AppKit layout.
@MainActor final class AIChatStatusView: NSView {
    let status = AIChatStatus()
    private let host: NSHostingView<AIChatStatusText>
    private var shimmerStart: DispatchWorkItem?
    override init(frame: NSRect) {
        host = NSHostingView(rootView: AIChatStatusText(status: status))
        super.init(frame: frame)
        host.sizingOptions = []
        addSubview(host)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); host.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var text: String { status.text }

    func applyColors(_ colors: AIChatColors) {
        status.muted = Color(nsColor: colors.muted); status.bright = Color(nsColor: colors.text)
    }
    /// Changes to `text`, rolling into it unless `animated` is off or motion is reduced, and
    /// shimmering when `thinking`, once the letters have settled.
    func show(_ text: String, thinking: Bool, animated: Bool = true) {
        shimmerStart?.cancel(); shimmerStart = nil
        setAccessibilityLabel(text)
        let animates = animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard text != status.text || thinking != status.shimmering else { return }
        if animates {
            withAnimation(.smooth(duration: 0.45)) { status.text = text }
            withAnimation(.easeOut(duration: 0.2)) { status.shimmering = false }
            if thinking {
                let start = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.2)) { self?.status.shimmering = true } }
                shimmerStart = start
                DispatchQueue.main.asyncAfter(deadline: .now()+0.4, execute: start)
            }
        } else {
            status.text = text; status.shimmering = thinking && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}

/// One step: its page's favicon or a symbol, and a line saying what was done, shimmering while
/// it's being done. A step about a tab or a page takes you there when clicked.
@MainActor final class AIChatStepRow: FlippedView {
    static let height: CGFloat = 20, gap: CGFloat = 6, iconSize: CGFloat = 14, textX: CGFloat = 22
    let id: String
    private(set) var step: AIChatStep
    private let icon = NSImageView(), label = NSTextField(labelWithString: "")
    private let shimmer = InputShimmer()
    /// Comes in, fading and dropping into place.
    var presence = MotionSpring(0)
    var onClick: ((AIChatStep.Target) -> Void)?
    private var colors = AIChatColors(.neutral)
    private var hovering = false

    init(id: String, step: AIChatStep) {
        self.id = id; self.step = step
        super.init(frame: .zero)
        presence.configure(response: 0.3, bounce: 0); presence.target = 1
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = AIChatStyle.font(13); label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        shimmer.field = label; shimmer.bandWidth = 60
        [icon, label, shimmer].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ step: AIChatStep) { let was = self.step; self.step = step; if step != was { apply() } }
    func applyColors(_ colors: AIChatColors) {
        self.colors = colors
        shimmer.baseColor = colors.muted; shimmer.bandColor = colors.text; shimmer.setRestingColor(colors.muted)
        apply()
    }
    private func apply() {
        label.stringValue = step.text
        setAccessibilityLabel(step.text)
        label.textColor = hovering && step.target != nil ? colors.text : colors.muted
        if let favicon = step.favicon {
            icon.image = favicon; icon.contentTintColor = nil
        } else {
            icon.image = NSImage(systemSymbolName: step.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            icon.contentTintColor = colors.muted
        }
        icon.alphaValue = step.state == .failed ? 0.5 : 1
        if step.state == .running { if !shimmer.isRunning { shimmer.start() } } else { shimmer.cancel() }
        window?.invalidateCursorRects(for: self)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: round((bounds.height-Self.iconSize)/2), width: Self.iconSize, height: Self.iconSize)
        let line = ceil(label.intrinsicContentSize.height)
        // A label's own 2 pt inset would put its text right of where it's placed.
        label.frame = NSRect(x: Self.textX-2, y: round((bounds.height-line)/2), width: max(0, bounds.width-Self.textX+2), height: line)
        shimmer.frame = label.frame.insetBy(dx: 0, dy: -3)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; apply() }
    override func mouseExited(with event: NSEvent) { hovering = false; apply() }
    override func resetCursorRects() { if step.target != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let target = step.target, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(target)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let target = step.target else { return false }
        onClick?(target); return true
    }
}
