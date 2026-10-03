import AppKit
import Vision

@MainActor extension BrowserController {
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
        let visibleRows = (siteControlsPopover.contentViewController as? SiteControlsController)?.rows ?? [:]
        let capabilities = [SiteCapability.camera, .microphone, .location].filter { visibleRows[$0.title] == nil }
        if !capabilities.isEmpty { menu.addItem(.separator()) }
        for capability in capabilities {
            menu.addItem(menuItem("\(capability.title) Permissions…") { [weak self] in self?.permissionSettingMenu(capability) })
        }
        return menu
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
