import UIKit
import WebKit

/// Printing through iOS's print sheet, which also saves a PDF: a page's own Print button and Print
/// in the Share sheet.
extension BrowserViewController {
    /// WebKit's call for window.print(), the one Safari answers; without it the call does nothing.
    /// The page is released at once: while it waits on window.print() it can't draw the sheet's
    /// preview, which then spins for good. Only the page on screen can ask, and not over something else.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func printFrame(of page: WKWebView, frame: AnyObject?, pdfFirstPageSize: CGSize, completionHandler: @escaping () -> Void) {
        completionHandler()
        guard page === webView, view.window != nil, presentedViewController == nil, !isPanelOpen else { return }
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self, let page, page === webView else { return }
            presentPrintSheet(for: page) { [weak self] in self?.applyPendingChanges() }
        }
    }

    func presentPrintSheet(for page: WKWebView, finished: @escaping () -> Void) {
        let printer = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = page.title.flatMap { $0.isEmpty ? nil : $0 } ?? page.url?.host ?? "Page"
        printer.printInfo = info
        printer.printFormatter = page.viewPrintFormatter()
        let done: UIPrintInteractionController.CompletionHandler = { _, _, _ in finished() }
        let shown = traitCollection.userInterfaceIdiom == .pad
            ? printer.present(from: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0), in: view, animated: true, completionHandler: done)
            : printer.present(animated: true, completionHandler: done)
        if !shown { finished() }
    }
}
