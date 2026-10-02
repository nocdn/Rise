import AppKit
import WebKit
import RiseCore

@MainActor extension BrowserController: WKNavigationDelegate, WKUIDelegate {
    func shouldPeek(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.shift) || modifiers.contains(.option)
    }
    @discardableResult func openModifiedLink(_ url: URL, modifiers: NSEvent.ModifierFlags) -> Bool {
        if shouldPeek(modifiers: modifiers) { showPeek(url: url); return true }
        if modifiers.contains(.command) { addTab(url: url); return true }
        return false
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if action.navigationType == .linkActivated, let url = action.request.url {
            if openModifiedLink(url, modifiers: action.modifierFlags) { decisionHandler(.cancel); return }
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
        historySwipe.cancel(for: webView)
        if hoveredWebView === webView { hideLinkStatus() }
        if errorWebView === webView { errorWebView = nil }; update()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }), let url = tab.url, url.absoluteString != "about:blank" {
            tab.captureThumbnail()
            history.removeAll { $0.url == url.absoluteString }; history.append(tab.saved)
            if history.count > 200 { history.removeFirst() }
        }; update()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showNavigationError(error, in: webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showNavigationError(error, in: webView) }
    func showNavigationError(_ error: Error, in webView: WKWebView) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        errorWebView = webView; errorMessage.stringValue = error.localizedDescription; update()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil else { return nil }
        if shouldPeek(modifiers: action.modifierFlags), let url = action.request.url {
            showPeek(url: url); return nil
        }
        return addTab(configuration: configuration).webView
    }
    func webViewDidClose(_ webView: WKWebView) { if let tab = tabs.first(where: { $0.webView === webView }) { closeTab(tab.id) } }
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
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
}
@MainActor extension BrowserController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedFilename
        guard let window else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.url : nil) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { showMessage("Download failed", error.localizedDescription) }
    func downloadDidFinish(_ download: WKDownload) { }
}
