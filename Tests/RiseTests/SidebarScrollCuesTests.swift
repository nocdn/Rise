import XCTest
import AppKit
@testable import Rise

final class SidebarScrollCuesTests: XCTestCase {
    func testFadesAppearAwayFromTheEndsOnly() {
        XCTAssertEqual(SidebarScrollCues.Edges(offset: 0, contentHeight: 300, viewHeight: 300), .init(top: 0, bottom: 0), "A list that fits has none")
        XCTAssertEqual(SidebarScrollCues.Edges(offset: 0, contentHeight: 1000, viewHeight: 300), .init(top: 0, bottom: 1), "At the top, only the bottom")
        XCTAssertEqual(SidebarScrollCues.Edges(offset: 48, contentHeight: 1000, viewHeight: 300), .init(top: 0.5, bottom: 1), "It eases in over the first scroll")
        XCTAssertEqual(SidebarScrollCues.Edges(offset: 400, contentHeight: 1000, viewHeight: 300), .init(top: 1, bottom: 1))
        XCTAssertEqual(SidebarScrollCues.Edges(offset: 700, contentHeight: 1000, viewHeight: 300), .init(top: 1, bottom: 0), "At the bottom, only the top")
        XCTAssertEqual(SidebarScrollCues.Edges(offset: -30, contentHeight: 1000, viewHeight: 300), .init(top: 0, bottom: 1), "Rubber-banding past the top")
        XCTAssertEqual(SidebarScrollCues.Edges(offset: 730, contentHeight: 1000, viewHeight: 300), .init(top: 1, bottom: 0), "Rubber-banding past the bottom")
        XCTAssertEqual(SidebarScrollCues.fadeDepth(height: 200), 24)
        XCTAssertEqual(SidebarScrollCues.fadeDepth(height: 900), 40)
    }

    func testARowCountsAsGoneOnceItsPastTheEdge() {
        let visible = NSRect(x: 0, y: 100, width: 200, height: 300)
        func row(_ y: CGFloat) -> NSRect { NSRect(x: 0, y: y, width: 200, height: 34) }
        XCTAssertNil(SidebarScrollCues.direction(of: row(200), visible: visible))
        XCTAssertNil(SidebarScrollCues.direction(of: row(90), visible: visible), "Most of it still shows")
        XCTAssertEqual(SidebarScrollCues.direction(of: row(70), visible: visible), .above, "A sliver in the fade reads as gone")
        XCTAssertEqual(SidebarScrollCues.direction(of: row(0), visible: visible), .above)
        XCTAssertNil(SidebarScrollCues.direction(of: row(370), visible: visible))
        XCTAssertEqual(SidebarScrollCues.direction(of: row(390), visible: visible), .below)
    }

