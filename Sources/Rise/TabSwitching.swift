import AppKit

@MainActor extension BrowserController {
    static let tabSwitcherLimitKey = "Rise.TabSwitcherLimit"
    static let tabSwitcherLimits = 2...15
    /// The most tabs Control-Tab goes through, the current one first: 5 unless set in rise://settings.
    var tabSwitcherLimit: Int {
        let saved = preferences.integer(forKey: Self.tabSwitcherLimitKey)
        return saved == 0 ? 5 : min(Self.tabSwitcherLimits.upperBound, max(Self.tabSwitcherLimits.lowerBound, saved))
    }
    func setTabSwitcherLimit(_ limit: Int) {
        preferences.set(min(Self.tabSwitcherLimits.upperBound, max(Self.tabSwitcherLimits.lowerBound, limit)), forKey: Self.tabSwitcherLimitKey)
        scheduleSwitcherPictures()
    }
    var isSwitchingTabs: Bool { !tabSwitchOrder.isEmpty }
    var tabSwitchCandidate: UUID? { tabSwitchOrder.indices.contains(tabSwitchIndex) ? tabSwitchOrder[tabSwitchIndex] : nil }
    /// Sidebar order, not MRU order. ⌘9 means the ninth tab even when more are open.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }
    @objc func selectNumberedTab(_ item: NSMenuItem) { selectTab(at: item.tag) }
    func handleTabSwitchEvent(_ event: NSEvent) -> Bool {
        if handleSelectionItemUndoKey(event) { return true }
        if handleTabMoveEvent(event) { return true }
        if event.type == .keyDown, let number = (1...9).first(where: { keyboardShortcuts.matches("openPinnedExtension\($0)", event) }),
           openPinnedExtension(at: number-1) { return true }
        if event.type == .keyDown, permissionCoordinator.isShowingPrompt {
            if keyboardShortcuts.matches("allowPermission", event) { permissionCoordinator.resolve(true); return true }
            if keyboardShortcuts.matches("denyPermission", event) { permissionCoordinator.resolve(false); return true }
        }
        if event.type == .keyDown, let number = (1...9).first(where: { keyboardShortcuts.matches("selectTab\($0)", event) }) {
            // Take these before Chromium or an address field handles them. An absent tab is
            // a no-op, so Chromium's own ⌘9 (last tab) cannot select a different one.
            selectTab(at: number-1); return true
        }
        if event.type == .keyDown, keyboardShortcuts.matches("tabSwitcherNext", event) || keyboardShortcuts.matches("tabSwitcherPrevious", event) {
            tabSwitchHeldModifiers = event.modifierFlags.intersection(KeyboardShortcut.modifierMask).subtracting(.shift)
            advanceTabSwitch(keyboardShortcuts.matches("tabSwitcherPrevious", event) ? -1 : 1); return true
        }
        guard isSwitchingTabs else { return false }
        if event.type == .flagsChanged, !tabSwitchHeldModifiers.isEmpty, !event.modifierFlags.isSuperset(of: tabSwitchHeldModifiers) {
            commitTabSwitch(); return false // Forward modifier release to the responder too.
        }
        if event.type == .keyDown {
            if event.keyCode == 53 { cancelTabSwitch(); return true }
            if event.keyCode == 36 { commitTabSwitch(); return true }
            if event.keyCode == 123 || event.keyCode == 124 { advanceTabSwitch(event.keyCode == 123 ? -1 : 1); return true }
        }
        if event.type == .keyUp, keyboardShortcuts.matches("tabSwitcherNext", event) || keyboardShortcuts.matches("tabSwitcherPrevious", event) {
            if tabSwitchHeldModifiers.isEmpty { commitTabSwitch() }; return true
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let point = root.convert(event.locationInWindow, from: nil)
            if tabSwitcher.isHidden || !tabSwitcher.frame.contains(point) {
                let wasVisible = !tabSwitcher.isHidden
                cancelTabSwitch(); return wasVisible
            }
        }
        return false
    }
    func advanceTabSwitch(_ direction: Int) {
        guard tabs.count > 1 else { return }
        let starting = !isSwitchingTabs
        if starting {
            hidePalette(); hideLinkStatus()
            tabSwitchOrder = switcherTabIDs
            tabSwitchIndex = 0
            tabSwitchGeneration += 1
            let generation = tabSwitchGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isSwitchingTabs, self.tabSwitchGeneration == generation else { return }
                self.revealTabSwitcher()
            }
            tabSwitchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tabSwitcherDelay, execute: work)
        }
        tabSwitchIndex = (tabSwitchIndex + direction + tabSwitchOrder.count) % tabSwitchOrder.count
        // Pressed again before it shows, the switcher is wanted: it shows at once.
        if !starting, let work = tabSwitchWork {
            work.cancel(); revealTabSwitcher()
        } else {
            refreshTabSwitcher()
        }
    }
    /// How long Control-Tab waits before showing the switcher: a quick press and release switches
    /// without it, and a second Tab shows it at once.
    static let tabSwitcherDelay: TimeInterval = 0.08
    /// The pointer moving over a card picks it, as Tab does; letting go of Control switches to it.
    func pickTabSwitchCard(_ id: UUID) {
        guard let index = tabSwitchOrder.firstIndex(of: id), index != tabSwitchIndex else { return }
        tabSwitchIndex = index
        refreshTabSwitcher()
    }
    private func revealTabSwitcher() {
        guard isSwitchingTabs else { return }
        tabSwitchWork = nil
        veil.frame = root.bounds
        veil.dismiss = { [weak self] in self?.cancelTabSwitch() }
        root.addSubview(veil, positioned: .above, relativeTo: nil)
        veil.show(theme: theme)
        tabSwitcher.isHidden = false
        root.addSubview(tabSwitcher, positioned: .above, relativeTo: veil)
        refreshTabSwitcher(); selectedTab?.captureThumbnail()
        tabSwitcher.noteShown()
        window?.makeFirstResponder(tabSwitcher)
    }
    func refreshTabSwitcher() {
        guard isSwitchingTabs, !tabSwitcher.isHidden else { return }
        let ordered = tabSwitchOrder.compactMap { id in tabs.first { $0.id == id } }
        tabSwitcher.update(tabs: ordered, selected: tabSwitchCandidate)
        tabSwitcher.place(in: root.bounds)
    }
    func commitTabSwitch(_ clicked: UUID? = nil) {
        guard isSwitchingTabs, let id = clicked ?? tabSwitchCandidate else { return }
        cancelTabSwitch()
        if tabs.contains(where: { $0.id == id }) { select(id) }
    }
    func cancelTabSwitch() {
        guard isSwitchingTabs else { return }
        tabSwitchGeneration += 1; tabSwitchWork?.cancel(); tabSwitchWork = nil
        tabSwitchOrder = []; tabSwitchIndex = 0
        tabSwitcher.dismiss(); veil.hide()
        window?.makeFirstResponder(peekTab?.page.view ?? selectedTab?.page.view)
    }
}
