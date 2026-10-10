import XCTest
import AppKit
@testable import Rise

final class InfoPlaqueTests: XCTestCase {
    @MainActor func testAnotherKindSitsToTheLeftAndMovesOverAsTheFirstLeaves() throws {
        _ = NSApplication.shared
        // In a window, so the springs run instead of settling; the test steps them itself.
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        let plaque = InfoPlaque(); plaque.frame = window.contentView!.bounds
        window.contentView?.addSubview(plaque)
        defer { plaque.hide(); window.orderOut(nil) }
        func settle() { plaque.notices.forEach { $0.settle() } }
        plaque.show("Link copied", image: InfoPlaque.linkCopiedIcon, kind: "link"); settle()
        let corner = plaque.panel.frame.maxX
        plaque.show("Simulated full screen enabled", image: InfoPlaque.fullScreenIcon, kind: "fullscreen")
        XCTAssertEqual(plaque.notices.map(\.kind), ["link", "fullscreen"])
        let (first, second) = (plaque.notices[0], plaque.notices[1])
        XCTAssertEqual(second.shift.value, first.panelWidth+InfoPlaque.spacing, accuracy: 0.01, "The second drops straight into its place")
        settle()
        XCTAssertEqual(first.panel.frame.maxX, corner, accuracy: 0.5, "The first keeps the corner")
        XCTAssertEqual(second.panel.frame.maxX, first.panel.frame.minX-InfoPlaque.spacing, accuracy: 0.5, "The second sits to its left")
        XCTAssertEqual(plaque.text, "Simulated full screen enabled")
        // The same kind again updates its own notice rather than adding one.
        plaque.show("Link copied", image: InfoPlaque.linkCopiedIcon, kind: "link")
        XCTAssertEqual(plaque.notices.count, 2)
        settle()
        XCTAssertEqual(first.panel.frame.maxX, corner, accuracy: 0.5)
        // As the first starts leaving, the second starts moving into its place (popLayout).
        first.hide()
        XCTAssertEqual(second.shift.target, 0, "The leaving notice no longer takes room")
        XCTAssertTrue(plaque.isPresented)
        let start = second.panel.frame.maxX
        for _ in 0..<4 { plaque.notices.forEach { $0.step(1.0/60) } }
        plaque.notices.forEach { $0.render() }
        XCTAssertGreaterThan(first.slide.value, 0.05, "The first is still on its way up")
        XCTAssertGreaterThan(second.panel.frame.maxX, start+10, "...while the second already moves right")
        for _ in 0..<120 { plaque.notices.forEach { $0.step(1.0/60) } }
        plaque.notices.forEach { $0.render() }
        XCTAssertEqual(second.panel.frame.maxX, corner, accuracy: 0.5, "It ends in the corner")
        XCTAssertTrue(first.isOut)
        // A notice leaving to the left doesn't move the one in the corner.
        plaque.show("Link copied", image: InfoPlaque.linkCopiedIcon, kind: "link"); settle()
        let link = try XCTUnwrap(plaque.notices.last { $0.kind == "link" && $0.isPresented })
        XCTAssertEqual(link.panel.frame.maxX, second.panel.frame.minX-InfoPlaque.spacing, accuracy: 0.5, "A new notice goes on the left")
        link.hide()
        XCTAssertEqual(second.shift.target, 0)
    }
}
