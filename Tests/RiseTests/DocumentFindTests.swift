import XCTest
@testable import Rise

final class DocumentFindTests: XCTestCase {
    func testPagesReadInOrderUnderTheirNumbers() {
        let text = DocumentFinder.documentText(["The Riemann Hypothesis\r\nis the classic problem.\r\n", "  1\r\nIt is obvious to me.  "])
        XCTAssertEqual(text, "[Page 1 of 2]\nThe Riemann Hypothesis\nis the classic problem.\n\n[Page 2 of 2]\n1\nIt is obvious to me.")
    }
    func testControlCharactersPDFiumLeavesAreDropped() {
        // PDFium marks a hyphen it breaks a word at with a control character.
        XCTAssertEqual(DocumentFinder.documentText(["mathe\u{2}\r\nmaticians\tcount"]), "[Page 1 of 1]\nmathe\nmaticians\tcount")
    }
    func testAnEmptyDocumentStillSaysItsPages() {
        XCTAssertEqual(DocumentFinder.documentText([""]), "[Page 1 of 1]\n")
        XCTAssertEqual(DocumentFinder.documentText([]), "")
    }
    func testQuotesLoseThePageMarkersTheModelReadAndTheirLineBreaks() {
        XCTAssertEqual(DocumentFinder.passageWords("[Page 2 of 4]\nIt is obvious to me\n that I should"),
                       ["It", "is", "obvious", "to", "me", "that", "I", "should"])
        XCTAssertEqual(DocumentFinder.passageWords("  \n "), [])
    }
}
