import AppKit
import RiseCore

// Both apps share the learner; the Mac installs it on its Chromium pages.
typealias SiteSearchLearner = RiseCore.SiteSearchLearner

@MainActor private let chromiumPages = NSHashTable<AnyObject>.weakObjects()

extension SiteSearchLearner {
    func install(on page: WebPage) {
        if let webView = (page as? WebKitPage)?.webView { install(on: webView); return }
        guard !chromiumPages.contains(page) else { return }
        chromiumPages.add(page)
        page.addMessageHandler("riseSiteSearch", world: .named(Self.worldName)) { [weak self] message in
            guard message.frame.isMain, let page = message.page, let body = message.body as? [String: Any],
                  let terms = body["terms"] as? [String] else { return }
            self?.searched(terms.prefix(6).map { String($0.prefix(200)) }, name: body["name"] as? String, in: page.view, url: page.url)
        }
        page.addUserScript(Self.script, world: .named(Self.worldName), mainFrameOnly: true, handlers: ["riseSiteSearch"])
    }
}