    func testThePillComesOutFromItsEdgeAroundItsMiddle() {
        let size = CGSize(width: 50, height: 26)
        for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5)] {
            func middle(_ direction: SidebarScrollCues.Direction) -> CGPoint {
                let start = ChosenTabPill.entranceStart(direction, size: size, anchor: anchor)
                let local = CGPoint(x: (0.5-anchor.x)*size.width, y: (0.5-anchor.y)*size.height)
                return CGPoint(x: local.x*start.m11+start.m41, y: local.y*start.m22+start.m42)
            }
            let local = CGPoint(x: (0.5-anchor.x)*size.width, y: (0.5-anchor.y)*size.height)
            XCTAssertEqual(ChosenTabPill.entranceStart(.below, size: size, anchor: anchor).m11, ChosenTabPill.entranceScale)
            XCTAssertEqual(middle(.below).x, local.x, accuracy: 0.001, "It scales around its middle")
            XCTAssertEqual(middle(.below).y, local.y+ChosenTabPill.entranceSlide, accuracy: 0.001, "From the bottom, it rises")
            XCTAssertEqual(middle(.above).y, local.y-ChosenTabPill.entranceSlide, accuracy: 0.001, "From the top, it drops")
        }
    }

    @MainActor private func listOfTabs(selecting index: Int = 0) -> (SidebarView, [BrowserTab]) {
        _ = NSApplication.shared
        let sidebar = SidebarView(archive: {}, cleanUp: {})
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        let tabs = (0..<30).map { _ in BrowserTab() }
        sidebar.update(tabs: tabs, selected: tabs[index], theme: .neutral, animated: false)
        return (sidebar, tabs)
    }
    @MainActor private func scroll(_ sidebar: SidebarView, to y: CGFloat) {
        sidebar.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        sidebar.scroll.reflectScrolledClipView(sidebar.scroll.contentView)
    }

    @MainActor func testTheListFadesAsItScrolls() {
        let (sidebar, _) = listOfTabs()
        XCTAssertEqual(sidebar.shownEdges, .init(top: 0, bottom: 1), "At rest at the top, only the bottom fades")
        XCTAssertNotNil(sidebar.scroll.layer?.mask)
        scroll(sidebar, to: 200)
        XCTAssertEqual(sidebar.shownEdges, .init(top: 1, bottom: 1))
        scroll(sidebar, to: sidebar.rowsHost.frame.height-sidebar.scroll.contentView.bounds.height)
        XCTAssertEqual(sidebar.shownEdges, .init(top: 1, bottom: 0), "At the bottom, only the top")
    }

    @MainActor func testAListThatFitsDoesNotFade() {
        _ = NSApplication.shared
        let sidebar = SidebarView(archive: {}, cleanUp: {})
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        let tab = BrowserTab()
        sidebar.update(tabs: [tab], selected: tab, theme: .neutral, animated: false)
        XCTAssertEqual(sidebar.shownEdges, .init(top: 0, bottom: 0))
        XCTAssertNil(sidebar.scroll.layer?.mask)
        XCTAssertNil(sidebar.chosenPill.direction)
    }

    @MainActor func testThePillPointsToTheChosenTabAndLeavesWhenItsBack() {
        let (sidebar, tabs) = listOfTabs(selecting: 0)
        let pill = sidebar.chosenPill
        XCTAssertNil(pill.direction, "The chosen tab's in view")
        scroll(sidebar, to: 300)
        XCTAssertEqual(pill.direction, .above)
        XCTAssertFalse(pill.isHidden)
        XCTAssertEqual(pill.frame.minY, sidebar.scroll.frame.minY+ChosenTabPill.inset, "At the list's top")
        XCTAssertEqual(pill.frame.midX, sidebar.bounds.midX, accuracy: 1)

        sidebar.update(tabs: tabs, selected: tabs[29], theme: .neutral, animated: false)
        XCTAssertEqual(pill.direction, .below)
        XCTAssertEqual(pill.frame.maxY, sidebar.scroll.frame.maxY-ChosenTabPill.inset, "At the list's bottom")

        sidebar.revealChosenTab()
        XCTAssertNil(pill.direction, "Clicking it scrolls the tab back")
        let row = sidebar.rows[tabs[29].id]!.frame
        XCTAssertTrue(sidebar.scroll.contentView.bounds.contains(row))
    }

    @MainActor func testClickingThePillPlacesTheTabInTheMiddleOrAsNearAsItCan() {
        let (sidebar, tabs) = listOfTabs(selecting: 15)
        scroll(sidebar, to: 0)
        XCTAssertEqual(sidebar.chosenPill.direction, .below)
        sidebar.revealChosenTab()
        let clip = sidebar.scroll.contentView.bounds
        XCTAssertEqual(sidebar.rows[tabs[15].id]!.frame.midY-clip.minY, clip.height/2, accuracy: 1, "In the middle")

        sidebar.update(tabs: tabs, selected: tabs[0], theme: .neutral, animated: false)
        sidebar.revealChosenTab()
        XCTAssertEqual(sidebar.scroll.contentView.bounds.minY, 0, "The first tab can't reach the middle")
        XCTAssertNil(sidebar.chosenPill.direction, "But it's shown")
    }

    @MainActor func testThePillStaysAwayWhileSearchingAndForPinnedTabs() {
        let (sidebar, tabs) = listOfTabs(selecting: 0)
        scroll(sidebar, to: 300)
        XCTAssertEqual(sidebar.chosenPill.direction, .above)
        sidebar.tabSearch = ""
        sidebar.relayout(animated: false)
        XCTAssertNil(sidebar.chosenPill.direction, "Searching, the list isn't where the tab is")
        sidebar.tabSearch = nil
        sidebar.relayout(animated: false)
        XCTAssertEqual(sidebar.chosenPill.direction, .above)
        tabs[0].pinned = true
        sidebar.update(tabs: tabs, selected: tabs[0], theme: .neutral, animated: false)
        XCTAssertNil(sidebar.chosenPill.direction, "A pinned tab's tile is always in view")
    }
}
