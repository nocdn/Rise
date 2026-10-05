import AppKit
import WebKit
import RiseCore

@MainActor extension BrowserController: WKNavigationDelegate, WKUIDelegate {
    func shouldPeek(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.shift) || modifiers.contains(.option)
    }
    @discardableResult func openModifiedLink(_ url: URL, modifiers: NSEvent.ModifierFlags, from source: WKWebView? = nil, opensNewTab: Bool = false) -> Bool {
        if shouldPeek(modifiers: modifiers) { showPeek(url: url, from: source, opensNewTab: opensNewTab); return true }
        if modifiers.contains(.command) { addTab(url: url); return true }
        return false
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true, action.navigationType != .backForward { pageCloth.cancel(for: webView) }
        if action.targetFrame?.isMainFrame == true { permissionCoordinator.cancel(for: webView) }
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if action.navigationType == .linkActivated, let url = action.request.url {
            if openModifiedLink(url, modifiers: action.modifierFlags, from: webView, opensNewTab: action.targetFrame == nil) { decisionHandler(.cancel); return }
        }
        if let scheme = action.request.url?.scheme?.lowercased(), !["http", "https", "file", "about", "data", "blob"].contains(scheme) {
            // External schemes require a deliberate choice; never silently run them.
            let alert = NSAlert(); alert.messageText = "Open in another app?"; alert.informativeText = action.request.url?.absoluteString ?? ""
            alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
            if let window { alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn, let url = action.request.url { NSWorkspace.shared.open(url) } } }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        permissionCoordinator.cancel(for: webView)
        if selectedTab?.webView === webView { siteControlsPopover.close(); copiedLinkPopover.close() }
        historySwipe.cancel(for: webView)
        if hoveredWebView === webView { hideLinkStatus() }
        if errorWebView === webView { errorWebView = nil }; update()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { pageCloth.destinationDidCommit(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageCloth.remember(webView)
        pageCloth.destinationDidCommit(webView)
        if let tab = tabs.first(where: { $0.webView === webView }), let url = tab.url, url.absoluteString != "about:blank" {
            tab.captureThumbnail()
            browsingHistory.record(url, title: webView.title ?? tab.title)
            discoverPageFavicon(webView)
        }; update()
        if let tab = tabs.first(where: { $0.webView === webView }) { findBars[tab.id]?.pageChanged() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showNavigationError(error, in: webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showNavigationError(error, in: webView) }
    func showNavigationError(_ error: Error, in webView: WKWebView) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        pageCloth.cancel(for: webView)
        errorWebView = webView; errorMessage.stringValue = error.localizedDescription; update()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil else { return nil }
        if shouldPeek(modifiers: action.modifierFlags), let url = action.request.url {
            showPeek(url: url, from: webView, opensNewTab: true); return nil
        }
        return addTab(configuration: configuration).webView
    }
    func webViewDidClose(_ webView: WKWebView) { if let tab = tabs.first(where: { $0.webView === webView }) { closeTab(tab.id) } }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let capabilities: [SiteCapability]
        switch type {
        case .camera: capabilities = [.camera]
        case .microphone: capabilities = [.microphone]
        case .cameraAndMicrophone: capabilities = [.camera, .microphone]
        @unknown default: decisionHandler(.deny); return
        }
        permissionCoordinator.request(in: webView, origin: SitePermissions.origin(origin), capabilities: capabilities) { decisionHandler($0 ? .grant : .deny) }
    }
    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        permissionCoordinator.request(in: webView, origin: SitePermissions.origin(origin), capabilities: [.location]) { decisionHandler($0 ? .grant : .deny) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = AddressResolver.displayHost(webView.url); alert.informativeText = message
        guard let window else { completionHandler(); return }
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = AddressResolver.displayHost(webView.url); alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        guard let window else { completionHandler(false); return }
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26)); input.stringValue = defaultText ?? ""; alert.accessoryView = input
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        guard let window else { completionHandler(nil); return }
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories; panel.canChooseFiles = true
        guard let window else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { registerDownload(download); launchDownloadFlight() }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { registerDownload(download); launchDownloadFlight() }
}
@MainActor extension BrowserController: WKDownloadDelegate {
    func registerDownload(_ download: WKDownload) {
        pendingDownloads[ObjectIdentifier(download)] = download; download.delegate = self
    }
    /// Saves straight to Downloads; names in use, on disk or by another download, get a number.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        try? FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
        let pending = downloads.pendingDestinations
        let destination = Self.downloadDestination(for: suggestedFilename, in: downloadsFolder) {
            pending.contains($0) || FileManager.default.fileExists(atPath: $0.path)
        }
        downloads.track(download, at: destination, expectedBytes: response.expectedContentLength) { [weak self] error in
            self?.showMessage("Download failed", error.localizedDescription)
        }
        pendingDownloads[ObjectIdentifier(download)] = nil
        completionHandler(destination)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingDownloads[ObjectIdentifier(download)] = nil
        NSLog("Rise download failed before destination selection: %@", error as NSError)
        showMessage("Download failed", error.localizedDescription)
    }
    func downloadDidFinish(_ download: WKDownload) {
        // Tracked downloads hand their delegate to DownloadTransfer at destination selection.
        pendingDownloads[ObjectIdentifier(download)] = nil
    }
}
