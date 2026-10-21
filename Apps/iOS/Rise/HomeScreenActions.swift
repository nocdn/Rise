import UIKit
import WebKit

/// Static items in Info.plist make these available before the app's first launch.
enum HomeScreenAction: String, CaseIterable {
    case downloads = "dev.bartosz.Rise.iOS.downloads"
    case history = "dev.bartosz.Rise.iOS.history"
    case newPrivateTab = "dev.bartosz.Rise.iOS.new-private-tab"

    init?(shortcut: UIApplicationShortcutItem) { self.init(rawValue: shortcut.type) }
}

/// Routes shortcuts after the browser's existing panel/card transitions finish.
@MainActor final class BrowserQuickActions {
    private weak var browser: BrowserViewController?
    private(set) var pending: HomeScreenAction?
    private var privacyCover: UIView?

    init(browser: BrowserViewController) { self.browser = browser }

    func open(_ action: HomeScreenAction) {
        browser?.suppressLaunchSearch()
        pending = action
        browser?.applyPendingChanges()
    }

    /// True while an action owns the next transition, including while it is waiting.
    @discardableResult func applyPending() -> Bool {
        guard let action = pending, let browser else { return false }
        guard browser.prepareForQuickAction(action) else { return true }
        pending = nil
        switch action {
        case .downloads:
            browser.openPanel(.menu)
            browser.openDownloads()
        case .history:
            browser.openHistory()
        case .newPrivateTab:
            browser.openPrivateSearch()
        }
        return true
    }

    /// Keep private page content out of the system's app-switcher snapshot.
    func setActive(_ active: Bool, in window: UIWindow) {
        if active { privacyCover?.removeFromSuperview(); privacyCover = nil; return }
        guard let browser, browser.hasVisiblePrivateContent, privacyCover == nil else { return }
        browser.panelMotion.stop()
        let cover = UIView(frame: window.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .black
        let label = UILabel()
        label.text = "Private Browsing"
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.frame = cover.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.addSubview(label)
        window.addSubview(cover)
        privacyCover = cover
    }
}
