import XCTest
@testable import Rise

final class PullRequestTooltipTests: XCTestCase {
    func testRecognizesPullRequestPagesAndTheirTabTitles() {
        let pr = GitHubPullRequest(url: URL(string: "https://github.com/swiftlang/swift/pull/80000/files"))
        XCTAssertEqual(pr?.key, "swiftlang/swift#80000")
        XCTAssertNil(GitHubPullRequest(url: URL(string: "https://github.com/swiftlang/swift/issues/80000")))
        XCTAssertNil(GitHubPullRequest(url: URL(string: "https://gitlab.com/a/b/pull/1")))
        XCTAssertEqual(GitHubPullRequest.title(fromTab: "fix(agc): exclude tests by bartek · Pull Request #12 · owner/repo"), "fix(agc): exclude tests")
    }
    @MainActor func testConventionalTitlesFadeTheirType() {
        let title = PullRequestTooltip.title("feat(catalog): add render.ai provider", color: .black, muted: .gray)
        XCTAssertEqual(title.string, "feat(catalog): add render.ai provider")
        func color(_ text: String) -> NSColor? {
            title.attribute(.foregroundColor, at: (title.string as NSString).range(of: text).location, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(color("feat("), .gray)
        XCTAssertEqual(color("catalog"), .black)
        XCTAssertEqual(color("):"), .gray)
        XCTAssertEqual(color("add"), .black)
        let weight = { (text: String) in (title.attribute(.font, at: (title.string as NSString).range(of: text).location, effectiveRange: nil) as? NSFont)?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any] }
        XCTAssertLessThan(weight("feat(")?[.weight] as? CGFloat ?? 1, weight("catalog")?[.weight] as? CGFloat ?? 0, "The faded parts are a weight lighter")
        let plain = PullRequestTooltip.title("Fix the build (again)", color: .black, muted: .gray)
        XCTAssertEqual(plain.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .black)
    }
    @MainActor func testSavedCardsComeBackWithTheirDetailsAndDescription() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"a/b#1":{"summary":"Fixes it.","details":{"title":"fix: it","state":"merged","commits":2,"changedFiles":3,"additions":4,"deletions":5}}}"#.utf8).write(to: file)
        let entry = PullRequestSummaries(storageURL: file).entry(for: GitHubPullRequest(url: URL(string: "https://github.com/a/b/pull/1"))!)
        XCTAssertEqual(entry.details, PullRequestDetails(title: "fix: it", state: .merged, commits: 2, changedFiles: 3, additions: 4, deletions: 5))
        XCTAssertEqual(entry.summary, "Fixes it."); XCTAssertEqual(entry.phase, .done)
    }
    func testDiffSquaresFollowGitHub() {
        XCTAssertEqual(PullRequestPalette.blocks(additions: 2, deletions: 2).added, 2)
        XCTAssertEqual(PullRequestPalette.blocks(additions: 2, deletions: 2).deleted, 2)
        XCTAssertEqual(PullRequestPalette.blocks(additions: 8, deletions: 2).added, 4)
        XCTAssertEqual(PullRequestPalette.blocks(additions: 1000, deletions: 1).deleted, 1, "Any deletions keep a square")
    }
}
