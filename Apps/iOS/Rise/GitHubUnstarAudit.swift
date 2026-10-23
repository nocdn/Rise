#if DEBUG
import UIKit
import WebKit

@MainActor enum GitHubUnstarAudit {
    static func device(_ browser: BrowserViewController,check: (String,Bool) throws -> Void) async throws {
        let service = browser.githubStarrer, store = browser.webView.configuration.websiteDataStore
        let repository = GitHubRepository(url: URL(string: "https://github.com/nocdn/Rise"))!
        let original = await service.status(repository,store: store,host: browser.view)
        try check("live-repository-status-is-readable",original == .starred || original == .unstarred)
        let first: MobileGitHubStarrer.Action = original == .starred ? .unstar : .star
        func submit(_ action: MobileGitHubStarrer.Action) async throws -> MobileGitHubStarrer.Outcome? {
            browser.setGitHubRepositoryStar(action,repository: repository,store: store)
            let toast = browser.githubStarToast!
            let deadline = Date().addingTimeInterval(65)
            while !toast.completed && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
            let result = toast.outcome
            toast.dismiss(animated: false); browser.githubStarToast = nil
            return result
        }
        let changed = try await submit(first)
        let after = await service.status(repository,store: store,host: browser.view)
        let restore: MobileGitHubStarrer.Action = original == .starred ? .star : .unstar
        _ = try await submit(restore)
        var restored = await service.status(repository,store: store,host: browser.view)
        if restored != original {
            _ = await service.set(restore,repository: repository,store: store,host: browser.view)
            restored = await service.status(repository,store: store,host: browser.view)
        }
        // Restore before any assertion can terminate the round-trip test.
        try check("live-round-trip-restores-the-original-star-state",restored == original)
        try check("live-github-confirms-the-requested-action",changed == (first == .star ? .starred : .unstarred))
        try check("live-status-observes-the-changed-state",after == (first == .star ? .starred : .unstarred))
        try check("live-round-trip-releases-all-helper-pages",service.isIdle)
    }
    static func exercise(_ browser: BrowserViewController,fixture: GitHubStarHTTPFixture,
                         check: (String,Bool) throws -> Void) async throws {
        let service = browser.githubStarrer, store = browser.webView.configuration.websiteDataStore
        func repository(_ name: String) -> GitHubRepository { .init(url: URL(string: "https://github.com/owner/\(name)"))! }
        for name in ["react","hydration","form","delayed","labelled"] {
            fixture.setStarred(name,true)
            try check("\(name)-status-detects-starred-without-mutating",await service.status(repository(name),store: store,host: browser.view) == .starred && fixture.postCount(name) == 0)
            let result = await service.unstar(repository(name),store: store,host: browser.view)
            try check("\(name)-unstar-needs-server-confirmation",result == .unstarred && !fixture.isStarred(name))
            try check("\(name)-unstar-submits-exactly-once",fixture.postCount(name,starred: false) == 1 && fixture.postCount(name,starred: true) == 0)
            try check("\(name)-status-detects-unstarred-without-mutating",await service.status(repository(name),store: store,host: browser.view) == .unstarred && fixture.postCount(name) == 1)
            try check("\(name)-repeated-unstar-never-stars",await service.unstar(repository(name),store: store,host: browser.view) == .alreadyUnstarred && fixture.postCount(name) == 1)
            try check("\(name)-status-and-unstar-release-their-helpers",service.isIdle)
        }
        fixture.setStarred("unstar-duplicate",true)
        async let duplicateA = service.unstar(repository("unstar-duplicate"),store: store,host: browser.view)
        async let duplicateB = service.unstar(repository("unstar-duplicate"),store: store,host: browser.view)
        let duplicates = await (duplicateA,duplicateB)
        try check("simultaneous-unstar-requests-share-one-submission",duplicates.0 == .unstarred && duplicates.1 == .unstarred && fixture.postCount("unstar-duplicate") == 1)

        let first = Task { await service.star(repository("opposing"),store: store,host: browser.view) }
        await Task.yield()
        let second = Task { await service.unstar(repository("opposing"),store: store,host: browser.view) }
        await Task.yield()
        let last = Task { await service.star(repository("opposing"),store: store,host: browser.view) }
        let ordered = await (first.value,second.value,last.value)
        try check("star-unstar-star-preserves-all-three-intentions",ordered.0 == .starred && ordered.1 == .unstarred && ordered.2 == .starred && fixture.isStarred("opposing"))
        try check("opposing-actions-never-reuse-an-obsolete-task",fixture.postCount("opposing",starred: true) == 2 && fixture.postCount("opposing",starred: false) == 1)

        fixture.setStarred("stale-unstar",true)
        _ = await service.status(repository("stale-unstar"),store: store,host: browser.view)
        fixture.setStarred("stale-unstar",false)
        try check("stale-unstar-menu-cannot-star-it-again",await service.unstar(repository("stale-unstar"),store: store,host: browser.view) == .alreadyUnstarred && fixture.postCount("stale-unstar") == 0)
        _ = await service.status(repository("stale-star"),store: store,host: browser.view)
        fixture.setStarred("stale-star",true)
        try check("stale-star-menu-cannot-unstar-it",await service.star(repository("stale-star"),store: store,host: browser.view) == .alreadyStarred && fixture.postCount("stale-star") == 0)

        fixture.setStarred("reject-unstar",true)
        try check("optimistic-unstar-cannot-hide-server-rejection",await service.unstar(repository("reject-unstar"),store: store,host: browser.view) == .failed && fixture.isStarred("reject-unstar") && fixture.postCount("reject-unstar") == 1)
        for (name,expected) in [("missing",MobileGitHubStarrer.Status.notFound),("expired",.signedOut),("server-error",.failed),("redirect",.failed),("disabled",.failed)] {
            let status = await service.status(repository(name),store: store,host: browser.view)
            try check("lookup-\(name)-fails-without-posting",status == expected && fixture.postCount(name) == 0)
        }
        let privateStore = WKWebsiteDataStore.nonPersistent()
        try check("status-cannot-borrow-another-stores-session",await service.status(repository("private-status"),store: privateStore,host: browser.view) == .signedOut)
        try check("unstar-cannot-borrow-another-stores-session",await service.unstar(repository("private-status"),store: privateStore,host: browser.view) == .signedOut && fixture.postCount("private-status") == 0)
        let lookup = Task { await service.status(repository("hang"),store: store,host: browser.view) }
        try await Task.sleep(for: .milliseconds(100))
        let queued = Task { await service.star(repository("after-cancelled-status"),store: store,host: browser.view) }
        lookup.cancel()
        try check("closing-a-menu-cancels-its-own-status-lookup",await lookup.value == .cancelled)
        try check("closing-a-menu-does-not-cancel-a-submitted-action",await queued.value == .starred && fixture.isStarred("after-cancelled-status"))
        try check("cancelled-lookups-leave-no-worker-or-queue-leak",service.isIdle)

        fixture.setStarred("menu-unstar",true)
        _ = browser.nativeLinkMenu(in: browser.webView,url: URL(string: "https://github.com/owner/menu-unstar"),actions: [])
        let menu = browser.githubRepositoryMenu!
        let until = Date().addingTimeInterval(8)
        while menu.status == nil && Date() < until { try await Task.sleep(for: .milliseconds(20)) }
        try check("starred-repository-menu-offers-unstar-with-the-same-star",menu.action().title == "Unstar repository" && menu.action().image?.isEqual(UIImage(named: "GitHubStarMenu")) == true && menu.action().image?.images == nil && menu.action().identifier == GitHubRepositoryMenu.identifier)
        let button = UIButton(); button.addAction(menu.action(),for: .primaryActionTriggered); button.sendActions(for: .primaryActionTriggered)
        let toastUntil = Date().addingTimeInterval(12)
        while browser.githubStarToast?.completed != true && Date() < toastUntil { try await Task.sleep(for: .milliseconds(20)) }
        let toast = browser.githubStarToast!
        try check("unstar-menu-action-selects-the-unstar-operation",toast.action == .unstar && toast.outcome == .unstarred && !fixture.isStarred("menu-unstar"))
        try check("unstar-toast-morphs-to-the-correct-success-message",toast.label.text == "Unstarred repository" && toast.widthAnimationCount == 1)
        try check("unstar-success-uses-the-same-star-and-one-success-haptic",toast.symbol.symbolName == "github-star" && toast.successFeedbackCount == 1)
        toast.dismiss(animated: false); browser.githubStarToast = nil
        menu.cancel(); browser.githubRepositoryMenu = nil
        let failed = GitHubStarToast(repository: repository("error"),action: .unstar)
        browser.view.addSubview(failed)
        try check("unstar-loading-message-is-distinct",failed.label.text == "Unstarring repository...")
        failed.finish(.failed)
        try check("unstar-failure-never-claims-it-starred",failed.label.text == "Couldn’t unstar repository" && failed.successFeedbackCount == 0)
        failed.dismiss(animated: false)
    }
}
#endif
