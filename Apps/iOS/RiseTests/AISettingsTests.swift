import XCTest
import UIKit
@testable import RiseiOS

final class AISettingsTests: XCTestCase {
    @MainActor func testSeparateKeysSurviveProviderSwitchAndRelaunch() throws {
        let name = "Rise.AI.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = MobileAIKeyStore(service: name)
        defer {
            defaults.removePersistentDomain(forName: name)
            for provider in AIProvider.allCases { try? store.set("", for: provider) }
        }
        let settings = MobileAISettings(defaults: defaults, credentials: store)
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.provider, .openRouter)
        try settings.setKey(" router-test-key ", for: .openRouter)
        settings.provider = .openAI
        XCTAssertEqual(settings.modelChoice.apiKey, "")
        try settings.setKey("openai-test-key", for: .openAI)
        settings.enabled = false
        let reopened = MobileAISettings(defaults: defaults, credentials: MobileAIKeyStore(service: name))
        XCTAssertFalse(reopened.enabled)
        XCTAssertEqual(reopened.provider, .openAI)
        XCTAssertEqual(reopened.key(for: .openAI), "openai-test-key")
        reopened.provider = .openRouter
        XCTAssertEqual(reopened.modelChoice.apiKey, "router-test-key")
        XCTAssertEqual(reopened.modelChoice.model, "openai/gpt-6-luna")
        XCTAssertEqual(reopened.modelChoice.effort, "low")
        try reopened.setKey("", for: .openAI)
        XCTAssertEqual(reopened.key(for: .openAI), "")
        XCTAssertEqual(reopened.key(for: .openRouter), "router-test-key")
        XCTAssertNil(defaults.object(forKey: "router-test-key"))
    }

    @MainActor func testSettingsRowsAndSecureInput() async throws {
        let name = "Rise.AI.UI.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MobileAISettings(defaults: defaults, credentials: MobileAIKeyStore(service: name))
        try settings.setKey(String(repeating: "x", count: 200), for: .openRouter)
        defer { try? settings.setKey("", for: .openRouter) }
        let group = AISettingsGroup(settings: settings)
        group.frame = CGRect(x: 0, y: 0, width: 361, height: group.height(for: 361))
        group.layoutIfNeeded()
        XCTAssertEqual(group.rowsHeight, SiteSettingsPanel.rowHeight*3)
        XCTAssertEqual(group.detail.numberOfLines, 3)
        let subtitle = group.detail.sizeThatFits(CGSize(width: 329, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertLessThanOrEqual(subtitle.height, ceil(group.detail.font.lineHeight*3))
        XCTAssertTrue(group.keyField.isSecureTextEntry)
        let dots = try XCTUnwrap(group.keyField.superview?.subviews.compactMap { $0 as? UILabel }
            .first { $0.text == String(repeating: "•", count: 200) })
        XCTAssertEqual(dots.lineBreakMode, .byClipping, "Overflow contains masking dots, never an ellipsis")
        XCTAssertNotNil(dots.layer.mask)
        XCTAssertEqual(group.keyField.autocorrectionType, .no)
        XCTAssertGreaterThan(group.keyField.frame.width, 44)
        XCTAssertEqual(group.keyField.frame.width, group.providerButton.frame.width-8, accuracy: 0.5)
        XCTAssertTrue(group.bounds.contains(group.keyField.convert(group.keyField.bounds, to: group)))
        let menu = try XCTUnwrap(group.providerButton.menu)
        XCTAssertEqual(menu.children.map(\.title), ["OpenRouter", "OpenAI"])
        XCTAssertTrue(menu.children.allSatisfy { $0.image == nil })
        XCTAssertTrue(group.keyMenuButton.showsMenuAsPrimaryAction)
        let check = try XCTUnwrap(group.keyMenuButton.menu?.children.first as? UIAction)
        XCTAssertTrue(check.attributes.contains(.keepsMenuPresented))
        XCTAssertFalse(check.attributes.contains(.disabled), "A saved key can be checked")
        settings.enabled = false
        group.refresh()
        XCTAssertEqual(group.rowsHeight, SiteSettingsPanel.rowHeight)
        XCTAssertFalse(group.enabledRow.toggle.isOn)
        let path = URL.temporaryDirectory.appendingPathComponent("rise-ai-settings-tests")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let panel = AppSettingsPanel(frame: CGRect(x: 0, y: 0, width: 393, height: AppSettingsPanel.height))
        panel.showSync(enabled: true, message: "Tabs sync automatically through your iCloud account.")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        host.view.backgroundColor = .systemBackground
        host.view.addSubview(panel)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(100))
            panel.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: panel.bounds).image { _ in panel.drawHierarchy(in: panel.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: path.appendingPathComponent(style == .light ? "light.png" : "dark.png"))
        }
    }

    func testValidationDistinguishesInvalidKeyFromServiceFailure() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIValidationProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let empty = await AIKeyValidator.check("", provider: .openRouter, session: session)
        XCTAssertEqual(empty, .invalid)
        for (key, provider, expected) in [
            ("valid-router", AIProvider.openRouter, AIKeyValidation.valid),
            ("valid-openai", .openAI, .valid),
            ("invalid", .openRouter, .invalid),
            ("outage", .openAI, .unavailable),
            ("restricted", .openAI, .unavailable),
        ] {
            let result = await AIKeyValidator.check(key, provider: provider, session: session)
            XCTAssertEqual(result, expected)
        }
    }

    @MainActor func testKeyRevealsWhileEditingAndRemasksWithoutLosingText() throws {
        let name = "Rise.AI.Editing.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = MobileAISettings(defaults: defaults, credentials: MobileAIKeyStore(service: name))
        let original = String(repeating: "fixture-", count: 20)
        try settings.setKey(original, for: .openRouter)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        let group = AISettingsGroup(settings: settings)
        group.frame = CGRect(x: 16, y: 80, width: 361, height: group.height(for: 361))
        host.view.addSubview(group)
        window.makeKeyAndVisible()
        defer {
            group.keyField.resignFirstResponder()
            window.isHidden = true
            try? settings.setKey("", for: .openRouter)
            defaults.removePersistentDomain(forName: name)
        }
        group.layoutIfNeeded()
        XCTAssertTrue(group.keyField.becomeFirstResponder())
        group.layoutIfNeeded()
        XCTAssertFalse(group.keyField.isSecureTextEntry)
        XCTAssertEqual(group.keyField.text, original)
        XCTAssertTrue(group.keyField.font!.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertNotNil(group.keyField.layer.mask, "The revealed overflowing key keeps its right-edge fade")
        group.keyField.selectedTextRange = group.keyField.textRange(from: group.keyField.endOfDocument, to: group.keyField.endOfDocument)
        group.keyField.insertText("x")
        XCTAssertEqual(group.keyField.text, original+"x")
        XCTAssertTrue(group.keyField.resignFirstResponder())
        group.layoutIfNeeded()
        XCTAssertTrue(group.keyField.isSecureTextEntry)
        XCTAssertEqual(group.keyField.text, original+"x")
        XCTAssertEqual(settings.key(for: .openRouter), original+"x")
        XCTAssertNil(group.keyField.layer.mask, "Resting dots own the mask after editing ends")
    }

    @MainActor func testMobileNeverFallsBackToEmbeddedCredential() async throws {
        do {
            try await ModelService.run([], provider: .openRouter) { _ in XCTFail("No model event without a key") }
            XCTFail("A missing key must fail before networking")
        } catch { XCTAssertTrue(error.localizedDescription.contains("API key")) }
    }

    @MainActor func testSummaryUsesEachProvidersConfiguredKeyAndStreamingTransport() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIReplyProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for provider in AIProvider.allCases {
            let choice = ModelChoice(provider: provider, model: provider.defaultModel, effort: "low", apiKey: "fixture-\(provider.rawValue)")
            let page = PageAssistant.Page(title: "Test", url: "https://example.test", selection: "", text: "A page")
            let summary = try await AIConsentTestScope.allowing {
                try await PageSummary.make(of: page, provider: choice, session: session)
            }
            XCTAssertEqual(summary.paragraphs, ["First paragraph.", "Second paragraph."])
        }
    }
}

private final class AIReplyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let router = request.url?.host == "openrouter.ai"
        let expectedKey = router ? "fixture-openRouter" : "fixture-openAI"
        let expectedPath = router ? "/api/v1/chat/completions" : "/v1/responses"
        guard request.httpMethod == "POST", request.url?.path == expectedPath,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expectedKey)" else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return
        }
        let text = "First paragraph.\n\nSecond paragraph."
        let event: [String: Any] = router ? ["choices": [["delta": ["content": text]]]]
            : ["type": "response.output_text.delta", "delta": text]
        let data = try! JSONSerialization.data(withJSONObject: event)
        let sse = "data: \(String(decoding: data, as: UTF8.self))\n\n" + (router ? "data: [DONE]\n\n" : "data: {\"type\":\"response.completed\"}\n\n")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class AIValidationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let status = key.contains("invalid") ? 401 : key.contains("outage") ? 503 : key.contains("restricted") ? 403 : 200
        let router = request.url?.host == "openrouter.ai"
        let expected = router ? "/api/v1/key" : "/v1/models"
        guard request.url?.path == expected, request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((router ? "{\"data\":{\"label\":\"test\"}}" : "{\"data\":[]}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
