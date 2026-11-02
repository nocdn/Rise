import AppKit
import XCTest
import RiseCore
@testable import Rise

@MainActor final class GitHubLinkStatusTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Status did not settle")
    }
    func testLateResultsNeverReplaceAnotherRepositoryOrAnEndedHover() async throws {
        var pending: [String: CheckedContinuation<Bool?, Never>] = [:]
        let status = GitHubLinkStatus(delay: .zero) { repo in
            await withCheckedContinuation { pending[repo.path] = $0 }
        }
        let first = URL(string: "https://github.com/first/repo")!, second = URL(string: "https://github.com/second/repo")!
        status.hover(first); XCTAssertEqual(status.state, .checking)
        try await wait { pending["first/repo"] != nil }
        status.hover(second)
        try await wait { pending["second/repo"] != nil }
        pending.removeValue(forKey: "second/repo")?.resume(returning: true)
        try await wait { status.state == .starred }
        pending.removeValue(forKey: "first/repo")?.resume(returning: false)
        await Task.yield()
        XCTAssertEqual(status.state, .starred)
        status.hover(first)
        try await wait { pending["first/repo"] != nil }
        status.hover(nil)
        pending.removeValue(forKey: "first/repo")?.resume(returning: false)
        await Task.yield()
        XCTAssertNil(status.state)
    }
    func testShortCacheCoversRepositorySubpagesAndExpires() async throws {
        var date = Date(), calls = 0
        let status = GitHubLinkStatus(delay: .zero, now: { date }) { _ in calls += 1; return false }
        status.hover(URL(string: "https://github.com/owner/repo")!)
        try await wait { status.state == .unstarred }
        status.hover(nil)
        status.hover(URL(string: "https://github.com/OWNER/REPO/issues/1")!)
        XCTAssertEqual(status.state, .unstarred); XCTAssertEqual(calls, 1)
        status.hover(nil); date.addTimeInterval(16)
        status.hover(URL(string: "https://github.com/owner/repo")!)
        try await wait { calls == 2 && status.state == .unstarred }
        status.hover(URL(string: "https://github.com/settings/profile")!)
        XCTAssertNil(status.state)
    }
    func testUnavailableStatusIsNotAnUnstarredResultAndQuickPassesNeverFetch() async throws {
        var calls = 0
        let status = GitHubLinkStatus(delay: .zero) { _ in calls += 1; return nil }
        status.hover(URL(string: "https://github.com/owner/repo")!)
        try await wait { calls == 1 && status.state == nil }
        let delayed = GitHubLinkStatus(delay: .milliseconds(40)) { _ in calls += 1; return true }
        delayed.hover(URL(string: "https://github.com/owner/repo")!); delayed.hover(nil)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(calls, 1); XCTAssertNil(delayed.state)
    }
    func testExplicitStarWinsOverAnOlderRead() async throws {
        var finish: CheckedContinuation<Bool?, Never>?
        let status = GitHubLinkStatus(delay: .zero) { _ in await withCheckedContinuation { finish = $0 } }
        let url = URL(string: "https://github.com/owner/repo")!
        status.hover(url); try await wait { finish != nil }
        status.record(true, for: GitHubRepository(url: url)!)
        finish?.resume(returning: false); await Task.yield()
        XCTAssertEqual(status.state, .starred)
        status.hover(nil); status.hover(url)
        XCTAssertEqual(status.state, .starred)
    }
    func testPillKeepsTextAndHintGeometryWithNativeMiniSpinnerAndStarSwaps() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let pill = LinkStatusPill(), url = URL(string: "https://github.com/owner/repo")!
        window.contentView?.addSubview(pill)
        let page = NSRect(x: 0, y: 0, width: 800, height: 600)
        pill.show(url, theme: .dark); pill.setRepositoryState(.checking); pill.place(in: page); pill.layoutSubtreeIfNeeded()
        XCTAssertTrue(pill.showsRepositoryStatus)
        XCTAssertEqual(pill.repositoryGlyph.spinner.controlSize, .mini)
        XCTAssertEqual(pill.repositoryGlyph.spinner.bounds.width, 12)
        XCTAssertEqual(pill.text.frame.minX, 26)
        let textFrame = pill.text.frame, size = pill.frame.size
        pill.setRepositoryState(.unstarred); pill.place(in: page)
        XCTAssertEqual(pill.text.frame, textFrame); XCTAssertEqual(pill.frame.size, size)
        XCTAssertEqual(pill.repositoryGlyph.empty.layer?.opacity, 1)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let spring = try XCTUnwrap(pill.repositoryGlyph.empty.layer?.animation(forKey: "swap.scale") as? CASpringAnimation)
            XCTAssertEqual(spring.stiffness, 700)
        }
        pill.setRepositoryState(.starred)
        XCTAssertEqual(pill.repositoryGlyph.filled.layer?.opacity, 1)
        XCTAssertEqual(try XCTUnwrap(pill.repositoryGlyph.filled.layer).frame.midY, 6.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(pill.repositoryGlyph.empty.layer).frame.midY, 6.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(pill.repositoryGlyph.spinner.layer).frame.midY, 7, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(pill.repositoryGlyph.filled.layer).frame.midX, 7, accuracy: 0.01)
        pill.show(url, theme: .dark, peek: true); pill.place(in: page)
        XCTAssertTrue(pill.repositoryGlyph.isHidden); XCTAssertFalse(pill.showsRepositoryStatus)
        XCTAssertFalse(pill.peekSuffix.isHidden)
        pill.show(url, theme: .dark); pill.place(in: page)
        XCTAssertTrue(pill.showsRepositoryStatus); XCTAssertEqual(pill.text.frame, textFrame)
        pill.show(URL(string: "https://example.com")!, theme: .dark); pill.place(in: page)
        XCTAssertFalse(pill.showsRepositoryStatus); XCTAssertEqual(pill.text.frame.minX, 12)
    }
}
