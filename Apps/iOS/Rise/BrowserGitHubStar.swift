import UIKit
import WebKit

extension BrowserViewController {
    func nativeLinkMenu(in page: WKWebView, url: URL?, actions suggested: [UIMenuElement]) -> UIMenu {
        githubRepositoryMenu?.cancel(); githubRepositoryMenu = nil
        let actions = addingOpenHere(to: suggested, url: url, in: page)
        guard let repository = GitHubRepository(url: url) else { return ImageContextMenus.menu(in: page, actions: actions, link: url) }
        let store = page.configuration.websiteDataStore
        let menu = GitHubRepositoryMenu(browser: self,page: page,repository: repository,store: store)
        githubRepositoryMenu = menu
        return ImageContextMenus.menu(in: page, actions: actions+[menu.element()], link: url)
    }

    func githubStarAction(_ repository: GitHubRepository, store: WKWebsiteDataStore,action: MobileGitHubStarrer.Action = .star) -> UIAction {
        let pending = githubStarrer.isPending(repository, store: store)
        return UIAction(title: pending ? action.progress : action.title, image: UIImage(named: "GitHubStarMenu"),
                        attributes: pending ? .disabled : []) { [weak self] _ in
            self?.setGitHubRepositoryStar(action,repository: repository,store: store)
        }
    }

    func starGitHubRepository(_ repository: GitHubRepository, store: WKWebsiteDataStore) {
        setGitHubRepositoryStar(.star,repository: repository,store: store)
    }
    func setGitHubRepositoryStar(_ action: MobileGitHubStarrer.Action,repository: GitHubRepository,store: WKWebsiteDataStore) {
        guard view.window != nil, !githubStarrer.isPending(repository, store: store) else { return }
        let toast = GitHubStarToast(repository: repository,action: action)
        showToast(toast)
        Task { [weak self, weak toast] in
            guard let self else { return }
            // Give WebKit time to finish if the user briefly leaves the app. Expiration
            // tears down the helper pages and resumes every pending continuation.
            let background = UIApplication.shared.beginBackgroundTask(withName: action.title) { [weak self] in
                Task { @MainActor in self?.githubStarrer.cancelAll() }
            }
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            let outcome = await githubStarrer.set(action,repository: repository,store: store,host: view)
            toast?.finish(outcome)
        }
    }
}
