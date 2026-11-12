import AppKit

enum TabScrollModifier: String, CaseIterable {
    case option, control, command, off
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .off: return []
        }
    }
    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        case .off: return "Off"
        }
    }
}

/// A scroll chooses only a sidebar highlight. Releasing the modifier shows that tab, once;
/// neither the pages nor their hover cards are visited on the way.
@MainActor final class TabScrollSelection {
    let arrow = TabScrollArrow()
    var candidate: UUID?, source: UUID?
    var held: NSEvent.ModifierFlags = []
    var distance: CGFloat = 0
    var originalOffset = NSPoint.zero
    var openedSidebar = false
    var cancelledUntilRelease: NSEvent.ModifierFlags = []
    var swallowsMomentum = false, swallowsTrackpadTail = false, swallowsEscapeUp = false
    /// A flick carries on through the tabs on AppKit's momentum, as the Now Playing bar's scrub
    /// does. Letting go of the key mid-glide switches where it comes to rest.
    var gliding = false, liftedAt: CFTimeInterval = -.infinity, commitsWhenStill = false
    var settle: DispatchWorkItem?
    /// The last trackpad event's time, and the fingers' smoothed speed, in points a second.
    var lastTime: TimeInterval?, speed: CGFloat = 0
    static let pointsPerTab: CGFloat = 36
    /// A finger lifted this recently may still be followed by its momentum.
    static let momentumGap: CFTimeInterval = 0.15
}

/// Pointer-style acceleration for the trackpad: a gain on each movement that grows with its speed.
enum TabScrollAcceleration {
    /// The speed moved one for one, in points a second; slower moves less, faster more.
    static let neutralSpeed: CGFloat = 1000
    /// How steeply the gain follows speed, and how far it can go either way.
    static let exponent: CGFloat = 0.7
    static let minimumGain: CGFloat = 0.3, maximumGain: CGFloat = 3
    /// A trackpad reports about every 8 to 16 ms; gaps outside this range are clamped.
    static let shortestGap: TimeInterval = 1.0/240, longestGap: TimeInterval = 0.1
    static let smoothing: CGFloat = 0.5
    static func gain(speed: CGFloat) -> CGFloat {
        min(maximumGain, max(minimumGain, pow(max(0, speed)/neutralSpeed, exponent)))
    }
}

@MainActor extension BrowserController {
    static let tabScrollModifierKey = "Rise.TabScrollModifier"
    var tabScrollModifier: TabScrollModifier {
        preferences.string(forKey: Self.tabScrollModifierKey).flatMap(TabScrollModifier.init(rawValue:)) ?? .option
    }
    func setTabScrollModifier(_ modifier: TabScrollModifier) {
        cancelTabScroll()
        preferences.set(modifier.rawValue, forKey: Self.tabScrollModifierKey)
    }
    var isScrollingTabs: Bool { tabScroll.candidate != nil }

