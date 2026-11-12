import XCTest
@testable import Rise

final class ChromiumFlagsTests: XCTestCase {
    func testDefaultsAreTurnedOnOnceAndAChoiceIsKept() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "RiseTests.Flags.\(UUID().uuidString)"))
        let file = profile.appendingPathComponent("Local State")
        try JSONSerialization.data(withJSONObject: ["browser": ["enabled_labs_experiments": ["smooth-scrolling@2"]], "other": 1]).write(to: file)
        func flags() throws -> [String] {
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(state["other"] as? Int, 1, "The rest of Local State stays")
            return (state["browser"] as? [String: Any])?["enabled_labs_experiments"] as? [String] ?? []
        }
        ChromiumFlags.prepare(profile, preferences: preferences)
        XCTAssertEqual(try flags(), ["smooth-scrolling@2", "canvas-draw-element@1"])

        try JSONSerialization.data(withJSONObject: ["browser": ["enabled_labs_experiments": [String]()], "other": 1]).write(to: file)
        ChromiumFlags.prepare(profile, preferences: preferences)
        XCTAssertEqual(try flags(), [], "Set back to Default on rise://flags, it stays")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((state["browser"] as? [String: Any])?["confirm_to_quit"] as? Bool, false, "⌘Q quits without Chrome's hold-to-quit warning")
    }
}
