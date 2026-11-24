import AppKit

/// What pages report as they load (progress, title, address, loading, history and sound) comes in
/// runs, several a frame. Each would otherwise run all of `update()`, the sidebar, the window's
/// layout, the hover cards and the save; they wait instead for one update just before Core
/// Animation draws, so none shows a frame late. Progress alone only moves the loading lines.
@MainActor extension BrowserController {
    enum PendingUpdate: Comparable { case progress, full }
    func setNeedsUpdate(_ level: PendingUpdate) {
        let wasPending = pendingUpdate != nil
        pendingUpdate = max(pendingUpdate ?? level, level)
        guard !wasPending else { return }
        // Before Core Animation's own commit, which runs at the same points in the run loop.
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, false, Self.updateObserverOrder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.runPendingUpdate() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    /// Core Animation commits at 2,000,000.
    static let updateObserverOrder = 1_900_000
    func runPendingUpdate() {
        guard let level = pendingUpdate else { return }
        pendingUpdate = nil
        switch level {
        case .full: update()
        case .progress: updateLoadingProgress()
        }
    }
    /// The page bars' loading lines, which show how far pages have loaded; the sidebar doesn't.
    private func updateLoadingProgress() {
        updatePlainBar()
    }
}