    /// Before the page, history swipes and keyboard shortcuts. Modifier releases still reach
    /// the page, so its own Option state cannot be left held after choosing a tab.
    func handleTabScrollEvent(_ event: NSEvent) -> Bool {
        let choice = tabScroll
        if event.type == .keyUp, event.keyCode == 53, choice.swallowsEscapeUp {
            choice.swallowsEscapeUp = false; return true
        }
        if event.type == .flagsChanged {
            if isScrollingTabs {
                if !event.modifierFlags.isSuperset(of: choice.held) { commitWhenStill() }
                else if event.modifierFlags.intersection(KeyboardShortcut.modifierMask) != choice.held { cancelTabScroll() }
            }
            if !event.modifierFlags.isSuperset(of: choice.cancelledUntilRelease) { choice.cancelledUntilRelease = [] }
            return false
        }
        if event.type == .keyDown, isScrollingTabs {
            let escape = event.keyCode == 53
            cancelTabScroll()
            if escape { choice.swallowsEscapeUp = true }
            return escape
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            cancelTabScroll(); return false
        }
        guard event.type == .scrollWheel else { return false }
        if !event.momentumPhase.isEmpty {
            // A flick's momentum glides on through the tabs; once you've picked one, it
            // must not scroll that tab's page either.
            guard isScrollingTabs else { return choice.swallowsMomentum }
            choice.settle?.cancel(); choice.settle = nil
            moveTabScrollCandidate(by: event.scrollingDeltaY, precise: true, at: event.timestamp)
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                choice.gliding = false
                if choice.commitsWhenStill { finishTabScroll(commit: true) }
            } else {
                choice.gliding = true
                if choice.commitsWhenStill { scheduleTabScrollSettle() }
            }
            return true
        }
        // A new gesture after letting go mid-glide lands the choice first.
        if choice.commitsWhenStill { finishTabScroll(commit: true) }
        if event.phase.contains(.began), !isScrollingTabs {
            choice.swallowsTrackpadTail = false; choice.swallowsMomentum = false
        }
        if !isScrollingTabs, choice.swallowsTrackpadTail, !event.phase.isEmpty {
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { choice.swallowsTrackpadTail = false }
            return true
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { choice.swallowsTrackpadTail = false }
        if event.phase.contains(.cancelled) {
            let consumed = isScrollingTabs || choice.swallowsMomentum
            cancelTabScroll(); return consumed
        }
        let moves = event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0
        if moves || event.phase.contains(.began), !isScrollingTabs { choice.swallowsMomentum = false }
        if !choice.cancelledUntilRelease.isEmpty {
            if event.modifierFlags.isSuperset(of: choice.cancelledUntilRelease) {
                choice.swallowsMomentum = true
                if !event.phase.isEmpty { choice.swallowsTrackpadTail = !event.phase.contains(.ended) }
                return true
            }
            choice.cancelledUntilRelease = []
        }
        let modifier = tabScrollModifier.flags
        guard !modifier.isEmpty, event.modifierFlags.intersection(KeyboardShortcut.modifierMask) == modifier else {
            cancelTabScroll(); return false
        }
        if isScrollingTabs {
            if event.phase.contains(.began) { choice.gliding = false; choice.liftedAt = -.infinity; choice.lastTime = nil; choice.speed = 0 }
            // The lift, which moves nothing, may be followed by the flick's momentum.
            if event.phase.contains(.ended) { choice.liftedAt = CACurrentMediaTime() }
        }
        guard moves else { return isScrollingTabs || choice.swallowsMomentum }
        guard isScrollingTabs || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
        if !isScrollingTabs {
            guard let window, window.attachedSheet == nil,
                  !isSwitchingTabs, !palette.isPresented, !sidebar.isSearchingTabs, shortcutRecordingID == nil,
                  extensionPopup == nil, sidebar.drag == nil, sidebar.pinnedDrag == nil,
                  !sidebar.rows.values.contains(where: \.isRenaming), let selectedID,
                  let first = sidebar.scrollTabIDs.first, sidebar.scrollTabIDs.count > 1 || first != selectedID else { return false }
            // From the current tab, or, from a pinned one, the list's first tab.
            let start = sidebar.scrollTabIDs.contains(selectedID) ? selectedID : first
            choice.source = selectedID; choice.candidate = start; choice.held = modifier; choice.distance = 0
            choice.lastTime = nil; choice.speed = 0
            choice.originalOffset = sidebar.scroll.contentView.bounds.origin
            choice.openedSidebar = !isSidebarShown
            historySwipe.cancel(); tabPressed(); hideLinkStatus()
            if !sidebarVisible { revealFloatingSidebar() }
            sidebar.showScrollFocus(start)
        }
        choice.swallowsMomentum = true
        if !event.phase.isEmpty { choice.swallowsTrackpadTail = !event.phase.contains(.ended) }
        moveTabScrollCandidate(by: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, at: event.timestamp)
        return true
    }

    /// The tab highlight moves opposite to ordinary list scrolling. On a trackpad it's accelerated
    /// as the pointer is: slow, careful movement steps through few tabs however far it goes, and
    /// quick movement (and a flick's momentum) through more for the same distance.
    private func moveTabScrollCandidate(by delta: CGFloat, precise: Bool, at time: TimeInterval) {
        let choice = tabScroll
        let steps: Int
        if precise {
            // How fast the fingers move, smoothed over a few events so one jumpy one doesn't count.
            // A gesture's first event has nothing to time it against, so it moves one for one.
            let speed = choice.lastTime.map { abs(delta)/min(TabScrollAcceleration.longestGap, max(TabScrollAcceleration.shortestGap, time-$0)) }
                ?? TabScrollAcceleration.neutralSpeed
            choice.lastTime = time
            choice.speed = choice.speed == 0 ? speed : choice.speed+(speed-choice.speed)*TabScrollAcceleration.smoothing
            let delta = delta*TabScrollAcceleration.gain(speed: choice.speed)
            if delta * choice.distance < 0 { choice.distance = 0 }
            choice.distance += delta
            // A hair's allowance, so a whole tab's distance isn't lost to rounding.
            steps = Int((choice.distance+(choice.distance < 0 ? -0.01 : 0.01)) / TabScrollSelection.pointsPerTab)
            choice.distance -= CGFloat(steps) * TabScrollSelection.pointsPerTab
        } else {
            steps = delta == 0 ? 0 : delta > 0 ? 1 : -1
        }
        guard steps != 0, let candidate = choice.candidate, let index = sidebar.scrollTabIDs.firstIndex(of: candidate) else { return }
        let ids = sidebar.scrollTabIDs
        choice.candidate = ids[min(max(0, index + steps), ids.count-1)]
        sidebar.showScrollFocus(choice.candidate)
    }
    /// Letting go of the key switches at once, unless a flick is still gliding, or may be about
    /// to: then where it comes to rest.
    private func commitWhenStill() {
        let choice = tabScroll
        let mayGlide = choice.gliding || CACurrentMediaTime()-choice.liftedAt < TabScrollSelection.momentumGap
        guard mayGlide, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { finishTabScroll(commit: true); return }
        choice.commitsWhenStill = true
        scheduleTabScrollSettle()
    }
    private func scheduleTabScrollSettle() {
        let choice = tabScroll
        choice.settle?.cancel()
        let settle = DispatchWorkItem { [weak self] in self?.finishTabScroll(commit: true) }
        choice.settle = settle
        DispatchQueue.main.asyncAfter(deadline: .now()+TabScrollSelection.momentumGap, execute: settle)
    }

