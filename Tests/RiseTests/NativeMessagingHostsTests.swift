import XCTest
@testable import Rise

final class NativeMessagingHostsTests: XCTestCase {
    func testUnavailableDestinationLeavesExistingFileUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("not-a-directory")
        try "keep this file".write(to: destination, atomically: true, encoding: .utf8)
        // A bad destination must be diagnosed without replacing it or stopping app startup.
        NativeMessagingHosts.link(into: destination, from: [])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep this file")
    }

    func testDesktopAppsHostsAreLinkedInKeptInStepAndOwnFilesAreLeftAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("Chrome"), chromium = root.appendingPathComponent("Chromium"), rise = root.appendingPathComponent("Rise")
        for folder in [chrome, chromium, rise] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "{}".write(to: chrome.appendingPathComponent("com.1password.1password.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: chromium.appendingPathComponent("com.1password.1password.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: chromium.appendingPathComponent("com.8bit.bitwarden.json"), atomically: true, encoding: .utf8)
        try "own".write(to: rise.appendingPathComponent("com.8bit.bitwarden.json"), atomically: true, encoding: .utf8)

        NativeMessagingHosts.link(into: rise, from: [chrome, chromium])
        let files = FileManager.default
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: rise.appendingPathComponent("com.1password.1password.json").path),
                       chrome.appendingPathComponent("com.1password.1password.json").path, "Chrome's registration first")
        XCTAssertEqual(try String(contentsOf: rise.appendingPathComponent("com.8bit.bitwarden.json"), encoding: .utf8), "own")

        // The app's gone from Chrome: its link follows Chromium's, then goes with that too.
        try files.removeItem(at: chrome.appendingPathComponent("com.1password.1password.json"))
        NativeMessagingHosts.link(into: rise, from: [chrome, chromium])
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: rise.appendingPathComponent("com.1password.1password.json").path),
                       chromium.appendingPathComponent("com.1password.1password.json").path)
        try files.removeItem(at: chromium.appendingPathComponent("com.1password.1password.json"))
        NativeMessagingHosts.link(into: rise, from: [chrome, chromium])
        XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: rise.appendingPathComponent("com.1password.1password.json").path))
    }
}
