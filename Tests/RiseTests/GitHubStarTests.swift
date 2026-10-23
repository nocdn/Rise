import XCTest
import RiseCore
@testable import Rise

final class GitHubStarTests: XCTestCase {
    func testRepositoryLinksAreRecognisedFromAnyOfTheirPagesAndGitHubsOwnPagesAreNot() {
        func path(_ text: String) -> String? { GitHubRepository(url: URL(string: text))?.path }
        XCTAssertEqual(path("https://github.com/pingdotgg/t3code"), "pingdotgg/t3code")
        XCTAssertEqual(path("https://www.github.com/t3-oss/create-t3-app/tree/main/cli?tab=readme#usage"), "t3-oss/create-t3-app", "Any of its pages")
        XCTAssertEqual(path("https://github.com/anomalyco/hex.git"), "anomalyco/hex", "A clone address")
        XCTAssertEqual(path("https://github.com/vercel/next.js/issues/1"), "vercel/next.js", "Dots in a name")
        for other in ["https://github.com/pingdotgg", "https://github.com/settings/profile", "https://github.com/orgs/vercel/repositories",
                      "https://github.com/topics/swift", "https://gist.github.com/someone/abc123", "https://gitlab.com/a/b",
                      "ftp://github.com/a/b", "https://github.com/a/.."] {
            XCTAssertNil(path(other), other)
        }
    }
}
