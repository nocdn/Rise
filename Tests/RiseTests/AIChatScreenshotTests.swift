import XCTest
import AppKit
@testable import Rise

@MainActor final class AIChatScreenshotTests: XCTestCase {
    private func sse(_ events: [[String: Any]]) -> String {
        events.map { "data: \(String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!)\n\n" }.joined()+"data: [DONE]\n\n"
    }
    private func jpeg(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .jpeg, properties: [:])!
    }

    func testItTakesWhatShowsOrTheScreenfulAskedFor() {
        let metrics = PageLayoutMetrics(scrollY: 1000, viewportWidth: 1280, viewportHeight: 900, contentWidth: 1280, contentHeight: 4000)
        let now = AIChatScreenshot.clip(metrics, screen: nil)
        XCTAssertEqual(now.clip, CGRect(x: 0, y: 1000, width: 1280, height: 900))
        XCTAssertEqual(now.screens, 5); XCTAssertEqual(now.screen, 2)
        XCTAssertFalse(now.beyondViewport, "What shows is taken as it is")
        let second = AIChatScreenshot.clip(metrics, screen: 2)
        XCTAssertEqual(second.clip.minY, 900); XCTAssertTrue(second.beyondViewport)
        let last = AIChatScreenshot.clip(metrics, screen: 99)
        XCTAssertEqual(last.screen, 5); XCTAssertEqual(last.clip, CGRect(x: 0, y: 3600, width: 1280, height: 400))
        let short = AIChatScreenshot.clip(PageLayoutMetrics(scrollY: 0, viewportWidth: 1000, viewportHeight: 800, contentWidth: 1000, contentHeight: 300), screen: nil)
        XCTAssertEqual(short.screens, 1); XCTAssertEqual(short.clip, CGRect(x: 0, y: 0, width: 1000, height: 800))
        // Exactly two screens tall is two, not three.
        XCTAssertEqual(AIChatScreenshot.clip(PageLayoutMetrics(scrollY: 0, viewportWidth: 1000, viewportHeight: 800, contentWidth: 1000, contentHeight: 1600), screen: 1).screens, 2)
    }

    func testAPictureWiderThanTheModelNeedsIsShrunk() throws {
        let big = try XCTUnwrap(AIChatScreenshot.fit(jpeg(width: 2560, height: 1800)))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: big))
        XCTAssertEqual(rep.pixelsWide, 1280); XCTAssertEqual(rep.pixelsHigh, 900)
        let small = jpeg(width: 800, height: 600)
        XCTAssertEqual(AIChatScreenshot.fit(small), small, "Left as it is")
    }

    func testTheModelSeesTheScreenshotAfterTheToolsResultOrIsToldItCantWhereItTakesNoImages() async throws {
        let call = sse([["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "type": "function", "function": ["name": "view_page", "arguments": "{\"tab\":\"3f9a\"}"]]]]]]]])
        let done = sse([["choices": [["delta": ["content": "A bar chart."], "finish_reason": "stop"]]]])
        let picture = jpeg(width: 40, height: 30)
        let tool = AIChatTool(name: "view_page", description: "Looks.", parameters: ["type": "object"], step: { _ in AIChatStep(text: "Looking") },
                              run: { _, step in AIChatToolResult(output: "Screenshot of Stats.", step: step.done(), images: [AIChatImage(jpeg: picture, caption: "Screenshot of Stats.")]) })

        func run(_ replies: [String]) async throws -> [[String: Any]] {
            let session = AIChatStreamProtocol.session(replies)
            let model = AIChatCompletionsModel(endpoint: URL(string: "https://openrouter.test/chat")!, key: "k", model: "m", effort: "low",
                                               messages: [["role": "user", "content": "What's the chart?"]], session: session)
            try await AIChatAgent.run(model, tools: [tool]) { _ in }
            return try XCTUnwrap(AIChatStreamProtocol.bodies.last?["messages"] as? [[String: Any]])
        }
        let sent = try await run([call, done])
        XCTAssertEqual(sent.map { $0["role"] as? String }, ["user", "assistant", "tool", "user"])
        let parts = try XCTUnwrap(sent[3]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "Screenshot of Stats.")
        XCTAssertEqual((parts[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/jpeg;base64,\(picture.base64EncodedString())")

        // A model without pictures turns the request down; it's asked again, told why.
        let refused = "HTTP 404\n{\"error\":{\"message\":\"No endpoints found that support image input\"}}"
        let retried = try await run([call, refused, done])
        XCTAssertEqual(AIChatStreamProtocol.bodies.count, 3)
        let again = try XCTUnwrap(retried[3]["content"] as? [[String: Any]])
        XCTAssertFalse(again.contains { $0["type"] as? String == "image_url" })
        XCTAssertTrue(again.contains { $0["text"] as? String == AIChatImage.refused })
    }

    func testResponsesTakesThePictureAsAnInputImage() async throws {
        let session = AIChatStreamProtocol.session([sse([["type": "response.output_text.delta", "delta": "Ok"], ["type": "response.completed", "response": ["output": []]]])])
        let model = AIChatResponsesModel(key: "k", model: "gpt", effort: "low", input: [["role": "user", "content": "Look"]], session: session)
        model.append(images: [AIChatImage(jpeg: Data([1, 2, 3]), caption: "Screen 1 of 2.")])
        _ = try await model.reply(tools: [], mayCall: false) { _ in }
        let input = try XCTUnwrap(AIChatStreamProtocol.bodies.last?["input"] as? [[String: Any]])
        let parts = try XCTUnwrap(input.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["input_text", "input_image"])
        XCTAssertEqual(parts[1]["image_url"] as? String, "data:image/jpeg;base64,AQID")
    }

    func testViewPageIsOfferedAndAsksForATabOrAnAddress() async throws {
        let tools = AIChatBrowserTools(browser: BrowserController())
        XCTAssertTrue(tools.tools.contains { $0.name == "view_page" })
        let tool = tools.viewPage
        do { _ = try await tool.run([:], tool.step([:])); XCTFail("Nothing to look at") }
        catch let failure as AIChatToolFailure { XCTAssertTrue(failure.message.contains("tab's id")) }
    }
}
