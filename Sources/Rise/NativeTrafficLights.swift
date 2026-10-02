import AppKit
import CoreImage

/// Apply a resting gray treatment to the actual system controls. Neither their
/// enabled state nor their native actions/hierarchy change on hover.
@MainActor final class NativeTrafficLights: NSObject {
    private struct ButtonState {
        weak var button: NSButton?
        let originalFilters: [CIFilter]
        let gray: CIFilter
    }
    private weak var window: NSWindow?
    private weak var trackingParent: NSView?
    private(set) var trackingArea: NSTrackingArea?
    private var states: [ButtonState] = []
    private var theme: RiseTheme?
    private var visible = false
    private var stopped = false
    private(set) var isHovering = false

    init(window: NSWindow) { self.window = window; super.init() }

    func update(visible: Bool, theme: RiseTheme) {
        guard !stopped, let window else { return }
        self.visible = visible
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        if self.theme != theme || buttons.map(ObjectIdentifier.init) != states.compactMap({ $0.button.map(ObjectIdentifier.init) }) {
            restoreFilters()
            states = buttons.map { button in
                let filter = CIFilter(name: "CIColorControls")!
                filter.setDefaults(); filter.setValue(0, forKey: kCIInputSaturationKey)
                filter.setValue(0.3, forKey: kCIInputContrastKey)
                filter.setValue(theme == .dark ? -0.22 : 0.20, forKey: kCIInputBrightnessKey)
                let state = ButtonState(button: button, originalFilters: button.contentFilters, gray: filter)
                button.wantsLayer = true
                return state
            }
            self.theme = theme
        }
        guard visible, let parent = buttons.first?.superview, buttons.allSatisfy({ $0.superview === parent && !$0.isHidden }) else {
            removeTracking(); setHovered(false); return
        }
        let rect = buttons.reduce(NSRect.null) { $0.union($1.convert($1.bounds, to: parent)) }.insetBy(dx: -4, dy: -4)
        if trackingParent !== parent || trackingArea?.rect != rect {
            removeTracking()
            let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag], owner: self)
            parent.addTrackingArea(area); trackingParent = parent; trackingArea = area
        }
        let pointer = parent.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(window.isVisible && rect.contains(pointer))
    }
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { setHovered(true) }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ hovering: Bool) {
        isHovering = visible && hovering
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for state in states {
            guard let button = state.button else { continue }
            let filters = isHovering ? state.originalFilters : state.originalFilters + [state.gray]
            if button.contentFilters != filters { button.contentFilters = filters }
        }
        CATransaction.commit()
    }
    func detach() { removeTracking(); restoreFilters(); states = []; visible = false; isHovering = false; stopped = true }
    private func restoreFilters() {
        for state in states { state.button?.contentFilters = state.originalFilters }
    }
    private func removeTracking() {
        if let area = trackingArea { trackingParent?.removeTrackingArea(area) }
        trackingArea = nil; trackingParent = nil
    }
    deinit {
        // Owned exclusively by the AppKit window controller on the main actor.
        MainActor.assumeIsolated { removeTracking(); restoreFilters() }
    }
}
