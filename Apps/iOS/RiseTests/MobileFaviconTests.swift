import XCTest
@testable import RiseiOS

final class MobileFaviconTests: XCTestCase {
    @MainActor func testAppearanceVariantsCachingAndVisibleTraitChanges() async throws {
        let checks = try await MobileFaviconAudit.exercise()
        XCTAssertGreaterThan(checks.count, 20)
        for (name, passed) in checks { XCTAssertTrue(passed, name) }
    }
}
