// XCTest's assertions for live checks, so tests that need a real page can run on Chromium in a Rise
// window as they were written: each case prints PASS or FAIL with its name, and every failed
// assertion a FAIL line saying where. A tab's `web` is its page's view, which also runs scripts,
// takes pictures and loads pages at the addresses they pretend to be at (scripts/live-fixture-server.py).
import AppKit
@testable import Rise

struct XCTSkip: Error { let message: String; init(_ message: String = "") { self.message = message } }
struct XCTUnwrapError: Error, CustomStringConvertible { let description: String }

nonisolated(unsafe) var liveFailedCases: [String] = []
nonisolated(unsafe) private var liveCaseFailed = false

private func liveFail(_ message: String, _ file: StaticString, _ line: UInt) {
    print("FAIL \(("\(file)" as NSString).lastPathComponent):\(line) \(message)"); liveCaseFailed = true
}
private func attempt(_ name: String, _ message: () -> String, _ file: StaticString, _ line: UInt, _ body: () throws -> String?) {
    do { if let failure = try body() { liveFail("\(name) failed: \(failure) \(message())", file, line) } }
    catch { liveFail("\(name) threw \(error) \(message())", file, line) }
}

func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) { liveFail(message, file, line) }
func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertTrue", message, file, line) { try e() ? nil : "false" }
}
func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertFalse", message, file, line) { try e() ? "true" : nil }
}
func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertNil", message, file, line) { try e().map { "\($0)" } }
}
func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertNotNil", message, file, line) { try e() == nil ? "nil" : nil }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertEqual", message, file, line) { let (x, y) = (try a(), try b()); return x == y ? nil : "(\"\(x)\") is not equal to (\"\(y)\")" }
}
func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertEqual", message, file, line) { let (x, y) = (try a(), try b()); return abs(x-y) <= accuracy ? nil : "(\"\(x)\") is not equal to (\"\(y)\") +/- (\"\(accuracy)\")" }
}
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertNotEqual", message, file, line) { let (x, y) = (try a(), try b()); return x != y ? nil : "(\"\(x)\") is equal to (\"\(y)\")" }
}
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertGreaterThan", message, file, line) { let (x, y) = (try a(), try b()); return x > y ? nil : "(\"\(x)\") is not greater than (\"\(y)\")" }
}
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertGreaterThanOrEqual", message, file, line) { let (x, y) = (try a(), try b()); return x >= y ? nil : "(\"\(x)\") is less than (\"\(y)\")" }
}
func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertLessThan", message, file, line) { let (x, y) = (try a(), try b()); return x < y ? nil : "(\"\(x)\") is not less than (\"\(y)\")" }
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    attempt("XCTAssertLessThanOrEqual", message, file, line) { let (x, y) = (try a(), try b()); return x <= y ? nil : "(\"\(x)\") is greater than (\"\(y)\")" }
}
func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try e() else { liveFail("XCTUnwrap failed: nil \(message())", file, line); throw XCTUnwrapError(description: "nil at line \(line)") }
    return value
}

/// Runs one case, printing whether it passed.
@MainActor func liveCase(_ name: String, _ body: () async throws -> Void) async {
    liveCaseFailed = false
    do { try await body() }
    catch let skip as XCTSkip { print("SKIP \(name) \(skip.message)"); return }
    catch { if !liveCaseFailed || !(error is XCTUnwrapError) { liveFail("threw \(error)", #filePath, #line) } }
    if liveCaseFailed { liveFailedCases.append(name); print("FAIL \(name)") } else { print("PASS \(name)") }
}
/// The last line the runner reads.
@MainActor func liveFinish() -> Never {
    print(liveFailedCases.isEmpty ? "ALL PASSED" : "\(liveFailedCases.count) FAILED: \(liveFailedCases.joined(separator: ", "))")
    print("DONE"); exit(0)
}

/// Where the check's server finds the pages registered for an address.
enum LiveFixtures {
    static let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
    /// A page at `address`, which Chromium is sent to the check's server for.
    static func register(_ html: String, at address: URL) throws {
        var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)!; parts.fragment = nil
        let name = parts.string!.utf8.map { String(format: "%02x", $0) }.joined()
        let pages = folder.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try html.write(to: pages.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    /// A file of the repository's, from where this file is.
    static func repository(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
    }
}

nonisolated(unsafe) private var livePages: [ObjectIdentifier: WebPage] = [:]

@MainActor extension BrowserTab {
    /// The page's view, which `NSView`'s page calls below reach the page through.
    var web: NSView { livePages[ObjectIdentifier(page.view)] = page; return page.view }
}

@MainActor extension NSView {
    private var livePage: WebPage {
        guard let page = livePages[ObjectIdentifier(self)] else { fatalError("Not a tab's page view") }
        return page
    }
    var isLoading: Bool { livePage.isLoading }
    var url: URL? { livePage.url }
    var title: String? { livePage.title }
    var pageZoom: CGFloat { get { livePage.zoom } set { livePage.zoom = newValue } }
    func stopLoading() { livePage.stopLoading() }
    /// As WebKit's: the value of the script's last statement, run in the page's own world.
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await livePage.evaluate("return (0, eval)(source)", arguments: ["source": script], in: nil, world: .page)
    }
    /// The page at `baseURL`, as if it had loaded `html` from there.
    func loadHTMLString(_ html: String, baseURL: URL?) {
        guard let baseURL else { fatalError("Live fixtures need an address") }
        try! LiveFixtures.register(html, at: baseURL)
        livePage.load(baseURL)
    }
    /// The page's picture, or the part in `rect` (in the view's points, from its top left).
    func takeSnapshot(rect: CGRect = .null) async throws -> NSImage {
        guard let image = await livePage.snapshot(width: nil), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTUnwrapError(description: "no picture of the page") }
        guard !rect.isNull, bounds.width > 0 else { return image }
        let scale = CGFloat(cg.width)/bounds.width
        let crop = CGRect(x: rect.minX*scale, y: rect.minY*scale, width: rect.width*scale, height: rect.height*scale).integral
        guard let part = cg.cropping(to: crop) else { return image }
        return NSImage(cgImage: part, size: rect.size)
    }
}
