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

    @MainActor func testARowSlideStartsWhenItsFrameIsShownSoWorkBeforeThenCannotEatIt() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 34)); view.wantsLayer = true
        TabListMotion.move(view, to: NSRect(x: 0, y: 40, width: 200, height: 34), animated: true)
        let slide = try XCTUnwrap(view.layer?.animation(forKey: TabListMotion.movementKey))
        // Stamped with the time of the layout, a slow page switch before the frame goes out
        // used to use up the whole slide, so rows jumped to their new places after ⌘W.
        XCTAssertEqual(slide.beginTime, 0, "It starts when the frame reaches the screen")
    }

    @MainActor func testControlROverAHoveredTabAndSmartRenameShimmerItsTitle() async throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
        let first = browser.addTab(), second = browser.addTab()
        browser.showWindow(nil); browser.root.layoutSubtreeIfNeeded()
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, characters: "\u{12}", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        let window = try XCTUnwrap(browser.window as? BrowserWindow)
        XCTAssertFalse(window.smartRenameEvent?(key) ?? true, "With no tab under the pointer, ⌃R goes on to the page")
        let row = try XCTUnwrap(browser.sidebar.rows[first.id])
        row.mouseEntered(with: NSEvent())
        XCTAssertTrue(window.performKeyEquivalent(with: key))
        XCTAssertTrue(row.titleShimmer.isRunning, "The hovered tab's title shimmers")
        XCTAssertNotEqual(row.titleField.textColor, browser.theme.muted, "Its text eases down to muted rather than jumping")
        try await Task.sleep(for: .milliseconds(InputShimmer.fade*1000+150))
        XCTAssertEqual(row.titleField.textColor, browser.theme.muted, "Then it's muted under the band")
        XCTAssertTrue(row.titleField.subviews.last === row.titleShimmer, "The band draws over the label AppKit adds for the title's own text")
        browser.update()
        XCTAssertEqual(row.titleField.textColor, browser.theme.muted, "Updating the row mid-shimmer doesn't bring the text back at once")
        let other = try XCTUnwrap(browser.sidebar.rows[second.id])
        XCTAssertFalse(other.titleShimmer.isRunning)
        let item = try XCTUnwrap(browser.makeTabMenu(second.id)?.items.first { $0.title == "Smart Rename" })
        _ = item.target?.perform(item.action, with: item)
        XCTAssertTrue(other.titleShimmer.isRunning, "Smart Rename in the tab's menu does the same")
    }
}
