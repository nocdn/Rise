import XCTest
import AppKit
import RiseCore
@testable import Rise

final class TabRowTests: XCTestCase {
    @MainActor func testGitLabRepositorySubtitleFitsAndMovesFollowingTabs() throws {
        _ = NSApplication.shared
        let sidebar = SidebarView(copy: {}, settings: {}, archive: {}, cleanUp: {})
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let mr = BrowserTab(), next = BrowserTab()
        mr.requestedURL = URL(string: "https://code.example.com/group/subgroup/repository/-/merge_requests/42/diffs?view=parallel#note_1")
        mr.title = "Fix the loading animation"
        sidebar.update(tabs: [mr, next], selected: mr, theme: .dark, animated: false)
        let row = try XCTUnwrap(sidebar.rows[mr.id]), nextRow = try XCTUnwrap(sidebar.rows[next.id])
        XCTAssertEqual(row.subtitle.stringValue, "group/subgroup/repository")
        XCTAssertFalse(row.subtitle.isHidden)
        XCTAssertEqual(row.subtitle.alphaValue, 1)
        XCTAssertEqual(row.titleField.stringValue, mr.title)
        XCTAssertGreaterThan(row.frame.height, nextRow.frame.height)
        XCTAssertTrue(row.bounds.contains(row.subtitle.frame))
        XCTAssertLessThan(row.icon.frame.midY, row.bounds.midY)
        XCTAssertLessThanOrEqual(row.titleField.frame.maxY, row.subtitle.frame.minY)
        XCTAssertEqual(nextRow.frame.minY, row.frame.maxY + TabAppearance.spacing)
        XCTAssertTrue(row.accessibilityLabel()?.contains("group/subgroup/repository") == true)

        mr.requestedURL = URL(string: "https://code.example.com/group/subgroup/repository/-/issues/42")
        sidebar.update(tabs: [mr, next], selected: mr, theme: .neutral, animated: false)
        XCTAssertTrue(row.subtitle.isHidden)
        XCTAssertEqual(row.icon.frame.midY, row.bounds.midY)
        XCTAssertEqual(row.frame.height, TabAppearance.height)
        XCTAssertEqual(nextRow.frame.minY, row.frame.maxY + TabAppearance.spacing)
    }

    @MainActor func testRepositorySubtitleSurvivesDeveloperToggleAndCustomTitle() {
        _ = NSApplication.shared
        let tab = BrowserTab()
        tab.requestedURL = URL(string: "https://gitlab.com/team/project/-/merge_requests/7")
        tab.rename("My merge request")
        let row = TabRow(tab: tab, onClose: {})
        for developer in [false, true, false] {
            tab.developer = developer
            row.update(tab: tab, selected: true, theme: .neutral)
            XCTAssertEqual(row.titleField.stringValue, "My merge request")
            XCTAssertEqual(row.subtitle.stringValue, "team/project")
            XCTAssertFalse(row.subtitle.isHidden)
        }
        tab.developer = true
        tab.requestedURL = URL(string: "http://localhost:3000")
        row.update(tab: tab, selected: true, theme: .neutral)
        XCTAssertEqual(row.subtitle.stringValue, "localhost:3000")
        XCTAssertFalse(row.subtitle.isHidden)
        XCTAssertEqual(row.rowHeight, TabAppearance.developerHeight)
        tab.developer = false
        tab.requestedURL = URL(string: "https://github.com/team/project/pull/7")
        row.update(tab: tab, selected: true, theme: .neutral)
        XCTAssertTrue(row.subtitle.isHidden)
        XCTAssertEqual(row.rowHeight, TabAppearance.height)
    }

    @MainActor func testSplitMergeRequestHasRoomForRepositorySubtitle() throws {
        _ = NSApplication.shared
        let sidebar = SidebarView(copy: {}, settings: {}, archive: {}, cleanUp: {})
        sidebar.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let mr = BrowserTab(), other = BrowserTab()
        mr.requestedURL = URL(string: "https://gitlab.com/team/project/-/merge_requests/7/commits")
        let group = SplitTabGroup(leftID: mr.id, rightID: other.id)
        sidebar.update(tabs: [mr, other], selected: mr, theme: .neutral, splits: [group], animated: false)
        let split = try XCTUnwrap(sidebar.splitRows[group.id])
        XCTAssertEqual(split.left.frame.height, TabAppearance.repositoryHeight)
        XCTAssertTrue(split.left.bounds.contains(split.left.subtitle.frame))
        XCTAssertFalse(split.left.subtitle.isHidden)
        XCTAssertTrue(split.right.subtitle.isHidden)
    }
}
