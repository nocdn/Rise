import XCTest
import UIKit
@testable import RiseiOS

final class SummariseTests: XCTestCase {
    func testDecodesTheSummaryAroundOtherText() throws {
        let reply = """
        ```json
        {"overview":"An essay on templating.","sections":[{"symbol":"star.fill","heading":"Key Features","text":"Escaping by default."}]}
        ```
        """
        let summary = try PageSummary.decode(reply)
        XCTAssertEqual(summary.overview, "An essay on templating.")
        XCTAssertEqual(summary.sections.map(\.heading), ["Key Features"])
        XCTAssertThrowsError(try PageSummary.decode("Sorry, I can't."))
        XCTAssertThrowsError(try PageSummary.decode(#"{"overview":"  ","sections":[]}"#))
    }

    func testUnknownSymbolsFallBack() {
        let section = PageSummary.Section(symbol: "not.a.symbol", heading: "", text: "")
        XCTAssertEqual(PageSummary.symbol(for: section, at: 1), "star.fill")
        XCTAssertEqual(PageSummary.symbol(for: PageSummary.Section(symbol: "bolt.fill", heading: "", text: ""), at: 0), "bolt.fill")
    }

    /// The playground's springs: the reveal's and the close's, both critically damped.
    func testSpringsMatchThePlayground() {
        XCTAssertEqual(SummariseMotion.reveal(0), 0)
        XCTAssertEqual(SummariseMotion.reveal(0.1), 0.4004, accuracy: 1e-3)
        XCTAssertEqual(SummariseMotion.close(2), 1, accuracy: 1e-6)
    }

    /// The playground's pinch replay: the bar is gone while the card loads, the summary is
    /// revealed, and tapping the card grows it back into the page with the bar back in place.
    @MainActor func testPinchReplay() async throws {
        let controller = BrowserViewController(startURL: nil)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let folder = ProcessInfo.processInfo.environment["RISE_SUMMARISE_FRAMES"].map { URL(fileURLWithPath: $0) }
        let result = await SummariseReplay.run(in: controller, savingFramesTo: folder)
        XCTAssertGreaterThan(result.barWhileLoading, controller.bottomBar.bounds.height)
        XCTAssertTrue(result.revealed)
        XCTAssertGreaterThan(result.summaryHeight, 200)
        XCTAssertTrue(result.finished)
        XCTAssertEqual(controller.bottomBar.transform, .identity)
        XCTAssertTrue(controller.bottomBar.isUserInteractionEnabled)
    }
}
