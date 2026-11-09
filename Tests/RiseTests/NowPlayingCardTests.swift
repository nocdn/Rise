import XCTest
import AppKit
@testable import Rise

final class NowPlayingCardTests: XCTestCase {
    @MainActor func testMediaWithoutAPositionOpensToTheRowAloneWithoutSkipping() {
        let card = NowPlayingCard()
        card.showPosition(time: 0, duration: .infinity)
        XCTAssertTrue(card.backButton.isHidden); XCTAssertTrue(card.forwardButton.isHidden)
        XCTAssertLessThan(card.expandedHeight, NowPlayingCard.expandedHeight, "No room kept for the bar")
        card.showPosition(time: 30, duration: 120)
        XCTAssertFalse(card.backButton.isHidden); XCTAssertFalse(card.forwardButton.isHidden)
        XCTAssertEqual(card.expandedHeight, NowPlayingCard.expandedHeight)
    }
}
