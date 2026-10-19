import XCTest
@testable import Rise

final class PullRequestTooltipTests: XCTestCase {
    func testRecognizesPullRequestPagesAndTheirTabTitles() {
        let pr = PullRequest(url: URL(string: "https://github.com/swiftlang/swift/pull/80000/files"))
        XCTAssertEqual(pr?.key, "swiftlang/swift#80000")
        XCTAssertNil(PullRequest(url: URL(string: "https://github.com/swiftlang/swift/issues/80000")))
        XCTAssertNil(PullRequest(url: URL(string: "https://gitlab.com/a/b/pull/1")))
        XCTAssertEqual(pr?.title(fromTab: "fix(agc): exclude tests by bartek · Pull Request #12 · owner/repo"), "fix(agc): exclude tests")
        let mr = PullRequest(url: URL(string: "https://gitlab.com/group/sub/project/-/merge_requests/2/diffs"))
        XCTAssertEqual(mr?.project, "group/sub/project"); XCTAssertEqual(mr?.reference, "!2")
        XCTAssertEqual(mr?.key, "gitlab.com/group/sub/project!2")
        XCTAssertNil(PullRequest(url: URL(string: "https://gitlab.com/group/project/-/issues/2")))
        XCTAssertEqual(mr?.title(fromTab: "Port to rat 3.x: CrossGroup · test fixes (!2) · Merge requests · Group / Project · GitLab"), "Port to rat 3.x: CrossGroup · test fixes")
    }
    func testCardLinksGoToTheChangedFilesAndThePipelinesJobs() {
        XCTAssertEqual(PullRequest(url: URL(string: "https://github.com/a/b/pull/7"))?.filesURL?.absoluteString, "https://github.com/a/b/pull/7/files")
        XCTAssertEqual(PullRequest(url: URL(string: "https://gitlab.com/g/p/-/merge_requests/2"))?.filesURL?.absoluteString, "https://gitlab.com/g/p/-/merge_requests/2/diffs")
        let pipeline = Pipeline(gitLab: ["id": 2923862691, "status": "success", "web_url": "https://gitlab.com/g/p/-/pipelines/2923862691",
                                         "detailed_status": ["icon": "status_warning", "text": "Warning"]])
        XCTAssertEqual(pipeline?.status, .warning, "Passed with warnings shows GitLab's warning icon")
        XCTAssertEqual(pipeline?.jobsURL?.absoluteString, "https://gitlab.com/g/p/-/pipelines/2923862691/builds")
        XCTAssertEqual(Pipeline.Status(icon: nil, status: "waiting_for_resource"), .pending)
    }
    func testMergeChecksListWhatsInTheWay() {
        let open: [String: Any] = ["state": "opened", "detailed_merge_status": "discussions_not_resolved", "blocking_discussions_resolved": false,
                                   "head_pipeline": ["id": 1, "status": "failed", "web_url": "x"]]
        XCTAssertEqual(MergeCheck(gitLab: open, approvals: ["approvals_required": 2, "approvals_left": 1])?.blockers,
                       ["Open threads", "Pipeline", "1 of 2 Approvals"])
        XCTAssertEqual(MergeCheck(gitLab: ["state": "opened", "detailed_merge_status": "ci_must_pass"], approvals: nil)?.blockers, ["Pipeline must succeed"])
        XCTAssertEqual(MergeCheck(gitLab: ["state": "opened", "detailed_merge_status": "mergeable"], approvals: ["approvals_required": 0, "approvals_left": 0])?.ready, true)
        XCTAssertNil(MergeCheck(gitLab: ["state": "opened", "detailed_merge_status": "unchecked"], approvals: nil), "Not checked yet isn't ready")
        XCTAssertNil(MergeCheck(gitLab: ["state": "merged", "detailed_merge_status": "not_open"], approvals: nil))
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
        let draft = PullRequestTooltip.title("Draft: feat(ui): add it", color: .black, muted: .gray)
        let color2 = { (text: String) in draft.attribute(.foregroundColor, at: (draft.string as NSString).range(of: text).location, effectiveRange: nil) as? NSColor }
        XCTAssertEqual(color2("Draft: "), .gray); XCTAssertEqual(color2("feat("), .gray, "A type right after the marker still fades")
        XCTAssertEqual(color2("ui"), .black); XCTAssertEqual(color2("add"), .black)
        let bracket = PullRequestTooltip.title("[DRAFT] Fix the build", color: .black, muted: .gray)
        XCTAssertEqual(bracket.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .gray)
        XCTAssertEqual(bracket.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor, .black)
        let plain = PullRequestTooltip.title("Fix the build (again)", color: .black, muted: .gray)
        XCTAssertEqual(plain.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .black)
        // Without a scope, the whole type and its colon fade, `!` included; other words before a colon don't.
        for (text, faded) in [("fix: treg user agent", "fix:"), ("feat!: drop the old API", "feat!:"), ("Draft: chore: bump", "chore:")] {
            let styled = PullRequestTooltip.title(text, color: .black, muted: .gray), range = (text as NSString).range(of: faded)
            XCTAssertEqual(styled.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, .gray, text)
            XCTAssertEqual(styled.attribute(.foregroundColor, at: NSMaxRange(range)-1, effectiveRange: nil) as? NSColor, .gray, text)
            XCTAssertEqual(styled.attribute(.foregroundColor, at: NSMaxRange(range)+1, effectiveRange: nil) as? NSColor, .black, text)
        }
        let word = PullRequestTooltip.title("Update: readme", color: .black, muted: .gray)
        XCTAssertEqual(word.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .black)
    }
    @MainActor func testSavedCardsComeBackWithTheirDetailsAndDescription() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"a/b#1":{"summary":"Fixes it.","details":{"title":"fix: it","state":"merged","commits":2,"changedFiles":3,"additions":4,"deletions":5}}}"#.utf8).write(to: file)
        let entry = PullRequestSummaries(storageURL: file).entry(for: PullRequest(url: URL(string: "https://github.com/a/b/pull/1"))!)
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

