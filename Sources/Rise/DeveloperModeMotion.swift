import AppKit

/// One clock morphs the page bar into developer mode's bar and back. The two are the same height
/// in the same place, so the page doesn't move: the page bar's colour eases away over the whole
/// way to show developer mode's stripes under it, its address is exchanged for developer mode's
/// as a notice is, and developer mode's buttons come in one after another. The sidebar, back,
/// forward, reload and extension buttons stay put throughout.
@MainActor final class DeveloperModeMotion {
    static let duration = 0.28
    static let subtitleFadeKey = "Rise.DeveloperURLFade"
    private static let easing = CubicEasing(0.2, 0.7, 0.2, 1)
    private(set) var currentProgress: CGFloat?
    private var tabID: UUID?
    private var target: CGFloat = 0
    private var timer: Timer?
    private let layout: () -> Void
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(layout: @escaping () -> Void) { self.layout = layout }
    func start(tabID: UUID, from: CGFloat, enabled: Bool, animated: Bool) {
        cancel()
        target = enabled ? 1 : 0
        guard animated, !reduceMotion(), from != target else { return }
        self.tabID = tabID; currentProgress = from
        // A reversal takes as long as the way it has come.
        let duration = Self.duration*Double(max(0.4, abs(target-from)))
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0/120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime-started)/duration)
                self.currentProgress = from + (self.target-from)*CGFloat(Self.easing(progress))
                if progress >= 1 { self.cancel() }
                self.layout()
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    /// How far into developer mode the tab's bar shows: 0 for the page bar, 1 for developer mode's.
    func progress(for tabID: UUID?, enabled: Bool) -> CGFloat {
        let target: CGFloat = enabled ? 1 : 0
        guard let currentProgress else { return target }
        guard self.tabID == tabID, self.target == target, !reduceMotion() else { cancel(); return target }
        return currentProgress
    }
    func cancel() { timer?.invalidate(); timer = nil; currentProgress = nil; tabID = nil }

    /// How much the page bar's colour still covers developer mode's stripes: going over the whole
    /// way, so they neither pop in nor out, and from the first frame, so it starts at once.
    static func covering(_ progress: CGFloat) -> CGFloat { 1-min(1, max(0, progress)) }
    /// What shows of the page bar's field buttons: gone by six tenths of the way.
    static func leaving(_ progress: CGFloat) -> CGFloat { 1-min(1, max(0, progress/0.6)) }
    /// What shows of developer mode's parts: from four tenths of the way, each `delay` later.
    static func arriving(_ progress: CGFloat, delay: CGFloat = 0) -> CGFloat {
        let start = 0.4+delay
        return min(1, max(0, (progress-start)/(1-start)))
    }

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
