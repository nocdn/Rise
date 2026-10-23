import AppKit
import SwiftUI

/// The page bar's zoom button's popover: smaller and larger either side of the zoom, and Reset
/// across under them, in the site controls' buttons.
@MainActor final class ZoomControlsController: NSViewController {
    weak var browser: BrowserController?
    private(set) var smaller: PopoverActionButton!, larger: PopoverActionButton!, reset: PopoverActionButton!
    /// The zoom between the buttons, its digits rolling to the new value like SwiftUI's numeric text.
    private let zoom = ZoomPercent()
    private(set) var percent: NSView!
    init(browser: BrowserController) { self.browser = browser; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        guard let browser else { view = NSView(); return }
        let theme = browser.theme, scale = SiteControlsLayout.scale
        let padding: CGFloat = 10, gap: CGFloat = 6, button = NSSize(width: 52*scale, height: 34*scale), label: CGFloat = 50
        let width = 2*padding+2*button.width+2*gap+label
        smaller = PopoverActionButton(symbol: "minus", size: 15, scale: scale, title: "Zoom Out", theme: theme) { [weak browser] in browser?.zoomOut() }
        larger = PopoverActionButton(symbol: "plus", size: 15, scale: scale, title: "Zoom In", theme: theme) { [weak browser] in browser?.zoomIn() }
        reset = PopoverActionButton(label: "Reset", scale: scale, title: "Actual Size", theme: theme) { [weak browser] in
            browser?.actualSize(); browser?.zoomPopover.close()
        }
        // Lighter than the shared buttons' semibold.
        reset.attributedTitle = NSAttributedString(string: "Reset", attributes: [
            .font: Self.font(NSFont.systemFont(ofSize: 13*scale)), .foregroundColor: theme.text,
            .paragraphStyle: { let style = NSMutableParagraphStyle(); style.alignment = .center; return style }()])
        smaller.frame = NSRect(x: padding, y: padding, width: button.width, height: button.height)
        larger.frame = NSRect(x: width-padding-button.width, y: padding, width: button.width, height: button.height)
        percent = NSHostingView(rootView: ZoomPercentLabel(zoom: zoom, font: Self.font(.monospacedDigitSystemFont(ofSize: 13, weight: .regular)), color: Color(nsColor: theme.text)))
        percent.frame = NSRect(x: smaller.frame.maxX+gap, y: padding, width: label, height: button.height)
        reset.frame = NSRect(x: padding, y: smaller.frame.maxY+8, width: width-2*padding, height: button.height)
        view = PopoverContentView(frame: NSRect(x: 0, y: 0, width: width, height: reset.frame.maxY+padding))
        [smaller, larger, percent, reset].forEach { view.addSubview($0!) }
        refresh()
    }
    /// SF Pro at weight 450, between regular and medium.
    private static func font(_ font: NSFont) -> NSFont {
        let weight = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: [NSNumber(value: 0x7767_6874): 450]] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize, nil, weight) as NSFont
    }
    /// The zoom now, with each way off at its end.
    func refresh() {
        guard isViewLoaded, let zoom = browser?.selectedTab?.page.zoom else { return }
        if self.zoom.value != zoom {
            let first = self.zoom.value == nil
            withAnimation(first || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy(duration: 0.3)) { self.zoom.value = zoom }
        }
        smaller.isEnabled = zoom > PageZoom.levels.first!+0.001; larger.isEnabled = zoom < PageZoom.levels.last!-0.001
        smaller.alphaValue = smaller.isEnabled ? 1 : 0.4; larger.alphaValue = larger.isEnabled ? 1 : 0.4
    }
}

final class ZoomPercent: ObservableObject {
    @Published var value: CGFloat?
}

struct ZoomPercentLabel: View {
    @ObservedObject var zoom: ZoomPercent
    let font: NSFont, color: Color
    var body: some View {
        Text(zoom.value.map(PageZoom.text) ?? "")
            .font(Font(font as CTFont)).monospacedDigit().foregroundStyle(color)
            .contentTransition(.numericText(value: Double(zoom.value ?? 1)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor extension BrowserController {
    var zoomControls: ZoomControlsController? { zoomPopover.isShown ? zoomPopover.contentViewController as? ZoomControlsController : nil }
    func showZoomControls() {
        if zoomPopover.isShown { zoomPopover.close(); return }
        guard selectedTab != nil else { return }
        siteControlsPopover.close(); siteInfoPopover.close()
        let controller = ZoomControlsController(browser: self)
        zoomPopover.behavior = .transient
        zoomPopover.appearance = theme.appearance
        zoomPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        zoomPopover.contentViewController = controller
        zoomPopover.contentSize = controller.view.frame.size
        zoomPopover.show(relativeTo: selectedBar.zoomButton.bounds, of: selectedBar.zoomButton, preferredEdge: .maxY)
    }
}
