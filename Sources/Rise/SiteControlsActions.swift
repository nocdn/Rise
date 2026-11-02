import AppKit
import Vision

@MainActor extension BrowserController {
    func refreshSiteControls() {
        guard siteControlsPopover.isShown else { return }
        siteControlsPopover.appearance = theme.appearance
        let controller = SiteControlsController(browser: self)
        if let shown = siteControlsPopover.contentViewController as? SiteControlsController, shown.take(controller) { return }
        siteControlsPopover.contentViewController = controller
        siteControlsPopover.contentSize = controller.view.frame.size
    }
    @objc func shareCurrentPage() {
        guard let url = selectedTab?.url else { return }
        let anchor = (siteControlsPopover.contentViewController as? SiteControlsController)?.quickActions.first ?? selectedBar.settingsButton
        sharingPicker = NSSharingServicePicker(items: [url])
        sharingPicker?.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    func moreSiteControls() {
        // Rise's settings are among Chrome's, at rise://settings; without the engine, as in unit
        // tests, the menu stands in.
        if ChromiumEngine.isRunning { siteControlsPopover.close(); showSettings(); return }
        guard let anchor = (siteControlsPopover.contentViewController as? SiteControlsController)?.quickActions.last else { return }
        makeMoreSiteMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor)
    }
    func makeMoreSiteMenu() -> NSMenu {
        let menu = makeSiteMenu()
        menu.addItem(.separator())
        menu.addItem(makeSearchEngineMenu())
        menu.addItem(makeThemeMenu())
        menu.addItem(makeAIProviderMenu())
        menu.addItem(makeGmailCategoryMenu())
        menu.addItem(menuItem("Hide Notification Counts", checked: hidesNotificationCounts) { [weak self] in
            self?.setHidesNotificationCounts(!(self?.hidesNotificationCounts ?? true))
        })
        menu.addItem(menuItem("Show Repository Under Merge Request Tabs", checked: showsRepositorySubtitle) { [weak self] in
            self?.setShowsRepositorySubtitle(!(self?.showsRepositorySubtitle ?? true))
        })
        menu.addItem(menuItem("Live Page While Expanding Peek", checked: livePeekResize) { [weak self] in
            self?.setLivePeekResize(!(self?.livePeekResize ?? true))
        })
        menu.addItem(menuItem("Animate Developer Tools", checked: animatesDevTools) { [weak self] in
            self?.setAnimatesDevTools(!(self?.animatesDevTools ?? true))
        })
        menu.addItem(menuItem("Simulated Full Screen", checked: pageFullscreen.isSimulated) { [weak self] in self?.toggleSimulatedFullscreen() })
        if pageFullscreen.isSimulated {
            menu.addItem(menuItem("Collapse Sidebar in Simulated Full Screen", checked: collapsesSidebarInSimulatedFullscreen) { [weak self] in
                guard let self else { return }
                self.setCollapsesSidebarInSimulatedFullscreen(!self.collapsesSidebarInSimulatedFullscreen)
            })
            menu.addItem(menuItem("Auto-hide URL Bar in Simulated Full Screen", checked: autoHidesFullscreenNavigation) { [weak self] in
                guard let self else { return }
                self.setAutoHidesFullscreenNavigation(!self.autoHidesFullscreenNavigation)
            })
        }
        menu.addItem(menuItem("Clear Browsing History…") { [weak self] in self?.confirmClearBrowsingHistory() })
        let visibleRows = (siteControlsPopover.contentViewController as? SiteControlsController)?.rows ?? [:]
        let capabilities = [SiteCapability.camera, .microphone, .location].filter { visibleRows[$0.title] == nil }
        if !capabilities.isEmpty { menu.addItem(.separator()) }
        for capability in capabilities {
            menu.addItem(menuItem("\(capability.title) Permissions…") { [weak self] in self?.permissionSettingMenu(capability) })
        }
        return menu
    }
    /// Named for YouTube, the first site it covered, so the setting carries over.
    static let notificationCountsKey = "Rise.HideYouTubeNotificationCount"
    /// On unless turned off in the site controls' More menu.
    var hidesNotificationCounts: Bool { preferences.object(forKey: Self.notificationCountsKey) as? Bool ?? true }
    /// A page's title as history keeps it: a count of the moment isn't worth remembering.
    func historyTitle(_ title: String, url: URL) -> String {
        hidesNotificationCounts ? TitleNotificationCount.removing(from: title, url: url) : title
    }
    func setHidesNotificationCounts(_ value: Bool) {
        preferences.set(value, forKey: Self.notificationCountsKey)
        for tab in tabs + allPeekTabs { tab.hidesNotificationCounts = value; tab.changed() }
    }
    static let repositorySubtitleKey = "Rise.ShowRepositorySubtitle"
    /// On unless turned off in the site controls' More menu.
    var showsRepositorySubtitle: Bool { preferences.object(forKey: Self.repositorySubtitleKey) as? Bool ?? true }
    func setShowsRepositorySubtitle(_ value: Bool) {
        preferences.set(value, forKey: Self.repositorySubtitleKey)
        for tab in tabs + allPeekTabs { tab.showsRepositorySubtitle = value }
        update()
    }
    func permissionSettingMenu(_ capability: SiteCapability) {
        guard let origin = SitePermissions.origin(selectedTab?.url), let view = siteControlsPopover.contentViewController?.view else { return }
        let row = (siteControlsPopover.contentViewController as? SiteControlsController)?.rows[capability.title]
        let menu = NSMenu()
        for permission in SitePermission.allCases {
            menu.addItem(menuItem(permission == .ask ? "Ask Every Time" : permission == .allow ? "Allow" : "Block",
                                  checked: sitePermissions.permission(capability, origin: origin) == permission) { [weak self] in
                self?.setSitePermission(permission, for: capability, origin: origin)
            })
        }
        let anchor = row ?? view
        menu.popUp(positioning: nil, at: NSPoint(x: 40, y: anchor.bounds.maxY), in: anchor)
    }
    /// The popover and rise://settings use the same authorization and revocation path.
    func setSitePermission(_ permission: SitePermission, for capability: SiteCapability, origin: String) {
        if permission == .allow, capability == .notifications {
            permissionCoordinator.requestNotificationAuthorization { [weak self] allowed in
                self?.sitePermissions.set(allowed ? .allow : .block, for: capability, origin: origin)
                self?.refreshPermissionScripts(); self?.refreshSiteControls()
            }
        } else {
            sitePermissions.set(permission, for: capability, origin: origin)
            refreshPermissionScripts(); refreshSiteControls()
            if permission != .allow && (capability == .camera || capability == .microphone) {
                for tab in tabs + allPeekTabs where SitePermissions.origin(tab.url) == origin { tab.page.reload() }
            }
        }
    }
    @objc func toggleAutomaticPictureInPicture() {
        guard let origin = SitePermissions.origin(selectedTab?.url) else { return }
        sitePermissions.setAutomaticPictureInPicture(!sitePermissions.automaticPictureInPicture(origin: origin), origin: origin)
        pictureInPicture.reconcile(visibleIDs: Set(visibleTabIDs))
    }
    @objc func toggleLinkPreloading() { linkPreloader.setEnabled(!linkPreloader.enabled) }
    func refreshPermissionScripts() {
        for tab in tabs + allPeekTabs {
            tab.page.evaluate("window.riseSiteControls?.refresh()", arguments: [:], in: nil, world: .page) { _ in }
        }
    }
    func copyTextFromPageImage() {
        guard let page = selectedTab?.page else { return }
        Task { [weak self] in
            let image = await page.snapshot(width: nil)
            guard let self else { return }
            guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.showMessage("Couldn’t read page text", "No page image available."); return
            }
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }.value
                guard !text.isEmpty else { self.showMessage("No text found", "No readable text was found in the visible page."); return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                self.showMessage("Text copied", "The visible page’s text is on your clipboard.")
            } catch { self.showMessage("Couldn’t read page text", error.localizedDescription) }
        }
    }
}
