import XCTest
@testable import RiseCore

final class GitHubRepositoryTests: XCTestCase {
    func testCanonicalRepositoryFromAllLinkForms() {
        for url in ["https://github.com/Owner/Repo", "https://GITHUB.COM/Owner/Repo/",
                    "https://www.github.com/Owner/Repo/tree/main/a.swift?x=1#L2",
                    "http://github.com:80/Owner/Repo/issues/42", "https://github.com:443/Owner/Repo.git",
                    "https://github.com/Owner/%52epo", "https://github.com/Owner/Repo.GIT"] {
            XCTAssertEqual(GitHubRepository(url: URL(string: url))?.path, "Owner/Repo", url)
        }
        XCTAssertEqual(GitHubRepository(url: URL(string: "https://github.com/a/repo.name_with-dashes"))?.name, "repo.name_with-dashes")
    }
    func testNotRepositoryAndUntrustedURLs() {
        for url in ["https://github.com", "https://github.com/owner", "https://gist.github.com/a/b",
                    "https://github.com.evil.test/a/b", "https://evilgithub.com/a/b", "https://github.com@evil.test/a/b",
                    "https://evil@github.com/a/b", "https://a:b@github.com/a/b", "ftp://github.com/a/b",
                    "javascript:github.com/a/b", "https://github.com:8443/a/b", "http://github.com:443/a/b",
                    "https://github.com/a/b%2Fc", "https://github.com/a%2Fb/c", "https://github.com/a/%2E%2E",
                    "https://github.com/a/.git", "https://github.com/a/..git", "https://github.com/a/...git",
                    "https://github.com/a/repo/../other", "https://github.com/-owner/repo", "https://github.com/owner-/repo",
                    "https://github.com/own_er/repo", "https://github.com/a/r%C3%A9po"] {
            XCTAssertNil(GitHubRepository(url: URL(string: url)), url)
        }
        XCTAssertNil(GitHubRepository(url: nil))
        for route in GitHubRepository.reserved {
            XCTAssertNil(GitHubRepository(url: URL(string: "https://github.com/\(route.uppercased())/example")), route)
        }
    }
    func testGitHubNameLengthLimits() {
        func repo(_ owner: String, _ name: String) -> GitHubRepository? { .init(url: URL(string: "https://github.com/\(owner)/\(name)")) }
        XCTAssertNotNil(repo(String(repeating: "a", count: 39), String(repeating: "r", count: 100)))
        XCTAssertNil(repo(String(repeating: "a", count: 40), "repo"))
        XCTAssertNil(repo("owner", String(repeating: "r", count: 101)))
    }
}
