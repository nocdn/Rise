import XCTest
@testable import Rise

final class ChromiumProfileLayoutTests: XCTestCase {
    private let files = FileManager.default
    private func folder() throws -> URL {
        let base = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Rise")
        let legacy = base.appendingPathComponent("Chromium")
        try files.createDirectory(at: legacy.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data("cookies".utf8).write(to: legacy.appendingPathComponent("Default/Cookies"))
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("Local State"))
        try Data("[]".utf8).write(to: base.appendingPathComponent("session.json"))
        try files.createSymbolicLink(atPath: legacy.appendingPathComponent("SingletonLock").path, withDestinationPath: "host-999999")
        return base
    }

    func testChromiumsDataMovesUpOnceAndAnOlderRiseStillFindsIt() throws {
        let base = try folder(); defer { try? files.removeItem(at: base.deletingLastPathComponent()) }
        XCTAssertEqual(ChromiumProfileLayout.prepare(base, isRunning: { _ in false }), base)
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("Default/Cookies"), encoding: .utf8), "cookies", "Its data is directly in Rise's folder, as Chrome's is")
        XCTAssertTrue(files.fileExists(atPath: base.appendingPathComponent("Local State").path))
        XCTAssertTrue(files.fileExists(atPath: base.appendingPathComponent("session.json").path), "Rise's own files stay beside it")
        XCTAssertFalse(files.fileExists(atPath: base.appendingPathComponent("SingletonLock").path), "Chromium's stale lock isn't carried up")
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: base.appendingPathComponent("Chromium").path), ".")
        XCTAssertTrue(files.fileExists(atPath: base.appendingPathComponent("Chromium/Default/Cookies").path), "An older Rise, looking in Chromium, finds the same profile")
        XCTAssertEqual(ChromiumProfileLayout.prepare(base, isRunning: { _ in false }), base, "Once moved, it stays")
    }
    func testItStaysPutWhileARiseRunsOnItOrNamesClash() throws {
        let base = try folder(); defer { try? files.removeItem(at: base.deletingLastPathComponent()) }
        let legacy = base.appendingPathComponent("Chromium")
        XCTAssertEqual(ChromiumProfileLayout.prepare(base, isRunning: { $0 == 999999 }), legacy, "A Rise still running on it keeps it")
        try files.createDirectory(at: base.appendingPathComponent("Default"), withIntermediateDirectories: true)
        XCTAssertEqual(ChromiumProfileLayout.prepare(base, isRunning: { _ in false }), legacy, "Two profiles: neither is overwritten")
        XCTAssertTrue(files.fileExists(atPath: legacy.appendingPathComponent("Default/Cookies").path))
    }
    func testANewProfileStartsInRisesFolder() throws {
        let base = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Rise")
        defer { try? files.removeItem(at: base.deletingLastPathComponent()) }
        XCTAssertEqual(ChromiumProfileLayout.prepare(base), base)
    }
}
