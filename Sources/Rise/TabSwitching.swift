import AppKit

@MainActor extension BrowserController {
    var isSwitchingTabs: Bool { !tabSwitchOrder.isEmpty }
    var tabSwitchCandidate: UUID? { tabSwitchOrder.indices.contains(tabSwitchIndex) ? tabSwitchOrder[tabSwitchIndex] : nil }
    /// Sidebar order, not MRU order. ⌘9 means the ninth tab even when more are open.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }
    @objc func selectNumberedTab(_ item: NSMenuItem) { selectTab(at: item.tag) }
    func handleTabSwitchEvent(_ event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let characters = event.charactersIgnoringModifiers, characters.count == 1,
           let number = Int(characters), (1...9).contains(number) {
            // Take these before Chromium or an address field handles them. An absent tab is
            // a no-op, so Chromium's own ⌘9 (last tab) cannot select a different one.
            selectTab(at: number-1); return true
        }
        if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.contains(.control),
           event.modifierFlags.intersection([.command, .option]).isEmpty {
            advanceTabSwitch(event.modifierFlags.contains(.shift) ? -1 : 1); return true
        }
        guard isSwitchingTabs else { return false }
        if event.type == .flagsChanged, !event.modifierFlags.contains(.control) {
            commitTabSwitch(); return false // Forward modifier release to the responder too.
        }
        if event.type == .keyDown {
            if event.keyCode == 53 { cancelTabSwitch(); return true }
            if event.keyCode == 36 { commitTabSwitch(); return true }
            if event.keyCode == 123 || event.keyCode == 124 { advanceTabSwitch(event.keyCode == 123 ? -1 : 1); return true }
        }
        if event.type == .keyUp, event.keyCode == 48 { return true }
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
        if !isSwitchingTabs {
            hidePalette(); hideLinkStatus()
            let ids = tabs.map(\.id)
            tabSwitchOrder = recentTabIDs.filter { ids.contains($0) }
            tabSwitchOrder += ids.filter { !tabSwitchOrder.contains($0) }
            if let selectedID {
                tabSwitchOrder.removeAll { $0 == selectedID }; tabSwitchOrder.insert(selectedID, at: 0)
            }
            tabSwitchIndex = 0
            tabSwitchGeneration += 1
            let generation = tabSwitchGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isSwitchingTabs, self.tabSwitchGeneration == generation else { return }
                self.revealTabSwitcher()
            }
            tabSwitchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        tabSwitchIndex = (tabSwitchIndex + direction + tabSwitchOrder.count) % tabSwitchOrder.count
        refreshTabSwitcher()
    }
    private func revealTabSwitcher() {
        guard isSwitchingTabs else { return }
        tabSwitchWork = nil
        tabSwitchBackdrop.frame = root.bounds; tabSwitchBackdrop.isHidden = false
        root.addSubview(tabSwitchBackdrop, positioned: .above, relativeTo: nil)
        tabSwitcher.isHidden = false
        root.addSubview(tabSwitcher, positioned: .above, relativeTo: tabSwitchBackdrop)
        refreshTabSwitcher(); selectedTab?.captureThumbnail()
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
        tabSwitcher.dismiss(); tabSwitchBackdrop.isHidden = true
        window?.makeFirstResponder(peekTab?.page.view ?? selectedTab?.page.view)
    }
}
