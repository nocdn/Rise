import XCTest
import AppKit
@testable import Rise

final class DownloadFlightTests: XCTestCase {
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        browser.showWindow(nil); return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.downloadFlight?.finish(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }

    /// The iOS app's flight, arcing over the top: it pops out at the click, rises, sweeps
    /// into the button and is gone as it arrives, the button jolting along the way it came.
    func testTheCardFollowsTheIOSFlight() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let path = DownloadFlightPath(from: CGPoint(x: 900, y: 400), to: CGPoint(x: 130, y: 780), within: bounds)
        XCTAssertEqual(path.pose(at: 0).position, path.origin)
        XCTAssertEqual(path.pose(at: path.duration).position, path.destination)
        XCTAssertEqual(path.pose(at: 0).scale, 0.86*0.42, accuracy: 0.001, "It starts small and pops up")
        XCTAssertGreaterThan(path.pose(at: 0.15).scale, 0.8)
        XCTAssertEqual(path.pose(at: path.duration).scale, 0.025, accuracy: 0.002, "and collapses into the button")
        XCTAssertEqual(path.pose(at: path.duration).opacity, 0, accuracy: 0.001)
        XCTAssertEqual(path.pose(at: path.duration/2).opacity, 1)
        XCTAssertGreaterThan(path.pose(at: path.duration/2).rotation, 0, "Heading left over the top, it leans right")
        XCTAssertTrue((0.34...0.54).contains(path.duration))
        XCTAssertLessThan(path.control.y, 400+(780-400)*0.35, "It rises first")
        XCTAssertLessThan(path.control.x, 900+(130-900)*0.35, "and bows over the top")
        XCTAssertTrue(bounds.insetBy(dx: 12, dy: 12).contains(path.control))
        XCTAssertTrue(CATransform3DIsIdentity(path.impact(at: 0)))
        XCTAssertFalse(CATransform3DIsIdentity(path.impact(at: 0.05)), "The button jolts as it lands")
        XCTAssertTrue(CATransform3DIsIdentity(path.impact(at: DownloadFlightPath.reactionDuration)))
    }

    /// The button's ring shows how much of the downloads in progress has come.
    @MainActor func testTheButtonFollowsDownloadsInProgress() throws {
        let browser = browser(); defer { clean(browser) }
        let glyph = browser.sidebar.archiveButton.glyph
        browser.updateDownloadsButton()
        XCTAssertEqual(glyph.state, .idle)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let progress = Progress(totalUnitCount: 200); progress.completedUnitCount = 50
        let id = browser.downloads.begin(folder.appendingPathComponent("a.zip"), progress: progress)
        XCTAssertEqual(glyph.state, .progress(0.25))
        let unknown = browser.downloads.begin(folder.appendingPathComponent("b.zip"), progress: Progress(totalUnitCount: -1))
        XCTAssertEqual(glyph.state, .indeterminate, "A download of unknown size turns the loop")
        browser.downloads.fail(unknown)
        XCTAssertEqual(glyph.state, .progress(0.25))
        browser.downloads.finish(id)
        XCTAssertEqual(glyph.state, .idle, "Done, the circle is whole again")
    }

    /// A download's card flies into a stand-in for the button, which shows again after.
    @MainActor func testADownloadFliesIntoTheButtonAndTheFlightClearsAway() async throws {
        let browser = browser(); defer { clean(browser) }
        browser.window?.setFrameOrigin(NSPoint(x: 80, y: 80))
        browser.root.layoutSubtreeIfNeeded()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let progress = Progress(totalUnitCount: 4_000_000); progress.completedUnitCount = 900_000
        let id = browser.downloads.begin(folder.appendingPathComponent("Quarterly report.pdf"), progress: progress)
        let item = try XCTUnwrap(browser.downloads.items.first { $0.record.id == id })
        browser.launchDownloadFlight(item)
        let flight = try XCTUnwrap(browser.downloadFlight)
        XCTAssertTrue(flight.superview === browser.root)
        XCTAssertFalse(flight.usesTray)
        XCTAssertTrue(browser.sidebar.archiveButton.isGlyphHidden, "A stand-in takes the jolt")
        XCTAssertEqual(flight.flights, 1)
        if let shots = ProcessInfo.processInfo.environment["RISE_FLIGHT_SHOTS"], let number = browser.window?.windowNumber {
            for (index, delay) in [80, 200, 330].enumerated() {
                try await Task.sleep(for: .milliseconds(index == 0 ? delay : delay-[80, 200, 330][index-1]))
                let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", "\(number)", "\(shots)/flight-\(index).png"]
                try shot.run(); shot.waitUntilExit()
            }
        }
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertNil(browser.downloadFlight)
        XCTAssertNil(flight.superview)
        XCTAssertFalse(browser.sidebar.archiveButton.isGlyphHidden)
    }
}
