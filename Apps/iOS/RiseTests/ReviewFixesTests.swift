import AVFoundation
import Speech
import UIKit
import XCTest
import os
@testable import RiseiOS

final class ReviewFixesTests: XCTestCase {
    @MainActor func testNetworkGateShowsConsentAndCancellationSendsNothing() async throws {
        let defaults = UserDefaults.standard
        let keys = ["Rise.AI.Enabled"]+AIProvider.allCases.map { "Rise.AI.SharingConsent.\($0.rawValue)" }
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(true, forKey: "Rise.AI.Enabled")
        MobileAISettings.shared.revokeSharingConsent()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConsentGateProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ConsentGateProtocol.requests.withLock { $0 = 0 }
        let task = Task {
            try await ModelService.run([["role": "user", "content": "private fixture"]],
                provider: ModelChoice(provider: .openRouter, model: PageAssistant.model, effort: "low", apiKey: "fixture"),
                session: session) { _ in XCTFail("No output without permission") }
        }
        defer { task.cancel() }
        for _ in 0..<100 {
            if host.presentedViewController is UIAlertController { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let alert = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertTrue(alert.message?.contains("private tabs") == true)
        XCTAssertEqual(alert.actions.map(\.title), ["Don’t Allow", "Privacy Policy", "Allow"])
        XCTAssertEqual(ConsentGateProtocol.requests.withLock { $0 }, 0)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled prompt must abort the request") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(ConsentGateProtocol.requests.withLock { $0 }, 0)
        XCTAssertFalse(MobileAISettings.shared.hasSharingConsent(for: .openRouter))
        for _ in 0..<100 {
            if host.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(host.presentedViewController)
    }

    @MainActor func testDeleteFileDeletesBytesAndPersistedRecordButClearKeepsFile() throws {
        let directory = URL.temporaryDirectory.appending(path: "RiseDeleteTests-\(UUID())")
        let folder = directory.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), keptID = UUID(), missingID = UUID()
        let deleted = folder.appending(path: "delete.txt"), kept = folder.appending(path: "keep.txt")
        let missing = folder.appending(path: "missing.txt")
        for url in [deleted, kept, missing] { try Data("fixture".utf8).write(to: url) }
        let records: [[String: Any]] = [(id, deleted), (keptID, kept), (missingID, missing)].map {
            ["id": $0.0.uuidString, "name": $0.1.lastPathComponent, "date": 0]
        }
        try JSONSerialization.data(withJSONObject: records).write(to: directory.appending(path: "Downloads.json"))
        let downloads = MobileDownloads(directory: directory)
        XCTAssertEqual(downloads.items.count, 3)
        try downloads.deleteFile(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.path))
        XCTAssertNil(downloads.item(id))
        XCTAssertEqual(MobileDownloads(directory: directory).items.count, 2)
        try FileManager.default.removeItem(at: missing)
        try downloads.deleteFile(missingID)
        XCTAssertNil(downloads.item(missingID), "An externally deleted file can have its stale row cleared")
        downloads.remove(keptID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "Clear is still list-only")
        XCTAssertTrue(MobileDownloads(directory: directory).items.isEmpty)
    }

    @MainActor func testDeletionFailureKeepsRow() throws {
        let directory = URL.temporaryDirectory.appending(path: "RiseDeleteFailure-\(UUID())")
        let folder = directory.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), url = folder.appending(path: "file.txt")
        try Data("fixture".utf8).write(to: url)
        try JSONSerialization.data(withJSONObject: [["id": id.uuidString, "name": "file.txt", "date": 0]])
            .write(to: directory.appending(path: "Downloads.json"))
        let downloads = MobileDownloads(directory: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try downloads.deleteFile(id))
        XCTAssertNotNil(downloads.item(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testConsentIsExplicitPerProviderPersistedAndRevocable() async throws {
        let name = "Rise.Consent.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MobileAISettings(defaults: defaults, credentials: MobileAIKeyStore(service: name))
        var prompts: [AIProvider] = []
        var allow = false
        let consent = MobileAIConsent(settings: settings) { provider in prompts.append(provider); return allow }
        XCTAssertTrue(settings.enabled)
        do { try await consent.authorize(.openRouter); XCTFail("Denied consent must cancel") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(settings.hasSharingConsent(for: .openRouter))
        allow = true
        try await consent.authorize(.openRouter)
        try await consent.authorize(.openRouter)
        XCTAssertEqual(prompts.count, 2, "Permission is reused only after explicitly allowing it")
        try await consent.authorize(.openAI)
        XCTAssertEqual(prompts.last, .openAI)
        let reopened = MobileAISettings(defaults: defaults, credentials: MobileAIKeyStore(service: name))
        XCTAssertTrue(reopened.hasSharingConsent(for: .openAI))
        settings.enabled = false
        XCTAssertFalse(settings.hasSharingConsent(for: .openRouter))
        XCTAssertFalse(settings.hasSharingConsent(for: .openAI))
        settings.enabled = true
        try await consent.authorize(.openAI)
        XCTAssertEqual(prompts.count, 4)
        let racingConsent = MobileAIConsent(settings: settings) { _ in
            settings.revokeSharingConsent(); return true
        }
        do { try await racingConsent.authorize(.openRouter); XCTFail("A revoked pending prompt cannot regrant permission") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(settings.hasSharingConsent(for: .openRouter))
    }

    @MainActor func testCancellationCannotGrantConsent() async throws {
        let name = "Rise.Consent.Cancel.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MobileAISettings(defaults: defaults, credentials: MobileAIKeyStore(service: name))
        let consent = MobileAIConsent(settings: settings) { _ in
            try await Task.sleep(for: .seconds(30)); return true
        }
        let task = Task { try await consent.authorize(.openRouter) }
        await Task.yield()
        task.cancel()
        do { try await task.value; XCTFail("Cancelled request must not be authorized") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(settings.hasSharingConsent(for: .openRouter))
    }

    @MainActor func testPolicyIsBundledLinkedAndRevokesConsent() throws {
        let file = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "html"))
        let policy = try String(contentsOf: file, encoding: .utf8)
        for phrase in ["OpenRouter", "OpenAI", "private tabs", "Google", "Keychain", "mailto:"] {
            XCTAssertTrue(policy.contains(phrase))
        }
        let panel = AppSettingsPanel(frame: CGRect(x: 0, y: 0, width: 393, height: 650))
        panel.layoutIfNeeded()
        XCTAssertTrue(panel.buttons.contains { $0 === panel.privacyRow })
        XCTAssertGreaterThan(panel.privacyRow.frame.minY, panel.aiOptionsRow.frame.maxY)
        let name = "Rise.Privacy.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MobileAISettings(defaults: defaults, credentials: MobileAIKeyStore(service: name))
        settings.allowSharing(with: .openAI)
        settings.provider = .openAI
        let privacy = PrivacyPolicyPanel(settings: settings)
        privacy.frame = CGRect(x: 0, y: 0, width: 393, height: PrivacyPolicyPanel.height)
        privacy.prepare()
        privacy.layoutIfNeeded()
        XCTAssertFalse(try XCTUnwrap(privacy.policyView).configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertTrue(privacy.sharingRow.toggle.isOn)
        privacy.sharingRow.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(settings.hasSharingConsent(for: .openAI))
        XCTAssertFalse(settings.hasSharingConsent(for: .openRouter))
        XCTAssertFalse(privacy.sharingRow.toggle.isOn)
        privacy.sharingRow.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(settings.hasSharingConsent(for: .openAI))
        XCTAssertFalse(settings.hasSharingConsent(for: .openRouter))
        settings.enabled = false
        privacy.refresh()
        XCTAssertFalse(privacy.sharingRow.toggle.isOn)
        XCTAssertFalse(privacy.sharingRow.toggle.isEnabled)
    }

    @MainActor func testPrivacyMorphsInPlaceScrollsPermissionAndReturnsToSettings() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let browser = InteractionAudit.makeBrowser()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        browser.view.layoutIfNeeded()
        browser.openPanel(.menu)
        browser.openSiteSettings()
        browser.openAppSettings()
        try await Task.sleep(for: .milliseconds(450))
        let bar = browser.bottomBar
        let settingsHeight = bar.bounds.height
        bar.appSettings.privacyRow.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(bar.panel, .privacyPolicy)
        XCTAssertNil(browser.presentedViewController, "Privacy stays in the existing settings panel")
        XCTAssertTrue(bar.shown === bar.privacyPolicy)
        XCTAssertGreaterThan(bar.bounds.height, settingsHeight)
        let privacy = bar.privacyPolicy, page = try XCTUnwrap(privacy.policyView)
        for _ in 0..<100 {
            if !page.isLoading && page.scrollView.contentSize.height > page.bounds.height { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThan(page.scrollView.contentSize.height, page.bounds.height)
        XCTAssertTrue(privacy.sharingRow.superview === page.scrollView)
        let startingRow = privacy.sharingRow.convert(privacy.sharingRow.bounds, to: privacy)
        XCTAssertLessThan(startingRow.minY, page.frame.minY+30)
        XCTAssertGreaterThan(page.scrollView.contentInset.top, SiteSettingsPanel.rowHeight)
        page.scrollView.setContentOffset(CGPoint(x: 0, y: 250), animated: false)
        privacy.layoutIfNeeded()
        let scrolledRow = privacy.sharingRow.convert(privacy.sharingRow.bounds, to: privacy)
        XCTAssertLessThan(scrolledRow.minY, startingRow.minY-200, "Permission scrolls away with the policy")
        XCTAssertFalse(privacy.canPullToClose(at: CGPoint(x: page.frame.midX, y: page.frame.midY), velocity: CGPoint(x: 0, y: 200)))
        page.scrollView.setContentOffset(CGPoint(x: 0, y: -page.scrollView.adjustedContentInset.top), animated: false)
        XCTAssertTrue(privacy.canPullToClose(at: CGPoint(x: page.frame.midX, y: page.frame.midY), velocity: CGPoint(x: 0, y: 200)))
        let mask = try XCTUnwrap(page.layer.mask as? CAGradientLayer)
        XCTAssertEqual(mask.frame, page.bounds, "The fade stays on the viewport as the policy scrolls")
        XCTAssertGreaterThan(page.scrollView.contentInset.bottom, SummariseMotion.followUpFade.height,
                             "The final lines can scroll completely clear of the fade")
        let folder = URL.cachesDirectory.appending(path: "PrivacyPanelCapture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            let image = UIGraphicsImageRenderer(bounds: bar.bounds).image { _ in
                bar.drawHierarchy(in: bar.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: folder.appending(path: style == .light ? "privacy-light.png" : "privacy-dark.png"))
            let end = page.scrollView.contentSize.height+page.scrollView.adjustedContentInset.bottom-page.bounds.height
            page.scrollView.setContentOffset(CGPoint(x: 0, y: end), animated: false)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertLessThanOrEqual(page.scrollView.contentSize.height-page.scrollView.contentOffset.y,
                                     page.bounds.height-SummariseMotion.followUpFade.height,
                                     "At the end the entire document is above the fade")
            let bottom = UIGraphicsImageRenderer(bounds: bar.bounds).image { _ in
                bar.drawHierarchy(in: bar.bounds, afterScreenUpdates: true)
            }
            try bottom.pngData()?.write(to: folder.appending(path: style == .light ? "privacy-bottom-light.png" : "privacy-bottom-dark.png"))
            page.scrollView.setContentOffset(CGPoint(x: 0, y: -page.scrollView.adjustedContentInset.top), animated: false)
        }
        privacy.closeButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(bar.panel, .appSettings)
        XCTAssertTrue(bar.shown === bar.appSettings)
        XCTAssertNil(browser.presentedViewController)
        browser.showPrivacyPolicy()
        browser.handlePanelEdgeSwipe(.began)
        XCTAssertEqual(bar.panel, .appSettings, "The edge gesture and X take the same route back")
        browser.closePanel()
    }

    @MainActor func testCancelledVoiceHoldStopsRecordingAndWaveform() throws {
        guard #available(iOS 26, *), AVAudioApplication.shared.recordPermission == .granted,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw XCTSkip("Real microphone test requires permissions already granted on the test device")
        }
        let browser = BrowserViewController(startURL: nil)
        browser.loadViewIfNeeded()
        browser.startListening()
        defer { browser.cancelListening() }
        XCTAssertTrue(browser.voice.isRecording)
        XCTAssertTrue(browser.bottomBar.isListening)
        browser.cancelListening()
        XCTAssertFalse(browser.voice.isRecording)
        XCTAssertFalse(browser.bottomBar.isListening)
        browser.cancelListening()
        XCTAssertFalse(browser.voice.isRecording, "Cancelling twice remains safe")
    }
}

private final class ConsentGateProtocol: URLProtocol, @unchecked Sendable {
    static let requests = OSAllocatedUnfairLock(initialState: 0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

/// Transport fixtures explicitly opt in and restore every preference; production never bypasses consent.
@MainActor enum AIConsentTestScope {
    static func allowing<T>(_ operation: () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let keys = ["Rise.AI.Enabled"]+AIProvider.allCases.map { "Rise.AI.SharingConsent.\($0.rawValue)" }
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(true, forKey: "Rise.AI.Enabled")
        for provider in AIProvider.allCases { MobileAISettings.shared.allowSharing(with: provider) }
        return try await operation()
    }
}