/// The find bar's ⋯ at the card's bottom right, with the same menu.
final class PullRequestCardMenuTests: XCTestCase {
    @MainActor private func card(summary: String, mergeCheck: Bool, tokens: Int? = 12_345) -> PullRequestTooltip {
        let card = PullRequestTooltip()
        var details = PullRequestDetails(title: "fix: it", state: .open, commits: 1, changedFiles: 2, additions: 3, deletions: 4)
        if mergeCheck {
            details.mergeCheck = MergeCheck(gitLab: ["state": "opened", "detailed_merge_status": "ci_must_pass"], approvals: nil)
            details.pipeline = Pipeline(gitLab: ["id": 1, "status": "failed", "web_url": "https://gitlab.com/g/p/-/pipelines/1"])
        }
        card.present(key: "k", content: .init(title: "fix: it", reference: "!1", details: details, summary: summary, phase: .done, inputTokens: tokens),
                     left: 0, placement: .beside(top: 0, maxBottom: 2000), theme: .neutral)
        return card
    }
    @MainActor func testTheButtonSitsInlineWithTheLastStatusRow() throws {
        let card = card(summary: "Fixes the sidebar.", mergeCheck: true)
        XCTAssertFalse(card.moreButton.isHidden)
        let merge = try XCTUnwrap(card.subviews.first?.subviews.first?.subviews.first { $0 is MergeCheckRow })
        XCTAssertEqual(card.moreButton.frame.midY, round(merge.frame.midY), accuracy: 0.5)
        XCTAssertEqual(card.moreButton.frame.maxX, card.bounds.width-PullRequestTooltip.inset.width+4, accuracy: 0.5)
        XCTAssertEqual(card.moreButton.frame.size, NSSize(width: 22, height: 20), "The find bar's size")
    }
    @MainActor func testWithoutStatusRowsItEndsTheDescriptionOrGetsItsOwnRow() {
        let short = card(summary: "Fixes it.", mergeCheck: false)
        let shortHeight = short.frame.height
        XCTAssertFalse(short.moreButton.isHidden)
        XCTAssertGreaterThan(short.moreButton.frame.minY, 40, "On the description's line, under the title and stats")
        let long = card(summary: String(repeating: "Rewrites the whole thing ", count: 6) + "and the end of the line runs right to the edge of the card yes", mergeCheck: false)
        XCTAssertFalse(long.moreButton.isHidden)
        XCTAssertGreaterThan(long.frame.height, shortHeight)
        XCTAssertLessThanOrEqual(long.moreButton.frame.maxY, long.frame.height-PullRequestTooltip.inset.height+2)
    }
    @MainActor func testTheMenuMatchesTheFindBars() {
        let card = card(summary: "Fixes the sidebar.", mergeCheck: true)
        XCTAssertEqual(card.makeMoreMenu().items.map(\.title), ["Regenerate", "Copy", "Custom Content", "", "12,345 tok"])
        XCTAssertFalse(card.makeMoreMenu().items.last!.isEnabled)
        XCTAssertEqual(self.card(summary: "Fixes it.", mergeCheck: false, tokens: nil).makeMoreMenu().items.map(\.title), ["Regenerate", "Copy", "Custom Content"])
        XCTAssertFalse(card.makeMoreMenu().items[2].isEnabled, "Custom Content waits for an edit")
        var regenerated = 0; card.onRegenerate = { regenerated += 1 }
        let menu = card.makeMoreMenu()
        menu.performActionForItem(at: 0)
        XCTAssertEqual(regenerated, 1)
        let pasteboard = NSPasteboard.general, kept = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let kept { pasteboard.setString(kept, forType: .string) } }
        menu.performActionForItem(at: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Fixes the sidebar.")
    }
    @MainActor func testRegeneratingStartsTheDescriptionOver() {
        let card = card(summary: "Fixes the sidebar.", mergeCheck: true)
        card.update(.init(title: "fix: it", reference: "!1", details: nil, summary: "", phase: .generating))
        XCTAssertTrue(card.moreButton.isHidden, "Not while it's being written")
        card.update(.init(title: "fix: it", reference: "!1", details: nil, summary: "Adds", phase: .generating))
        card.update(.init(title: "fix: it", reference: "!1", details: nil, summary: "Adds a thing.", phase: .done, inputTokens: 9))
        XCTAssertFalse(card.moreButton.isHidden)
        XCTAssertEqual(card.makeMoreMenu().items.last?.title, "9 tok")
    }
}
