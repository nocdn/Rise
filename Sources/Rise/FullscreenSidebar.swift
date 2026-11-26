import AppKit

@MainActor extension BrowserController {
    static let fullscreenSidebarKey = "Rise.CollapseSidebarInSimulatedFullScreen"

    var collapsesSidebarInSimulatedFullscreen: Bool { preferences.bool(forKey: Self.fullscreenSidebarKey) }

    func setCollapsesSidebarInSimulatedFullscreen(_ value: Bool) {
        preferences.set(value, forKey: Self.fullscreenSidebarKey)
        reconcileFullscreenSidebar()
    }

    func reconcileFullscreenSidebar() {
        let visibleIDs = visibleTabIDs
        let fullscreen = isPeekSimulatedFullscreen || (collapsesSidebarInSimulatedFullscreen && tabs.contains {
            visibleIDs.contains($0.id) && pageFullscreen.isActive(in: $0.page.view)
        })
        if fullscreen {
            guard fullscreenSidebarWasVisible == nil else { return }
            fullscreenSidebarWasVisible = sidebarVisible
            if sidebarVisible { setSidebarVisible(false) }
            else { tuckFloatingSidebar() }
        } else if let wasVisible = fullscreenSidebarWasVisible {
            fullscreenSidebarWasVisible = nil
            // Sidebar changes while watching are temporary; restore the exact
            // state from before fullscreen, whether it was open or collapsed.
            setSidebarVisible(wasVisible)
        }
    }
}
