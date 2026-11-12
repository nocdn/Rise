import XCTest
@testable import RiseCore

final class PageAnnotationsTests: XCTestCase {
    func testNumberingDeletionAndCrossAnnotationHistoryRemainStable() throws {
        var document=AnnotationDocument()
        let one=try XCTUnwrap(document.add(AnnotationAnchor(exact:"first")))
        let two=try XCTUnwrap(document.add(AnnotationAnchor(exact:"second")))
        document.append(AnnotationExchange(annotationID:one.id,question:"Why?",answer:"Because."))
        document.append(AnnotationExchange(annotationID:two.id,question:"How does this relate to 1?",answer:"It follows."))
        document.remove(one.id)
        let three=try XCTUnwrap(document.add(AnnotationAnchor(exact:"third")))
        XCTAssertEqual(document.annotations.map(\.number),[2,3]);XCTAssertEqual(three.number,3)
        XCTAssertEqual(document.exchanges.map(\.annotationID),[two.id])
        document.append(AnnotationExchange(annotationID:one.id,question:"late",answer:"deleted"))
        XCTAssertEqual(document.exchanges.count,1)
    }
    @MainActor func testAtomicPersistenceAndPageKeys() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url=folder.appendingPathComponent("notes.json"),store=PageAnnotationStore(url:url)
        let key=try XCTUnwrap(PageAnnotationStore.key(for:URL(string:"https://example.com/article?q=1#section")))
        XCTAssertEqual(key,"https://example.com/article?q=1")
        XCTAssertNotEqual(PageAnnotationStore.key(for:URL(string:"https://example.com/#/one")),PageAnnotationStore.key(for:URL(string:"https://example.com/#/two")))
        XCTAssertNil(PageAnnotationStore.key(for:URL(string:"https://user:pass@example.com")))
        XCTAssertNil(PageAnnotationStore.key(for:URL(string:"rise://settings")))
        var document=AnnotationDocument();_=document.add(AnnotationAnchor(exact:"Saved quote",prefix:"before",suffix:"after",start:22))
        store.set(document,for:key)
        XCTAssertNil(store.saveError)
        XCTAssertEqual(PageAnnotationStore(url:url).document(for:key),document)
        store.set(AnnotationDocument(),for:key)
        XCTAssertTrue(PageAnnotationStore(url:url).document(for:key).annotations.isEmpty)
    }
    func testPayloadIsBoundedAndEmptySelectionsAreRejected() {
        var document=AnnotationDocument()
        XCTAssertNil(document.add(AnnotationAnchor(exact:"  \n")))
        let anchor=AnnotationAnchor(exact:String(repeating:"x",count:20_000),prefix:String(repeating:"y",count:100),suffix:String(repeating:"z",count:100),start:-3)
        XCTAssertEqual(anchor.exact.count,12_000);XCTAssertEqual(anchor.prefix.count,80);XCTAssertEqual(anchor.start,0)
        for _ in 0..<100 { XCTAssertNotNil(document.add(AnnotationAnchor(exact:"passage"))) }
        XCTAssertNil(document.add(AnnotationAnchor(exact:"too many")))
    }
}
