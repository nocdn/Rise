import XCTest
import UIKit
@testable import RiseiOS

final class SelectionMeasurementMenuTests: XCTestCase {
    @MainActor func testAMeasurementInOtherUnitsOpensToCopyReplaceAndOtherUnits() throws {
        let elements = SelectionMeasurementMenu.elements(for: "5 km", in: nil, units: .us)
        let menu = try XCTUnwrap(elements.first as? UIMenu)
        XCTAssertEqual(elements.count, 1)
        XCTAssertTrue(menu.title.hasSuffix(" mi"), menu.title)
        XCTAssertEqual(menu.children.map(\.title), ["Copy “\(menu.title)”", "Replace on Page", "Other Units"])
        XCTAssertEqual((menu.children[1] as? UIAction)?.state, .off)
        let others = try XCTUnwrap(menu.children[2] as? UIMenu).children.compactMap { ($0 as? UIAction)?.subtitle }
        XCTAssertFalse(others.isEmpty)
        XCTAssertFalse(others.contains { $0.hasPrefix("Kilomet") || $0 == "Miles" }, "Neither what it was written in nor what it's converted to")
        XCTAssertTrue(menu.identifier.rawValue.hasPrefix(SelectionMeasurementMenu.menuIdentifier.rawValue + "."))
    }

    @MainActor func testAMeasurementAlreadyInThePersonsUnitsHasNoMenuButStillReplacesTheSystems() {
        XCTAssertTrue(SelectionMeasurementMenu.elements(for: "5 km", in: nil, units: .metric).isEmpty)
        XCTAssertTrue(SelectionMeasurementMenu.hasMeasurement(in: "5 km"))
        XCTAssertFalse(SelectionMeasurementMenu.hasMeasurement(in: "Room 101"))
    }
}
