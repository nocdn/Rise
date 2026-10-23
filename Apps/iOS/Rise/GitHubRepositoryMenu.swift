import UIKit
import WebKit

/// One menu presentation owns one cancellable, read-only lookup. A stable action
/// identifier and constant star keep title updates in place without content effects.
@MainActor final class GitHubRepositoryMenu {
    static let identifier = UIAction.Identifier("rise.github.repository-star")
    private static let sectionIdentifier = UIMenu.Identifier("rise.github.repository")
    private weak var browser: BrowserViewController?
    private weak var page: WKWebView?
    private let repository: GitHubRepository
    private let store: WKWebsiteDataStore
    private var lookup: Task<Void,Never>?
    private var cancelled = false
    private(set) var status: MobileGitHubStarrer.Status?
    private(set) var isPresented = false

    init(browser: BrowserViewController,page: WKWebView,repository: GitHubRepository,store: WKWebsiteDataStore) {
        self.browser = browser; self.page = page; self.repository = repository; self.store = store
    }
    func element() -> UIMenu {
        if lookup == nil, status == nil, !cancelled { start() }
        return UIMenu(identifier: Self.sectionIdentifier,options: .displayInline,children: [action()])
    }
    func action() -> UIAction {
        guard let browser else { return UIAction(title: "Repository unavailable",attributes: .disabled) { _ in } }
        let image = UIImage(named: "GitHubStarMenu")
        let result: UIAction
        switch status {
        case .starred?, .unstarred?:
            let requested: MobileGitHubStarrer.Action = status == .starred ? .unstar : .star
            let pending = browser.githubStarrer.isPending(repository,store: store)
            result = UIAction(title: pending ? "Updating repository..." : requested.title,image: image,identifier: Self.identifier,
                              attributes: pending ? .disabled : []) { [weak browser, repository, store] _ in
                browser?.setGitHubRepositoryStar(requested,repository: repository,store: store)
            }
        case .signedOut?:
            result = UIAction(title: "Sign in to GitHub to star",image: image,identifier: Self.identifier,attributes: .disabled) { _ in }
        case .notFound?:
            result = UIAction(title: "Repository unavailable",image: image,identifier: Self.identifier,attributes: .disabled) { _ in }
        case .failed?, .cancelled?:
            result = UIAction(title: "Retry checking status",image: image,identifier: Self.identifier,attributes: .keepsMenuPresented) { [weak self] _ in
                self?.start(); self?.refresh()
            }
        case nil:
            result = UIAction(title: "Checking status...",image: image,
                              identifier: Self.identifier,attributes: .disabled) { _ in }
        }
        return result
    }
    private func start() {
        lookup?.cancel(); status = nil
        guard !cancelled, let browser else { return }
        lookup = Task { [weak self, weak browser] in
            guard let self, let browser else { return }
            let result = await browser.githubStarrer.status(repository,store: store,host: browser.view)
            guard !Task.isCancelled, !cancelled, browser.githubRepositoryMenu === self else { return }
            status = result; lookup = nil
            refresh()
        }
    }
    func willPresent(in page: WKWebView) {
        guard self.page === page else { return }
        isPresented = true
        // A fast lookup may finish before UIKit has installed its menu view.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    private func refresh() {
        guard !cancelled, isPresented, let page else { return }
        func update(_ menu: UIMenu) -> UIMenu {
            if menu.identifier == Self.sectionIdentifier { return element() }
            return menu.replacingChildren(menu.children.map { child in
                if let item = child as? UIAction, item.identifier == Self.identifier {
                    return action()
                }
                return (child as? UIMenu).map(update) ?? child
            })
        }
        func visit(_ view: UIView) {
            for interaction in view.interactions.compactMap({ $0 as? UIContextMenuInteraction }) {
                NativeMenuLoading.withoutAnimation { interaction.updateVisibleMenu(update) }
            }
            view.subviews.forEach(visit)
        }
        visit(page)
    }
    func cancel() {
        cancelled = true; isPresented = false; lookup?.cancel(); lookup = nil
    }
    isolated deinit { lookup?.cancel() }
}
