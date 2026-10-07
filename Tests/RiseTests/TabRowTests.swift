import XCTest
import AppKit
import RiseCore
@testable import Rise

final class TabRowTests: XCTestCase {
    @MainActor func testSharedRowAcceptsIndependentPresentationOptionsAndSwapsAccessoryOnHover() {
        _ = NSApplication.shared
        let tab = BrowserTab()
        let row = TabRow(tab: tab, onClose: {})
        let image = TablerIcon.image(LucideIcon.hammer, size: 12, description: "Developer mode")
        let configuration = TabRowConfiguration(subtitle: .init(text: "custom subtitle", color: .systemPurple),
            constructionBorder: true, subtitleAccessory: image)
        row.update(tab: tab, selected: true, theme: .neutral, configuration: configuration)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: row.rowHeight)
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(tab.developer, "Presentation options do not depend on a page mode")
        XCTAssertTrue(row.configuration.constructionBorder)
        XCTAssertEqual(row.subtitle.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemPurple)
        XCTAssertEqual(row.subtitleAccessory.frame.midY, row.close.frame.midY)
        XCTAssertEqual(row.subtitleAccessory.frame.midX, row.close.frame.midX)
        XCTAssertEqual(row.subtitleAccessory.frame.size, NSSize(width: 12, height: 12))
        XCTAssertLessThanOrEqual(row.subtitle.frame.maxX, row.subtitleAccessory.frame.minX)
        XCTAssertFalse(row.subtitleAccessory.isHidden)
        XCTAssertTrue(row.close.isHidden)

        row.mouseEntered(with: NSEvent())
        XCTAssertTrue(row.subtitleAccessory.isHidden)
        XCTAssertFalse(row.close.isHidden)
        row.mouseExited(with: NSEvent())
        XCTAssertFalse(row.subtitleAccessory.isHidden)
        XCTAssertTrue(row.close.isHidden)

        row.update(tab: tab, selected: true, theme: .neutral, configuration: .init())
        XCTAssertFalse(row.configuration.constructionBorder)
        XCTAssertTrue(row.subtitleAccessory.isHidden)
        XCTAssertFalse(row.showsSubtitle)
    }

    @MainActor func testRepositoryHighlightKeepsUnicodePrefixMutedAndColorStable() throws {
        let tab = BrowserTab()
        tab.requestedURL = URL(string: "https://gitlab.com/équipe/🚀/projet/-/merge_requests/7")
        let first = TabRowConfiguration.forTab(tab, theme: .neutral)
        let second = TabRowConfiguration.forTab(tab, theme: .neutral)
        let subtitle = try XCTUnwrap(first.subtitle)
        XCTAssertEqual(subtitle.text, "équipe/🚀/projet")
        XCTAssertEqual(subtitle.color, second.subtitle?.color)
        let value = subtitle.attributedString(font: .systemFont(ofSize: 11), defaultColor: RiseTheme.neutral.muted)
        let suffix = (subtitle.text as NSString).range(of: "projet")
        XCTAssertEqual(subtitle.highlightRange, suffix)
        XCTAssertEqual(value.attribute(.foregroundColor, at: suffix.location-1, effectiveRange: nil) as? NSColor, RiseTheme.neutral.muted)
        XCTAssertEqual(value.attribute(.foregroundColor, at: suffix.location, effectiveRange: nil) as? NSColor, subtitle.color)
        XCTAssertFalse(first.constructionBorder)
        XCTAssertNil(first.subtitleAccessory)
    }

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
            row.update(tab: tab, selected: true, theme: .neutral, configuration: .forTab(tab, theme: .neutral))
            XCTAssertEqual(row.titleField.stringValue, "My merge request")
            XCTAssertEqual(row.subtitle.stringValue, "team/project")
            XCTAssertFalse(row.subtitle.isHidden)
        }
        tab.developer = true
        tab.requestedURL = URL(string: "http://localhost:3000")
        row.update(tab: tab, selected: true, theme: .neutral, configuration: .forTab(tab, theme: .neutral))
        XCTAssertEqual(row.subtitle.stringValue, "localhost:3000")
        XCTAssertFalse(row.subtitle.isHidden)
        XCTAssertEqual(row.rowHeight, TabAppearance.subtitleRowHeight)
        tab.developer = false
        tab.requestedURL = URL(string: "https://github.com/team/project/pull/7")
        row.update(tab: tab, selected: true, theme: .neutral, configuration: .forTab(tab, theme: .neutral))
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
        XCTAssertEqual(split.left.frame.height, TabAppearance.subtitleRowHeight)
        XCTAssertTrue(split.left.bounds.contains(split.left.subtitle.frame))
        XCTAssertFalse(split.left.subtitle.isHidden)
        XCTAssertTrue(split.right.subtitle.isHidden)
    }
}
