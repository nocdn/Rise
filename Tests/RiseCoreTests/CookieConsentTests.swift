import XCTest
import CryptoKit
@testable import RiseCore

@MainActor final class CookieConsentTests: XCTestCase {
    func testDefaultsHostScopeLegacyMigrationAndPrivatePreferences() {
        let suite = "CookieConsentTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "https://www.example.com/account")!
        defaults.set(["old.example"], forKey: "Rise.iOS.CookieBanners.DisabledSites")
        let policy = CookieConsentPolicy(preferences: defaults)
        XCTAssertFalse(policy.isEnabled(for: URL(string: "https://old.example")))
        XCTAssertTrue(policy.isEnabled(for: url))
        policy.setEnabled(false, for: url)
        XCTAssertFalse(CookieConsentPolicy(preferences: defaults).isEnabled(for: URL(string: "http://example.com/")))
        XCTAssertTrue(policy.isEnabled(for: URL(string: "https://other.example.com")))
        for invalid in ["file:///tmp/page", "rise://settings", "about:blank"] { XCTAssertFalse(policy.isEnabled(for: URL(string: invalid))) }
        let privatePolicy = CookieConsentPolicy(preferences: nil)
        privatePolicy.setEnabled(false, for: URL(string: "https://private.example")!)
        XCTAssertTrue(policy.isEnabled(for: URL(string: "https://private.example")))
        XCTAssertTrue(CookieConsentPolicy(preferences: nil).isEnabled(for: URL(string: "https://private.example")))
    }

    private func rules() throws -> CookieConsentRules {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ["cookie-consent.js": Data("/* test rule */".utf8), "cookie-consent-evals.json": Data(#"{"RISE_TEST":"true"}"#.utf8)]
        var assets: [[String: String]] = []
        for (file, bytes) in files {
            try bytes.write(to: folder.appendingPathComponent(file))
            assets.append(["file": file, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()])
        }
        try JSONSerialization.data(withJSONObject: ["assets": assets]).write(to: folder.appendingPathComponent("cookie-consent-manifest.json"))
        let rules = try CookieConsentRules.load(from: folder)
        XCTAssertTrue(rules.source.hasPrefix(CookieConsentRules.scriptMarker))
        try Data("tampered".utf8).write(to: folder.appendingPathComponent("cookie-consent.js"))
        XCTAssertThrowsError(try CookieConsentRules.load(from: folder))
        assets[0]["file"] = "../elsewhere.js"
        try JSONSerialization.data(withJSONObject: ["assets": assets]).write(to: folder.appendingPathComponent("cookie-consent-manifest.json"))
        XCTAssertThrowsError(try CookieConsentRules.load(from: folder))
        return rules
    }
    func testOnlyVerifiedAssetsCanSupplyExecutableRules() throws { _ = try rules() }

    func testBridgeRejectsUnknownCodeStaleDocumentsAndManualInteraction() async throws {
        let rules = try rules()
        var current: String? = "document", codeCalls = 0
        let session = CookieConsentSession<Int>(rules: { rules }, allowed: { true }) { _, _, _, world in
            if world == .page { codeCalls += 1; return true }
            return current.map { ["token": $0, "documentTime": 1234.5] }
        }
        session.enabled = true
        session.receive(["type": "ready", "token": "document"], in: 1, isMain: true)
        session.receive(["type": "eval", "token": "document", "id": "one", "snippetId": "UNTRUSTED", "code": "arbitrary()"], in: 1, isMain: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(codeCalls, 0)
        current = "new-document"
        session.receive(["type": "eval", "token": "document", "id": "two", "snippetId": "RISE_TEST"], in: 1, isMain: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(codeCalls, 0)
        current = nil // canAct() also returns null after a trusted manual interaction.
        session.receive(["type": "eval", "token": "document", "id": "three", "snippetId": "RISE_TEST"], in: 1, isMain: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(codeCalls, 0)
    }

    func testDisableBetweenTokenCheckAndEvaluationCancelsTheAction() async throws {
        let rules = try rules()
        var allowed = true, codeCalls = 0
        var pending: CheckedContinuation<Any?, Never>?
        let session = CookieConsentSession<Int>(rules: { rules }, allowed: { allowed }) { _, _, _, world in
            if world == .page { codeCalls += 1; return true }
            return await withCheckedContinuation { pending = $0 }
        }
        session.enabled = true
        session.receive(["type": "eval", "token": "document", "id": "one", "snippetId": "RISE_TEST"], in: 1, isMain: true)
        await Task.yield()
        allowed = false
        pending?.resume(returning: ["token": "document", "documentTime": 1234.5])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(codeCalls, 0)
    }

    func testEvaluationQuotaAndResponsesStayInTheOriginatingFrame() async throws {
        let rules = try rules()
        var codeCalls = 0, responses = 0
        let session = CookieConsentSession<Int>(rules: { rules }, allowed: { true }) { body, args, frame, world in
            XCTAssertEqual(frame, 42)
            if world == .page {
                codeCalls += 1
                XCTAssertTrue(body.hasPrefix("if (performance.timeOrigin !== documentTime) return false;"))
                XCTAssertEqual(args["documentTime"] as? Double, 1234.5)
                return true
            }
            if body.contains("respond(") { responses += 1; XCTAssertEqual(args["token"] as? String, "document"); return nil }
            return ["token": "document", "documentTime": 1234.5]
        }
        session.enabled = true
        session.receive(["type": "ready", "token": "document"], in: 42, isMain: false)
        for i in 0..<270 {
            session.receive(["type": "eval", "token": "document", "id": "\(i)", "snippetId": "RISE_TEST"], in: 42, isMain: false)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(codeCalls, 250); XCTAssertEqual(responses, 250)
    }

    func testLateReadyAtDisableIsRetainedForReenabling() async throws {
        let rules = try rules()
        var allowed = false, stops = 0, resumes = 0
        let session = CookieConsentSession<Int>(rules: { rules }, allowed: { allowed }) { body, _, _, _ in
            if body.contains(".stop()") { stops += 1 }
            if body.contains(".shouldResume()") { resumes += 1 }
            return nil
        }
        session.enabled = true
        session.stopFrames(forget: false)
        session.receive(["type": "ready", "token": "document"], in: 42, isMain: true)
        await Task.yield()
        allowed = true; session.resumeFrames()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(stops, 1); XCTAssertEqual(resumes, 1)
    }
}
