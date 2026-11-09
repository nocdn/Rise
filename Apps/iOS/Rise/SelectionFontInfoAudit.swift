#if DEBUG
import BrowserEngineKit
import UIKit
import WebKit

/// Font info on a real page: text selected in a web font, an installed font and the system font
/// reads as each, the selection menu offers it, and it opens the bar into its panel. With
/// `-RiseAuditPage <url>` naming the page, served from the Mac; it holds each step up for a
/// screenshot (`shot-*.txt`, removed once taken as `taken-*.txt` appears).
@MainActor enum SelectionFontInfoAudit {
    static let argument = "-RiseSelectionFontInfoAudit"
    struct Failure: Error { let name: String }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("SelectionFontInfoAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(in: browser, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch { try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8) }
        }
    }
    private static func exercise(in browser: BrowserViewController, folder: URL) async throws {
        var checks: [String: Any] = [:]
        func note(_ name: String, _ value: Any) throws {
            checks[name] = value
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
        }
        func check(_ name: String, _ valid: Bool) throws { try note(name, valid); if !valid { throw Failure(name: name) } }
        func wait(_ name: String, seconds: Double = 8, _ ready: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if try await ready() { try check(name, true); return }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(name, false)
        }
        /// Holds still until the Mac has photographed it.
        func shot(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(700))
            let marker = folder.appendingPathComponent("shot-\(name).txt"), taken = folder.appendingPathComponent("taken-\(name).txt")
            try name.write(to: marker, atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: taken.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-RiseAuditPage"), index+1 < arguments.count, let address = URL(string: arguments[index+1]) else {
            throw Failure(name: "page-address-given")
        }
        let page = browser.webView
        page.load(URLRequest(url: address))
        try await wait("web-font-loaded", seconds: 20) {
            try await page.evaluateJavaScript("document.readyState === 'complete' && document.fonts.check('16px Inter') && [...document.fonts].some(f => f.family.replace(/\"/g,'') === 'Inter' && f.status === 'loaded')") as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(500))

        func select(_ selector: String, words: Int) async throws {
            _ = try await page.evaluateJavaScript("""
            (() => { const node = document.querySelector('\(selector)').firstChild, range = document.createRange();
              const text = node.data, end = text.split(' ').slice(0, \(words)).join(' ').length;
              range.setStart(node, 0); range.setEnd(node, end);
              const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); return true; })()
            """)
            try await wait("\(selector)-selection-reaches-the-app") { !SelectionTimeMenu.rawSelection(in: page).isEmpty }
        }

        // An installed font and the system's.
        try await select("#georgia", words: 3)
        let georgia = await SelectionFontInfo.info(in: page)
        try note("georgia", [georgia?.displayName ?? "", georgia?.kind.rawValue ?? "", georgia?.sourceName ?? ""])
        try check("an-installed-font-is-named", georgia?.kind == .installed && georgia?.displayName == "Georgia")
        try await select("#system", words: 3)
        let system = await SelectionFontInfo.info(in: page)
        try note("system", [system?.displayName ?? "", system?.stack.map { "\($0.name) \($0.status)" } ?? []])
        try check("the-system-font-is-named", system?.kind == .generic && system?.displayName == "SF Pro"
                  && system?.stack.first?.status == "missing")

        // The web font, from Google Fonts.
        try await select("#sample", words: 6)
        let info = await SelectionFontInfo.info(in: page)
        let rows: [String] = info?.rows.map { "\($0.0): \($0.1)" } ?? []
        try note("inter", rows+[info?.source?.absoluteString ?? ""])
        try check("a-web-font-is-named-with-its-source", info?.kind == .web && info?.displayName == "Inter"
                  && info?.sourceName.hasPrefix("Google Fonts") == true)
        try check("its-size-and-weight-are-read", info?.size == 20 && info?.weight == 500)

        // The selection menu offers it, beside Explain in Context or Look Up.
        if #available(iOS 17.4, *), let content = page.scrollView.subviews.first(where: { $0 is UITextInput }),
           let interaction = content.interactions.compactMap({ $0 as? BETextInteraction }).first {
            content.becomeFirstResponder()
            interaction.presentEditMenuForSelection()
            try await Task.sleep(for: .milliseconds(700))
            // Its second page, where Font info follows Look Up and Translate.
            func views(_ view: UIView) -> [UIView] { [view]+view.subviews.flatMap(views) }
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            let all = windows.flatMap(views)
            if let next = all.last(where: { $0.accessibilityLabel == "Next Page" }) {
                if !next.accessibilityActivate(), let control = next as? UIControl { control.sendActions(for: .touchUpInside) }
                try await Task.sleep(for: .milliseconds(600))
            }
            // The menu's own items: views labelled inside the edit menu.
            func inMenu(_ view: UIView) -> Bool {
                var current: UIView? = view
                while let next = current { let name = "\(type(of: next))"; if name.hasPrefix("_UI"), name.contains("Menu") { return true }; current = next.superview }
                return false
            }
            var titles: [String] = []
            for view in windows.flatMap(views) where inMenu(view) {
                if let label = view.accessibilityLabel, !label.isEmpty, !titles.contains(label) { titles.append(label) }
            }
            try note("menu-items", Array(titles))
            try await shot("menu")
            try check("the-selection-menu-offers-font-info", titles.contains(SelectionFontInfo.title))
            interaction.dismissEditMenuForSelection()
            try await Task.sleep(for: .milliseconds(400))
        }
        await SelectionFontInfo.present(from: page)
        try await wait("its-panel-opens") { browser.bottomBar.panel == .fontInfo && browser.bottomBar.fontInfo.alpha == 1 }
        try await Task.sleep(for: .milliseconds(1200))
        try await shot("panel")
        let scroll = browser.bottomBar.fontInfo.scroll
        try note("list-and-room", [scroll.contentSize.height, scroll.bounds.height])
        try check("the-whole-list-fits-without-a-fade", scroll.contentSize.height <= scroll.bounds.height+0.5 && scroll.layer.mask == nil)
        browser.overrideUserInterfaceStyle = .dark
        browser.view.window?.overrideUserInterfaceStyle = .dark
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        try await shot("dark")
        browser.view.window?.overrideUserInterfaceStyle = .unspecified
        browser.overrideUserInterfaceStyle = .unspecified
        browser.bottomBar.fontInfo.closeButton.sendActions(for: .primaryActionTriggered)
        try await wait("its-x-closes-it") { !browser.isPanelOpen }
    }
}
#endif
