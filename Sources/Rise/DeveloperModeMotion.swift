import AppKit

/// One clock keeps the header and the real WebKit viewport moving together.
@MainActor final class DeveloperModeMotion {
    static let duration = 0.18
    static let headerHeight: CGFloat = 40
    static let subtitleFadeKey = "Rise.DeveloperURLFade"
    private(set) var currentHeight: CGFloat?
    private var tabID: UUID?
    private var target: CGFloat = 0
    private var timer: Timer?
    private let layout: () -> Void
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(layout: @escaping () -> Void) { self.layout = layout }
    func start(tabID: UUID, from: CGFloat, enabled: Bool, animated: Bool) {
        cancel()
        target = enabled ? Self.headerHeight : 0
        guard animated, !reduceMotion(), from != target else { return }
        self.tabID = tabID; currentHeight = from
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0/120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime-started)/Self.duration)
                self.currentHeight = from + (self.target-from)*CGFloat(1-pow(1-progress, 3))
                if progress >= 1 { self.cancel() }
                self.layout()
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func height(for tabID: UUID?, enabled: Bool) -> CGFloat {
        let target = enabled ? Self.headerHeight : 0
        guard let currentHeight else { return target }
        guard self.tabID == tabID, self.target == target, !reduceMotion() else { cancel(); return target }
        return currentHeight
    }
    func cancel() { timer?.invalidate(); timer = nil; currentHeight = nil; tabID = nil }

    static func fade(_ view: NSView, from opacity: Float, to target: CGFloat, at time: CFTimeInterval) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.alphaValue = target
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity; fade.toValue = Float(target)
        fade.duration = duration; fade.beginTime = view.layer?.convertTime(time, from: nil) ?? time
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        view.layer?.add(fade, forKey: subtitleFadeKey)
    }
}
