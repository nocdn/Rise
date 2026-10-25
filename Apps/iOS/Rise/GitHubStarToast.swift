import UIKit

/// Starring or unstarring a repository: a spinner until GitHub answers, then the outcome.
@MainActor final class GitHubStarToast: Toast {
    let action: MobileGitHubStarrer.Action
    private(set) var completed = false
    private(set) var outcome: MobileGitHubStarrer.Outcome?
    private(set) var successFeedbackCount = 0

    init(repository: GitHubRepository,action: MobileGitHubStarrer.Action = .star) {
        self.action = action
        super.init(message: action.progress, motionName: "github-toast")
        symbol.setLoading(name: action == .star ? "github-starring" : "github-unstarring")
        accessibilityValue = repository.path
    }
    required init?(coder: NSCoder) { fatalError() }

    func finish(_ outcome: MobileGitHubStarrer.Outcome) {
        guard !dismissed, !completed else { return }
        completed = true
        self.outcome = outcome
        let success = [.starred,.alreadyStarred,.unstarred,.alreadyUnstarred].contains(outcome)
        let title: String
        switch outcome {
        case .starred: title = "Starred repository"
        case .alreadyStarred: title = "Already starred"
        case .unstarred: title = "Unstarred repository"
        case .alreadyUnstarred: title = "Already unstarred"
        case .signedOut: title = action == .star ? "Sign in to GitHub to star" : "Sign in to GitHub to unstar"
        case .notFound: title = "Repository unavailable"
        case .failed: title = action == .star ? "Couldn’t star repository" : "Couldn’t unstar repository"
        case .cancelled: dismiss(); return
        }
        setMessage(title)
        if success {
            symbol.setGlyph(UIImage(named: "GitHubStar"), name: "github-star")
            if window?.windowScene?.activationState == .foregroundActive {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                successFeedbackCount += 1
            }
        } else { symbol.setGlyph(UIImage(named: "GitHubToastError"), name: "github-star-error") }
        accessibilityLabel = label.text
        UIAccessibility.post(notification: .announcement, argument: label.text)
        leave(after: success ? 2.5 : 4, afterDrag: 2.5)
    }
}
