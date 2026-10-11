import AppKit

@MainActor extension BrowserController {
    static let fullscreenSidebarKey = "Rise.CollapseSidebarInSimulatedFullScreen"

    var collapsesSidebarInSimulatedFullscreen: Bool { preferences.bool(forKey: Self.fullscreenSidebarKey) }

    func setCollapsesSidebarInSimulatedFullscreen(_ value: Bool) {
        preferences.set(value, forKey: Self.fullscreenSidebarKey)
        reconcileFullscreenSidebar()
    }

    func reconcileFullscreenSidebar() {
        let visible = tabs.filter { visibleTabIDs.contains($0.id) } + (peekTab.map { [$0] } ?? [])
        let fullscreen = pageFullscreen.isSimulated && collapsesSidebarInSimulatedFullscreen
            && visible.contains { pageFullscreen.isActive(in: $0.webView) }
        if fullscreen {
            guard fullscreenSidebarWasVisible == nil else { return }
            fullscreenSidebarWasVisible = sidebarVisible
            if sidebarVisible { setSidebarVisible(false) }
            else { tuckFloatingSidebar() }
        } else if let wasVisible = fullscreenSidebarWasVisible {
            fullscreenSidebarWasVisible = nil
            if wasVisible { setSidebarVisible(true) }
        }
    }
}
