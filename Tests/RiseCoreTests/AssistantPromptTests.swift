import XCTest
@testable import RiseCore

final class AssistantPromptTests: XCTestCase {
    func testOldPrefillLinksAndFrequentConversationsDoNotHideAsk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = BrowsingHistory(storageURL: folder.appendingPathComponent("history.json"))
        for (domain, path) in [("claude.ai", "/new?q=old"), ("chatgpt.com", "/c/frequent"), ("gemini.google.com", "/app/old")] {
            let url = URL(string: "https://\(domain)\(path)")!
            for _ in 0..<8 { history.recordTyped(url); history.record(url, title: "Old conversation") }
            for query in [String(domain.prefix(4)), domain] {
                let first = try XCTUnwrap(AddressSuggestionEngine.suggestions(for: query, history: history, tabs: []).first)
                XCTAssertEqual(first.url?.host, domain); XCTAssertEqual(first.url?.path, "")
                XCTAssertTrue(first.isAutofill)
                XCTAssertEqual(first.completion, PopularSites.completion(for: query)?.completed ?? query)
            }
        }
    }
    func testAllThreeAssistantsOfferAskAndOpenFreshChatsWithoutPuttingPromptsInURLs() throws {
        for service in ChatAssistant.allCases {
            let site = try XCTUnwrap(PopularSites.site(forAddress: service.domain))
            XCTAssertEqual(site.assistant, service); XCTAssertEqual(site.action, "Ask"); XCTAssertTrue(site.isSearchable)
            XCTAssertEqual(PopularSites.completion(for: String(service.domain.prefix(4)))?.site.assistant, service)
            XCTAssertTrue(service.isComposer(service.entryURL)); XCTAssertNil(service.entryURL.query)
            XCTAssertNil(service.entryURL.fragment)
        }
        XCTAssertEqual(PopularSites.site(forAddress: "github.com")?.action, "Search")
        XCTAssertEqual(PopularSite(name: "Custom", domain: "chatgpt.com", search: "https://chatgpt.com/?custom={q}", color: nil).action, "Search",
                       "A hand-set template keeps its own behavior")
        XCTAssertNil(PopularSites.site(forAddress: "claude.ai.evil.example"))
    }
    func testOnlyExactSecureOriginsAndNewChatRoutesCanReceiveAPrompt() {
        for service in ChatAssistant.allCases {
            for value in ["http://\(service.domain)/", "https://\(service.domain).evil.example/", "https://\(service.domain):8443/", "https://evil.example/\(service.domain)"] {
                XCTAssertFalse(service.isComposer(URL(string: value)!)); XCTAssertFalse(service.isConversation(URL(string: value)!))
            }
            XCTAssertFalse(service.isComposer(URL(string: "https://\(service.domain)/login")!))
        }
        XCTAssertTrue(ChatAssistant.gemini.isComposer(URL(string: "https://gemini.google.com/u/2/app")!))
        XCTAssertTrue(ChatAssistant.gemini.isConversation(URL(string: "https://gemini.google.com/u/2/app/12345")!))
        XCTAssertFalse(ChatAssistant.claude.isComposer(URL(string: "https://claude.ai/chat/existing")!))
        XCTAssertTrue(ChatAssistant.chatGPT.isConversation(URL(string: "https://chatgpt.com/c/123")!))
    }
    @MainActor func testNavigationAfterOneClickDoesNotSubmitAgain() async {
        let runner = AssistantPromptSubmission(), request = AssistantPrompt(service: .claude, text: "Say hello")
        var url = request.service.entryURL, calls = 0
        let done = expectation(description: "Submitted")
        runner.start(request, url: { url }, evaluate: { _, arguments in
            calls += 1
            XCTAssertEqual(arguments["prompt"] as? String, "Say hello")
            url = URL(string: "https://claude.ai/chat/new-conversation")!
            return "clicked"
        }, completion: { outcome in XCTAssertEqual(outcome, .submitted); done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testChromiumsInitialNewTabAddressDoesNotCancelThePendingPrompt() async {
        let runner = AssistantPromptSubmission(), request = AssistantPrompt(service: .chatGPT, text: "hello")
        var calls = 0, reads = 0
        let done = expectation(description: "Waited for the assistant document")
        runner.start(request, url: {
            reads += 1
            return reads == 1 ? URL(string: "chrome://newtab/")! : request.service.entryURL
        }, evaluate: { _, _ in calls += 1; return "submitted" }, completion: { outcome in
            XCTAssertEqual(outcome, .submitted); done.fulfill()
        })
        await fulfillment(of: [done], timeout: 2); XCTAssertEqual(calls, 1)
    }
    @MainActor func testAnExistingDraftStopsWithoutRetryingAndCancellationStopsPendingWork() async {
        let runner = AssistantPromptSubmission(), request = AssistantPrompt(service: .chatGPT, text: "Different prompt")
        var calls = 0
        let done = expectation(description: "Draft preserved")
        runner.start(request, url: { request.service.entryURL }, evaluate: { _, _ in calls += 1; return "draft" },
                     completion: { outcome in XCTAssertEqual(outcome, .draft); done.fulfill() })
        await fulfillment(of: [done], timeout: 2); XCTAssertEqual(calls, 1)
        runner.start(request, url: { request.service.entryURL }, evaluate: { _, _ in calls += 1; return "waiting" },
                     completion: { _ in XCTFail("A cancelled request must not finish or submit") })
        runner.cancel()
        await Task.yield(); XCTAssertEqual(calls, 1)
    }
}
