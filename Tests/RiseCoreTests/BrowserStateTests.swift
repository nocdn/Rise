import XCTest
@testable import RiseCore

final class BrowserStateTests: XCTestCase {
    func testOlderSessionsWithoutGroupsStillDecode() throws {
        let data = Data("{\"tabs\":[],\"theme\":\"dark\",\"sidebarWidth\":228}".utf8)
        let session = try JSONDecoder().decode(BrowserSession.self, from: data)
        XCTAssertEqual(session.theme, "dark")
        XCTAssertTrue(session.splitGroups.isEmpty)
        let tabJSON = "{\"id\":\"\(UUID())\",\"url\":\"https://example.com\",\"title\":\"Example\",\"pinned\":false,\"developer\":false}"
        let tab = try JSONDecoder().decode(SavedTab.self, from: Data(tabJSON.utf8))
        XCTAssertNil(tab.faviconData); XCTAssertNil(tab.faviconOrigin)
    }
    func testMissingDuplicateAndOverlappingSplitMembersAreDiscarded() throws {
        let a = SavedTab(url: "about:blank", title: "A"), b = SavedTab(url: "about:blank", title: "B"), c = SavedTab(url: "about:blank", title: "C")
        let valid = SplitTabGroup(leftID: a.id, rightID: b.id)
        let session = BrowserSession(tabs: [a, b, c], splitGroups: [valid, valid,
            SplitTabGroup(leftID: b.id, rightID: c.id), SplitTabGroup(leftID: c.id, rightID: c.id),
            SplitTabGroup(leftID: c.id, rightID: UUID())])
        let restored = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.splitGroups, [valid])
    }
    func testSplitsKeepTheirDraggedWidthAndOlderOnesSplitDownTheMiddle() throws {
        let a = UUID(), b = UUID()
        let older = try JSONDecoder().decode(SplitTabGroup.self, from: Data("{\"id\":\"\(UUID())\",\"leftID\":\"\(a)\",\"rightID\":\"\(b)\"}".utf8))
        XCTAssertEqual(older.fraction, 0.5)
        let dragged = SplitTabGroup(leftID: a, rightID: b, fraction: 0.3)
        XCTAssertEqual(try JSONDecoder().decode(SplitTabGroup.self, from: JSONEncoder().encode(dragged)).fraction, 0.3)
        XCTAssertEqual(SplitTabGroup(leftID: a, rightID: b, fraction: 0.99).fraction, SplitTabGroup.fractionRange.upperBound, "Neither page can be squeezed away")
    }
    func testHTTPSAndPaths() {
        XCTAssertEqual(AddressResolver.resolve("example.com/a?x=1")?.absoluteString, "https://example.com/a?x=1")
        XCTAssertEqual(AddressResolver.resolve(" https://example.com ")?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressResolver.resolve("http://example.com")?.scheme, "http")
    }
    func testRisePagesOpenRatherThanSearch() {
        XCTAssertEqual(AddressResolver.resolve("rise://settings")?.absoluteString, "rise://settings")
        XCTAssertEqual(AddressResolver.resolve("rise://settings/privacy")?.absoluteString, "rise://settings/privacy")
    }
    func testLocalDevelopmentAddresses() {
        XCTAssertEqual(AddressResolver.resolve("localhost:8190/a")?.absoluteString, "http://localhost:8190/a")
        XCTAssertEqual(AddressResolver.resolve("127.0.0.1:8000")?.scheme, "http")
        XCTAssertEqual(AddressResolver.resolve("app.localhost:8080")?.scheme, "http")
        XCTAssertEqual(AddressResolver.resolve("[::1]:8080")?.scheme, "http")
        XCTAssertTrue(AddressResolver.isLocal(URL(string: "http://[::1]:8080")))
        XCTAssertTrue(AddressResolver.isLocal(URL(string: "http://localhost:8190")))
        XCTAssertFalse(AddressResolver.isLocal(URL(string: "https://localhost.evil.example")))
    }
    func testSearchIsEncoded() {
        let url = AddressResolver.resolve("cats & dogs + birds")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.host, "www.google.com")
        XCTAssertEqual(components.queryItems?.first?.value, "cats & dogs + birds")
    }
    func testSelectedSearchEngineOnlyChangesSearchQueriesAndPreservesEncoding() throws {
        let query = "résumé & cats + dogs?"
        for engine in SearchEngine.allCases {
            let url = try XCTUnwrap(AddressResolver.resolve(query, searchEngine: engine))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.host, engine == .google ? "www.google.com" : "kagi.com")
            XCTAssertEqual(components.path, "/search"); XCTAssertEqual(components.queryItems?.first?.value, query)
            XCTAssertEqual(AddressResolver.resolve("https://example.com/a?q=test", searchEngine: engine)?.absoluteString, "https://example.com/a?q=test")
            XCTAssertEqual(AddressResolver.resolve("localhost:8000", searchEngine: engine)?.absoluteString, "http://localhost:8000")
            XCTAssertEqual(AddressResolver.resolve("/tmp/example.html", searchEngine: engine)?.path, "/tmp/example.html")
            XCTAssertNil(AddressResolver.resolve(" ", searchEngine: engine))
        }
    }
    func testWhitespaceAndUntrustedSchemes() {
        XCTAssertNil(AddressResolver.resolve(" \n "))
        XCTAssertEqual(AddressResolver.resolve("javascript:alert(1)")?.host, "www.google.com")
        XCTAssertEqual(AddressResolver.resolve("data:text/html,hello")?.host, "www.google.com")
    }
    func testBlankAndFiles() {
        XCTAssertEqual(AddressResolver.resolve("about:blank")?.absoluteString, "about:blank")
        XCTAssertEqual(AddressResolver.resolve("/tmp/a b.html")?.path, "/tmp/a b.html")
    }
    func testHostDisplay() {
        XCTAssertEqual(AddressResolver.displayHost(URL(string: "https://www.example.com/path")), "example.com")
        XCTAssertEqual(AddressResolver.displayHost(nil), "Search or Enter URL…")
    }
    func testSessionSurvivesDiskRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let tab = SavedTab(url: "https://example.com", title: "Example", pinned: true, developer: true)
        let session = BrowserSession(tabs: [tab], selectedID: tab.id, theme: "rose", sidebarWidth: 228)
        try SessionStorage.write(session, to: path)
        XCTAssertEqual(SessionStorage.read(from: path), session)
    }
    /// Each tab's engine state is a file of its own, written only when it changes, and only one
    /// whose digest the session names is restored; sessions with it inline still read.
    func testTabStatesLiveBesideTheSessionAndOnlyTheirOwnRestore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("session.json")
        let a = SavedTab(url: "https://a.example", title: "A", sessionState: Data(repeating: 1, count: 5000))
        let b = SavedTab(url: "https://b.example", title: "B", sessionState: Data([2, 3]))
        try SessionStorage.write(BrowserSession(tabs: [a, b]), to: path)
        XCTAssertFalse(try String(contentsOf: path, encoding: .utf8).contains("sessionState"), "The states aren't in the session")
        XCTAssertEqual(SessionStorage.read(from: path)?.tabs, [a, b])
        let fileA = SessionStorage.stateFile(a.id, for: path), fileB = SessionStorage.stateFile(b.id, for: path)
        let written = try FileManager.default.attributesOfItem(atPath: fileA.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        var b2 = b; b2.sessionState = Data([4])
        try SessionStorage.write(BrowserSession(tabs: [a, b2]), to: path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fileA.path)[.modificationDate] as? Date, written, "Unchanged, not written again")
        // A state file that isn't the one the session names stays unrestored: B opens from its history.
        try Data([9]).write(to: fileB)
        XCTAssertNil(SessionStorage.read(from: path)?.tabs[1].sessionState)
        XCTAssertEqual(SessionStorage.read(from: path)?.tabs[0], a)
        // A closed tab's state goes with it.
        try SessionStorage.write(BrowserSession(tabs: [a]), to: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileB.path))
        // A session from before, with its states inline, reads as it did.
        let encoder = JSONEncoder()
        try encoder.encode(BrowserSession(tabs: [b])).write(to: path)
        XCTAssertEqual(SessionStorage.read(from: path)?.tabs, [b])
    }
    func testCorruptSessionFailsGracefully() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("not json".utf8).write(to: path)
        XCTAssertNil(SessionStorage.read(from: path))
    }
}
