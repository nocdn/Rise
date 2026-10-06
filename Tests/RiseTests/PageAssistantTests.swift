import XCTest
import Foundation
@testable import Rise

final class PageAnswerStreamTests: XCTestCase {
    private func header(_ snippet: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["snippet": snippet]), as: UTF8.self)
    }
    func testEveryTokenBoundaryKeepsMetadataHiddenAndPreservesMarkdown() throws {
        let quote = "The \"release\" is March 3.\nZażółć 🥳 \\ path"
        let answer = "It ships **March 3**.\nAnother line."
        let text = try header(quote)+"\n"+answer
        for split in 0...text.count {
            var decoder = PageAnswerStream()
            let index = text.index(text.startIndex, offsetBy: split)
            let first = try decoder.append(String(text[..<index]))
            let second = try decoder.append(String(text[index...]))
            let last = try decoder.finish()
            XCTAssertEqual([first, second, last].compactMap(\.snippet), [quote])
            XCTAssertEqual(first.text+second.text+last.text, answer)
        }
        var decoder = PageAnswerStream(), snippets: [String] = [], streamed = ""
        for character in text {
            let output = try decoder.append(String(character))
            if let snippet = output.snippet { snippets.append(snippet) }
            streamed += output.text
        }
        XCTAssertEqual(snippets, [quote]); XCTAssertEqual(streamed, answer)
    }
    func testEmptySnippetAndLeadingWhitespaceDoNotHoldTheAnswer() throws {
        var decoder = PageAnswerStream()
        let output = try decoder.append(" \n\t{\"snippet\":\"\"}\r\nThe page does not say.")
        XCTAssertEqual(output.snippet, "")
        XCTAssertEqual(output.text, "The page does not say.")
        XCTAssertEqual(try decoder.append(" Next token.").text, " Next token.")
    }
    func testFencedMetadataAcrossEveryBoundaryDoesNotLeakIntoTheAnswer() throws {
        for newline in ["\n", "\r\n"] {
            let text = "```json"+newline+"{\"snippet\":\"March 3\"}"+newline+"```"+newline+"**March 3**."
            for split in 0...text.count {
                var decoder = PageAnswerStream()
                let index = text.index(text.startIndex, offsetBy: split)
                let first = try decoder.append(String(text[..<index]))
                let second = try decoder.append(String(text[index...]))
                let last = try decoder.finish()
                XCTAssertEqual([first, second, last].compactMap(\.snippet), ["March 3"])
                XCTAssertEqual(first.text+second.text+last.text, "**March 3**.")
            }
        }
    }
    func testClosingMetadataFenceAtEndOfStreamIsNotShownAsAnAnswer() throws {
        for ending in ["```", "```\n", "```\r\n"] {
            var decoder = PageAnswerStream()
            let header = try decoder.append("```json\n{\"snippet\":\"March 3\"}\n")
            let closing = try decoder.append(ending)
            let end = try decoder.finish()
            XCTAssertEqual(header.snippet, "March 3")
            XCTAssertEqual(header.text+closing.text+end.text, "")
        }
    }
    func testPlainAnswerWithoutHeaderStreamsImmediately() throws {
        var decoder = PageAnswerStream()
        XCTAssertEqual(try decoder.append("It ships").text, "It ships")
        XCTAssertEqual(try decoder.append(" tomorrow.").text, " tomorrow.")
        XCTAssertNil(try decoder.finish().snippet)
    }
    func testMalformedTruncatedAndOversizedHeadersFailWithoutDisplayingMetadata() {
        for text in ["{\"snippet\":7}\nAnswer", "{\"snippet\":\"unfinished", "{\"answer\":\"Wrong field\"}\n", "{"+String(repeating: "x", count: 16_384)] {
            var decoder = PageAnswerStream()
            XCTAssertThrowsError(try {
                let output = try decoder.append(text)
                XCTAssertEqual(output.text, "")
                _ = try decoder.finish()
            }())
        }
    }
}

