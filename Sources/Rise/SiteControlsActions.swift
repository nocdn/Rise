import AppKit
import Vision

@MainActor extension BrowserController {
    func popoverWillShow(_ notification: Notification) {
        guard notification.object as? NSPopover === siteControlsPopover else { return }
        sidebar.isSiteControlsOpen = true
    }
    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === siteControlsPopover else { return }
        sidebar.isSiteControlsOpen = false
    }
    func refreshSiteControls() {
        guard siteControlsPopover.isShown else { return }
        siteControlsPopover.appearance = theme.appearance
        let controller = SiteControlsController(browser: self)
        siteControlsPopover.contentViewController = controller
        siteControlsPopover.contentSize = controller.view.frame.size
    }
    func shareCurrentPage() {
        guard let url = selectedTab?.url else { return }
        let anchor = (siteControlsPopover.contentViewController as? SiteControlsController)?.quickActions.first ?? sidebar.settingsButton
        sharingPicker = NSSharingServicePicker(items: [url])
        sharingPicker?.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    func moreSiteControls() {
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
        menu.addItem(menuItem("Hide YouTube Notification Count", checked: hidesYouTubeNotificationCount) { [weak self] in
            self?.setHidesYouTubeNotificationCount(!(self?.hidesYouTubeNotificationCount ?? true))
        })
        menu.addItem(menuItem("Show Repository Under Merge Request Tabs", checked: showsRepositorySubtitle) { [weak self] in
            self?.setShowsRepositorySubtitle(!(self?.showsRepositorySubtitle ?? true))
        })
        menu.addItem(menuItem("Live Page While Expanding Peek", checked: livePeekResize) { [weak self] in
            self?.setLivePeekResize(!(self?.livePeekResize ?? true))
        })
        menu.addItem(menuItem("Simulated Full Screen", checked: pageFullscreen.isSimulated) { [weak self] in self?.toggleSimulatedFullscreen() })
        menu.addItem(menuItem("Clear Browsing History…") { [weak self] in self?.confirmClearBrowsingHistory() })
        let visibleRows = (siteControlsPopover.contentViewController as? SiteControlsController)?.rows ?? [:]
        let capabilities = [SiteCapability.camera, .microphone, .location].filter { visibleRows[$0.title] == nil }
        if !capabilities.isEmpty { menu.addItem(.separator()) }
        for capability in capabilities {
            menu.addItem(menuItem("\(capability.title) Permissions…") { [weak self] in self?.permissionSettingMenu(capability) })
        }
        return menu
    }
    static let youTubeNotificationCountKey = "Rise.HideYouTubeNotificationCount"
    /// On unless turned off in the site controls' More menu.
    var hidesYouTubeNotificationCount: Bool { preferences.object(forKey: Self.youTubeNotificationCountKey) as? Bool ?? true }
    func setHidesYouTubeNotificationCount(_ value: Bool) {
        preferences.set(value, forKey: Self.youTubeNotificationCountKey)
        for tab in tabs + (peekTab.map { [$0] } ?? []) { tab.hidesYouTubeNotificationCount = value; tab.changed() }
    }
    static let repositorySubtitleKey = "Rise.ShowRepositorySubtitle"
    /// On unless turned off in the site controls' More menu.
    var showsRepositorySubtitle: Bool { preferences.object(forKey: Self.repositorySubtitleKey) as? Bool ?? true }
    func setShowsRepositorySubtitle(_ value: Bool) {
        preferences.set(value, forKey: Self.repositorySubtitleKey)
        for tab in tabs + (peekTab.map { [$0] } ?? []) { tab.showsRepositorySubtitle = value }
        update()
    }
    func permissionSettingMenu(_ capability: SiteCapability) {
        guard let origin = SitePermissions.origin(selectedTab?.url), let view = siteControlsPopover.contentViewController?.view else { return }
        let row = (siteControlsPopover.contentViewController as? SiteControlsController)?.rows[capability.title]
        let menu = NSMenu()
        for permission in SitePermission.allCases {
            menu.addItem(menuItem(permission == .ask ? "Ask Every Time" : permission == .allow ? "Allow" : "Block",
                                  checked: sitePermissions.permission(capability, origin: origin) == permission) { [weak self] in
                guard let self else { return }
                if permission == .allow, capability == .notifications {
                    self.permissionCoordinator.requestNotificationAuthorization { [weak self] allowed in
                        self?.sitePermissions.set(allowed ? .allow : .block, for: capability, origin: origin)
                        self?.refreshPermissionScripts(); self?.refreshSiteControls()
                    }
                } else {
                    self.sitePermissions.set(permission, for: capability, origin: origin)
                    self.refreshPermissionScripts(); self.refreshSiteControls()
                    // Revoke an active capture session as well as future requests.
                    if permission != .allow && (capability == .camera || capability == .microphone) {
                        for tab in self.tabs where SitePermissions.origin(tab.url) == origin { tab.webView.reload() }
                    }
                }
            })
        }
        let anchor = row ?? view
        menu.popUp(positioning: nil, at: NSPoint(x: 40, y: anchor.bounds.maxY), in: anchor)
    }
    func toggleAutomaticPictureInPicture() {
        guard let origin = SitePermissions.origin(selectedTab?.url) else { return }
        sitePermissions.setAutomaticPictureInPicture(!sitePermissions.automaticPictureInPicture(origin: origin), origin: origin)
        refreshPermissionScripts()
        pictureInPicture.reconcile(visibleIDs: Set(visibleTabIDs))
    }
    func refreshPermissionScripts() {
        for tab in tabs + (peekTab.map { [$0] } ?? []) {
            tab.webView.evaluateJavaScript("window.riseSiteControls?.refresh()") { _, _ in }
        }
    }
    func copyTextFromPageImage() {
        guard let web = selectedTab?.webView else { return }
        web.takeSnapshot(with: nil) { [weak self] image, error in
            guard let self, let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self?.showMessage("Couldn’t read page text", error?.localizedDescription ?? "No page image available."); return
            }
            Task {
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
}
