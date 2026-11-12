import XCTest
import RiseCore
@testable import Rise
final class AnnotationConversationTests: XCTestCase {
    func testWholePageAndPreviousAnnotationsShareAnIdenticalMessagePrefix() throws {
        let page=PageAssistant.Page(title:"Example",url:"https://example.com",selection:"varies",text:"The entire article, including text outside the selection.")
        var document=AnnotationDocument()
        let one=try XCTUnwrap(document.add(AnnotationAnchor(exact:"First passage")))
        let first=AnnotationConversation.messages(page:page,document:document,note:one,question:"Why?")
        let prompt=first.last?["content"] as? String
        document.append(AnnotationExchange(annotationID:one.id,question:"Why?",answer:"Explanation.",prompt:prompt))
        let two=try XCTUnwrap(document.add(AnnotationAnchor(exact:"Second passage")))
        let second=AnnotationConversation.messages(page:page,document:document,note:two,question:"How does this relate to annotation 1?")
        XCTAssertEqual(second[0]["content"] as? String,first[0]["content"] as? String)
        XCTAssertEqual(second[1]["content"] as? String,first[1]["content"] as? String)
        XCTAssertTrue((second[1]["content"] as? String ?? "").contains(page.text))
        XCTAssertEqual(second[2]["content"] as? String,prompt,"Replay the actual earlier prompt, including its then-current index, for prefix caching")
        XCTAssertTrue((second[3]["content"] as? String ?? "").contains("Explanation."))
        XCTAssertTrue((second.last?["content"] as? String ?? "").contains("Annotation 1: First passage"))
        XCTAssertTrue((second.last?["content"] as? String ?? "").contains("Annotation 2: Second passage"))
        document.remove(one.id)
        let afterRemoval=AnnotationConversation.messages(page:page,document:document,note:two,question:"Explain")
        XCTAssertFalse(afterRemoval.contains { ($0["content"] as? String ?? "").contains("Explanation.") })
    }
    @MainActor func testAnnotationCardKeepsAskModeAndRestoresItsAnswer() {
        let bar=FindBar()
        bar.presentAnnotation(number:2,draft:"What does this mean?",turns:[.init(question:"What does this mean?",answer:"An explanation.")])
        XCTAssertEqual(bar.mode,.ask);XCTAssertEqual(bar.conversation.count,1)
        bar.toggleMode();XCTAssertEqual(bar.mode,.ask,"Tab must not turn an annotation into Find")
        var closed=false;bar.dismiss={ closed=true };bar.handleEscape();XCTAssertTrue(closed)
        bar.discard()
    }
}
