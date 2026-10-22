import XCTest
import AppKit
@testable import Rise

/// GitHub's and GitLab's APIs, as far as the split needs them.
private final class ForgeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body: Any
        if url.path.hasSuffix("/pulls/7/files") {
            body = [["filename": "src/app.ts", "additions": 30, "deletions": 4], ["filename": "src/app.test.ts", "additions": 12, "deletions": 0]]
        } else if url.path.hasSuffix("/merge_requests/1") {
            body = ["title": "Add the banner", "state": "merged", "changes_count": "3"]
        } else if url.path.hasSuffix("/merge_requests/1/diffs") {
            body = [["new_path": "Sources/Banner.swift", "diff": "+a\n+b\n-c\n"], ["new_path": "Tests/BannerTests.swift", "diff": "+t\n"],
                    ["new_path": "package-lock.json", "diff": "+x\n-y\n"]]
        } else { body = [:] }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ChangeBreakdownTests: XCTestCase {
    func testFilesSortByTheirPathsAsT3CodeDoes() {
        let kinds: [(String, ChangeBreakdown.Kind)] = [
            ("src/app.ts", .code), ("Sources/Rise/Latest.swift", .code), ("src/app.test.ts", .tests), ("pkg/api_test.go", .tests),
            ("app/FooTest.java", .tests), ("tests/helpers.py", .tests), ("src/__mocks__/api.ts", .mocks), ("fixtures/user.json", .mocks),
            ("ui/__snapshots__/card.snap", .mocks), ("bun.lock", .generated), ("api/schema.generated.ts", .generated),
        ]
        for (path, kind) in kinds { XCTAssertEqual(ChangeBreakdown.kind(ofPath: path), kind, path) }
    }

    func testGitLabAndGitHubSplitTheLinesAndGiveUpWhenNotEveryFileIsCounted() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ForgeProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let request = try XCTUnwrap(PullRequest(url: URL(string: "https://gitlab.com/rise/app/-/merge_requests/1")!))
        let details = try await GitLabAPI.details(request, session: session)
        let split = try XCTUnwrap(details.breakdown)
        XCTAssertEqual(split.code, .init(additions: 2, deletions: 1)); XCTAssertEqual(split.tests, .init(additions: 1, deletions: 0))
        XCTAssertEqual(split.generated, .init(additions: 1, deletions: 1)); XCTAssertTrue(split.mocks.isEmpty)

        let pull = try XCTUnwrap(PullRequest(url: URL(string: "https://github.com/rise/app/pull/7")!))
        let github = try await GitHubAPI.breakdown(pull, changedFiles: 2, session: session)
        XCTAssertEqual(github?.code, .init(additions: 30, deletions: 4)); XCTAssertEqual(github?.tests, .init(additions: 12, deletions: 0))
        let partial = try await GitHubAPI.breakdown(pull, changedFiles: 900, session: session)
        XCTAssertNil(partial, "A split that doesn't add up to the whole isn't shown")
    }

    func testADiffIsReadFileByFileWithoutCountingItsHeaders() {
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1..2 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,3 @@
         unchanged
        --- a removed line that looks like a header
        +++ an added line that looks like one
        +added
        diff --git a/Tests/AppTests.swift b/Tests/AppTests.swift
        new file mode 100644
        --- /dev/null
        +++ b/Tests/AppTests.swift
        @@ -0,0 +1,2 @@
        +test one
        +test two
        \\ No newline at end of file
        """
        let read = ChangeBreakdown.read(diff: diff)
        XCTAssertEqual(read.breakdown.code, .init(additions: 2, deletions: 1))
        XCTAssertEqual(read.breakdown.tests, .init(additions: 2, deletions: 0))
        XCTAssertEqual(read.lines, .init(additions: 4, deletions: 1), "Matched against the pull request's own count before it's shown")
    }

    @MainActor func testALoneKindIsItsOwnTotalAndMoreKindsAddOne() {
        let card = ChangeBreakdownCard(), row = ChangeBreakdownCard.rowHeight, inset = ChangeBreakdownCard.inset.height
        let total = ChangeBreakdown.Lines(additions: 38, deletions: 3)
        func height(_ breakdown: ChangeBreakdown) -> CGFloat {
            card.show(breakdown, loading: false, total: total, below: NSRect(x: 10, y: 10, width: 80, height: 20), in: NSRect(x: 0, y: 0, width: 600, height: 400),
                      theme: .neutral, background: .white, text: .black)
            return card.frame.height
        }
        XCTAssertEqual(height(ChangeBreakdown(code: total)), row+2*inset, "Just code: one row, no total")
        XCTAssertEqual(height(ChangeBreakdown(code: .init(additions: 30, deletions: 3), tests: .init(additions: 8, deletions: 0))),
                       3*row+ChangeBreakdownCard.rowGap+2*ChangeBreakdownCard.dividerGap+1+2*inset, "Code and tests, then the total")
    }
    @MainActor func testHoveringTheFileCountShowsTheSplitUnderItAndLeavingHidesIt() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: 500)); window.contentView = host; window.orderFrontRegardless()
        let card = PullRequestTooltip(); host.addSubview(card)
        defer { card.dismiss(immediately: true); window.orderOut(nil) }
        var details = PullRequestDetails(title: "fix: it", state: .open, commits: 1, changedFiles: 2, additions: 42, deletions: 4)
        details.breakdown = ChangeBreakdown(code: .init(additions: 30, deletions: 4), tests: .init(additions: 12, deletions: 0))
        card.present(key: "pr", content: .init(title: "fix: it", reference: "#7", details: details, summary: "Fixes it.", phase: .done),
                     left: 20, placement: .beside(top: 20, maxBottom: 480), theme: .neutral)
        // The row places its link as it draws.
        try await Task.sleep(for: .milliseconds(100))
        var wanted = false; card.onWantsBreakdown = { wanted = true }
        func move(to point: NSPoint) {
            card.meta.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: card.meta.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        }
        let link = card.meta.linkRect
        move(to: NSPoint(x: link.midX, y: link.midY))
        try await Task.sleep(for: .milliseconds(Int(PullRequestTooltip.breakdownDelay*1000)+150))
        XCTAssertTrue(wanted); XCTAssertTrue(card.breakdownCard.isShown)
        let corner = host.convert(link, from: card.meta)
        XCTAssertEqual(card.breakdownCard.frame.origin.x, corner.maxX+ChangeBreakdownCard.gap.width, accuracy: 0.5, "Off the count's bottom right corner")
        XCTAssertEqual(card.breakdownCard.frame.origin.y, corner.maxY+ChangeBreakdownCard.gap.height, accuracy: 0.5)
        move(to: NSPoint(x: link.maxX+40, y: link.midY))
        XCTAssertFalse(card.breakdownCard.isShown)
    }
}