/// Real URLSession streaming against a deterministic SSE response, with no network access.
private final class AssistantStreamProtocol: URLProtocol {
    static let lock = NSLock()
    static var response = Data()
    static var requests: [URLRequest] = []
    static func prepare(_ response: Data) {
        lock.lock(); defer { lock.unlock() }
        self.response = response; requests = []
    }
    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request); let data = Self.response
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class PageAssistantTests: XCTestCase {
    private func session(contents: [String]) throws -> URLSession {
        var stream = ": keep-alive\n\n"
        for content in contents {
            let chunk: [String: Any] = ["choices": [["delta": ["content": content]]]]
            stream += "data: "+String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)+"\n\n"
        }
        stream += "data: [DONE]\n\n"
        AssistantStreamProtocol.prepare(Data(stream.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantStreamProtocol.self]
        return URLSession(configuration: configuration)
    }
    func testOneRequestHighlightsBeforeAnswerEvenWhenThePassageCannotBeFound() async throws {
        for found in [true, false] {
            let session = try session(contents: ["{\"sn", "ippet\":\"March 3\"}", "\nIt ships ", "**March 3**."])
            defer { session.invalidateAndCancel() }
            var events: [String] = [], tokens: [String] = []
            let stream = PageAssistant.answer("When?", history: [], page: {
                PageAssistant.Page(title: "Release", url: "https://example.test", selection: "", text: "March 3")
            }, highlight: { snippet in events.append("highlight:"+snippet); return found }, session: session)
            for try await token in stream {
                tokens.append(token)
                if !token.isEmpty { events.append("answer:"+token) }
            }
            XCTAssertEqual(tokens.first, "")
            XCTAssertEqual(tokens.joined(), "It ships **March 3**.")
            XCTAssertEqual(events, ["highlight:March 3", "answer:It ships ", "answer:**March 3**."])
            XCTAssertEqual(AssistantStreamProtocol.recordedRequests().count, 1)
        }
    }
    func testCancellationAtHighlightDoesNotDeliverLateAnswerText() async throws {
        let session = try session(contents: ["{\"snippet\":\"March 3\"}\nLate answer"])
        defer { session.invalidateAndCancel() }
        var consumer: Task<[String], Never>!
        let stream = PageAssistant.answer("When?", history: [], page: {
            PageAssistant.Page(title: "Release", url: "https://example.test", selection: "", text: "March 3")
        }, highlight: { _ in consumer.cancel(); await Task.yield(); return true }, session: session)
        consumer = Task {
            var tokens: [String] = []
            do { for try await token in stream { tokens.append(token) } } catch {}
            return tokens
        }
        let tokens = await consumer.value
        XCTAssertTrue(tokens.allSatisfy(\.isEmpty))
        XCTAssertEqual(AssistantStreamProtocol.recordedRequests().count, 1)
    }
    func testNoSnippetStillDeliversAnswerWithoutAttemptingHighlight() async throws {
        for content in ["{\"snippet\":\"\"}\nThe page does not say.", "The page does not say."] {
            let session = try session(contents: [content])
            defer { session.invalidateAndCancel() }
            let stream = PageAssistant.answer("When?", history: [], page: {
                PageAssistant.Page(title: "Release", url: "https://example.test", selection: "", text: "No date yet")
            }, highlight: { _ in XCTFail("No snippet should be highlighted"); return false }, session: session)
            var text = ""
            for try await token in stream { text += token }
            XCTAssertEqual(text, "The page does not say.")
            XCTAssertEqual(AssistantStreamProtocol.recordedRequests().count, 1)
        }
    }
    func testMalformedHeaderFailsWithoutLeakingMetadataOrRetrying() async throws {
        let session = try session(contents: ["{\"snippet\":123}\nAnswer"])
        defer { session.invalidateAndCancel() }
        let stream = PageAssistant.answer("When?", history: [], page: {
            PageAssistant.Page(title: "Release", url: "https://example.test", selection: "", text: "March 3")
        }, highlight: { _ in XCTFail("Malformed metadata must not highlight"); return false }, session: session)
        var text = "", failed = false
        do { for try await token in stream { text += token } } catch { failed = true }
        XCTAssertTrue(failed); XCTAssertEqual(text, "")
        XCTAssertEqual(AssistantStreamProtocol.recordedRequests().count, 1)
    }
}