    func cancelTabScroll() { finishTabScroll(commit: false) }
    private func finishTabScroll(commit: Bool) {
        let choice = tabScroll
        choice.settle?.cancel(); choice.settle = nil
        choice.commitsWhenStill = false; choice.gliding = false; choice.liftedAt = -.infinity
        guard let id = choice.candidate else { return }
        if !commit { choice.cancelledUntilRelease = choice.held }
        choice.candidate = nil; choice.source = nil; choice.distance = 0
        sidebar.showScrollFocus(nil)
        if !commit {
            sidebar.scroll.contentView.scroll(to: choice.originalOffset)
            sidebar.scroll.reflectScrolledClipView(sidebar.scroll.contentView)
        }
        if choice.openedSidebar { choice.openedSidebar = false; tuckFloatingSidebar() }
        if commit, id != selectedID, tabs.contains(where: { $0.id == id }) { select(id) }
        else { DispatchQueue.main.async { [weak self] in self?.applyPendingSharedTabs() } }
    }

    /// Background tab changes keep the highlight, but cannot leave it pointing to a closed tab.
    func refreshTabScroll() {
        guard let id = tabScroll.candidate else { return }
        guard selectedID == tabScroll.source, sidebar.scrollTabIDs.contains(id) else { cancelTabScroll(); return }
        sidebar.showScrollFocus(id, reveal: false)
    }
}

@MainActor extension SidebarView {
    /// The list's tabs in order, a split's left half before its right. Pinned tabs aren't among
    /// them: they're a click away at the top.
    var scrollTabIDs: [UUID] {
        displayedRows.flatMap { row -> [UUID] in
            if let pair = row as? SplitTabRow { return [pair.left.tabID, pair.right.tabID] }
            return (row as? TabRow).map { [$0.tabID] } ?? []
        }
    }
    func showScrollFocus(_ id: UUID?, reveal: Bool = true) {
        defer { onScrollFocusChanged?() }
        scrollFocusID = id
        for row in rows.values { row.scrollFocus = id.map { $0 == row.tabID } }
        for tile in pinnedView.tiles.values { tile.scrollFocus = id.map { $0 == tile.tabID } }
        updateScrollCues()
        guard reveal, let id, let row = displayedRow(for: id) else { return }
        guard let index = displayedRows.firstIndex(where: { $0 === row }) else { return }
        let clip = scroll.contentView
        // Keep two actual rows beyond the highlight in either direction. At the ends there
        // are fewer to keep, so the first and last tabs can still reach the viewport's edges.
        // A small viewport keeps as much context as fits, without scrolling back and forth.
        let before = displayedRows[max(0, index-2)].frame, after = displayedRows[min(displayedRows.count-1, index+2)].frame
        let room = max(0, (clip.bounds.height-row.frame.height)/2)
        let top = min(room, row.frame.minY-before.minY+SidebarScrollCues.visibleMargin)
        let bottom = min(room, after.maxY-row.frame.maxY+SidebarScrollCues.visibleMargin)
        let frame = NSRect(x: row.frame.minX, y: row.frame.minY-top, width: row.frame.width, height: row.frame.height+top+bottom)
        var y = clip.bounds.minY
        if frame.minY < y { y = frame.minY }
        else if frame.maxY > clip.bounds.maxY { y = frame.maxY-clip.bounds.height }
        y = min(max(0, y), max(0, rowsHost.bounds.height-clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
    }
}
