import QuickLook
import UIKit
import WebKit

/// Pages' downloads: asked about as Safari does, then saved to Downloads with toolbar progress,
/// and listed in More's Downloads.
extension BrowserViewController {
    func setUpDownloads() {
        let downloads = MobileDownloads.shared
        downloads.confirm = { [weak self] name, host, bytes, answer in
            guard let self else { answer(false); return }
            // "10.5 MB from example.com", with whichever of the two is known.
            let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            let message = [size, host.map { "from \($0)" }].compactMap { $0 }.joined(separator: " ")
            let alert = UIAlertController(title: "Download \(name)?", message: message.isEmpty ? nil : message,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(false) })
            alert.addAction(UIAlertAction(title: "Download", style: .default) { [weak alert] _ in
                // Let the alert clear the page before its download row takes off.
                guard let alert else { answer(false); return }
                alert.dismiss(animated: true) { answer(true) }
            })
            topPresenter.present(alert, animated: true)
        }
        downloads.failed = { [weak self] error in
            guard let self else { return }
            let alert = UIAlertController(title: "Download failed", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            topPresenter.present(alert, animated: true)
        }
        downloads.onListChange = { [weak self] in self?.downloadsChanged() }
        downloads.onStart = { [weak self] item, origin in self?.launchDownloadFlight(item, from: origin) }
        downloads.onProgress = { [weak self, weak downloads] item in
            guard let self, let downloads else { return }
            bottomBar.downloads.update(item)
            bottomBar.menu.updateDownloadProgress(downloads.items)
        }
        bottomBar.downloads.open = { [weak self] item in self?.quickLook(item.url) }
        bottomBar.downloads.menu = { [weak self] item, button in self?.downloadMenu(for: item, from: button) ?? [] }
        bottomBar.downloads.listMenu = { [weak self] in self?.downloadsListMenu() ?? [] }
        bottomBar.downloads.reload(downloads.items)
        bottomBar.menu.updateDownloadProgress(downloads.items)
    }

    /// Pages WebKit can't show, and files sent as attachments, download rather than open.
    static func shouldDownload(_ response: WKNavigationResponse) -> Bool {
        guard response.isForMainFrame else { return false }
        if !response.canShowMIMEType { return true }
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        return disposition?.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("attachment") == true
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MobileDownloads.shared.begin(download, origin: downloadOrigins.take(from: webView))
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MobileDownloads.shared.begin(download, origin: downloadOrigins.take(from: webView))
    }

    func launchDownloadFlight(_ item: MobileDownloads.Item, from origin: CGPoint?) {
        guard let window = viewIfLoaded?.window, window.windowScene?.activationState == .foregroundActive else { return }
        // With no throw, receipt at the destination is immediate; keep its tactile feedback.
        if UIAccessibility.isReduceMotionEnabled {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1)
            return
        }
        if isPanelOpen { closePanel() }
        setBottomBarCollapsed(false)
        view.layoutIfNeeded(); bottomBar.layoutIfNeeded()
        let fallback = webView.convert(CGPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: window)
        let source = origin.flatMap { window.bounds.contains($0) ? $0 : nil } ?? fallback
        let flight = MobileDownloadFlight(item: item, origin: source, landing: bottomBar.moreLanding, window: window)
        window.addSubview(flight)
        flight.start()
    }

    /// Alerts go over whatever is showing, such as a Peek.
    private var topPresenter: UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    private func downloadMenu(for item: MobileDownloads.Item, from button: UIButton) -> [UIMenuElement] {
        let remove = { [id = item.id] in MobileDownloads.shared.remove(id) }
        guard item.state == .finished else {
            let title = item.state == .downloading ? "Cancel Download" : "Delete File"
            let symbol = item.state == .downloading ? "xmark" : "trash"
            return [UIAction(title: title, image: UIImage(systemName: symbol), attributes: .destructive) { _ in remove() }]
        }
        let url = item.url
        return [
            UIAction(title: "Show in Files", image: UIImage(systemName: "folder")) { _ in
                Self.showInFiles(url.deletingLastPathComponent())
            },
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak button] _ in
                guard let self else { return }
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = button
                topPresenter.present(share, animated: true)
            },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Delete File", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in remove() },
            ]),
        ]
    }

    /// The title's menu, its clearing actions last: for the whole list, or in Multi Select, the files ticked.
    private func downloadsListMenu() -> [UIMenuElement] {
        let panel = bottomBar.downloads, downloads = MobileDownloads.shared
        let disabled = { (off: Bool, attributes: UIMenuElement.Attributes) in off ? attributes.union(.disabled) : attributes }
        guard panel.isSelecting else {
            return [
                UIAction(title: "Multi Select", image: UIImage(systemName: "checkmark.circle"),
                         attributes: disabled(panel.items.isEmpty, [])) { [weak panel] _ in panel?.setSelecting(true) },
                UIAction(title: "Show in Files", image: UIImage(systemName: "folder")) { _ in Self.showInFiles(MobileDownloads.folder) },
                UIAction(title: "Clear All", image: UIImage(systemName: "trash"),
                         attributes: disabled(panel.items.isEmpty, .destructive)) { _ in downloads.removeAll() },
            ]
        }
        let selected = panel.selected, allSelected = selected.count == panel.items.count
        let files = panel.items.filter { selected.contains($0.id) && $0.state == .finished }.map(\.url)
        return [
            UIAction(title: allSelected ? "Deselect All" : "Select All",
                     image: UIImage(systemName: allSelected ? "circle" : "checkmark.circle.fill")) { [weak panel] _ in panel?.toggleAll() },
            UIAction(title: "Share Selected", image: UIImage(systemName: "square.and.arrow.up"),
                     attributes: disabled(files.isEmpty, [])) { [weak self] _ in
                guard let self else { return }
                let share = UIActivityViewController(activityItems: files, applicationActivities: nil)
                share.popoverPresentationController?.sourceView = bottomBar.downloads.listMenuButton
                topPresenter.present(share, animated: true)
            },
            UIAction(title: "Done", image: UIImage(systemName: "checkmark")) { [weak panel] _ in panel?.setSelecting(false) },
            UIAction(title: "Clear Selected", image: UIImage(systemName: "trash"),
                     attributes: disabled(selected.isEmpty, .destructive)) { [weak panel] _ in
                panel?.setSelecting(false)
                downloads.remove(selected)
            },
        ]
    }

    /// Files opens a folder of an app's Documents at its shareddocuments address.
    static func showInFiles(_ folder: URL) {
        if let files = URL(string: "shareddocuments://"+folder.path(percentEncoded: true)) { UIApplication.shared.open(files) }
    }

    func quickLook(_ url: URL) {
        topPresenter.present(FilePreview(url), animated: true)
    }
}

/// Quick Look of one downloaded file.
private final class FilePreview: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL

    init(_ url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
}
