import XCTest
@testable import RiseCore

final class SelectionBase64Tests: XCTestCase {
    func testStandardURLSafeUnpaddedAndWrappedTextDecode() {
        for (encoded, value) in [("Zg==", "f"), ("Zm8=", "fo"), ("Zm9v", "foo"), ("Zg", "f"), ("Zm8", "fo"),
                                 ("  SGVs\r\nbG8gd29ybGQ=\t", "Hello world"), ("8J-YgA", "😀"), ("8J+YgA==", "😀")] {
            XCTAssertEqual(SelectionBase64.decode(encoded)?.value, value, encoded)
        }
    }

    func testEncodingPreservesUnicodeWhitespaceAndEmptyLookingTextExactly() {
        for value in ["hello", "  hello\n\t", "\r\n", " ", "café 東京", "👨‍👩‍👧‍👦", "https://example.com/a?b=1&c=2"] {
            let encoded = SelectionBase64.encode(value)
            XCTAssertEqual(encoded, Data(value.utf8).base64EncodedString())
            XCTAssertEqual(encoded.flatMap(SelectionBase64.decode)?.value, value)
        }
    }

    func testMalformedPaddingAlphabetAndNonCanonicalBitsAreRejected() {
        for value in ["", "   ", "A", "A===", "====", "Zg=", "Zg===", "Z=g=", "Zm9v=", "Zh==", "Zm9=", "Zg==more", "SGVsbG8!", "8J+YgA__", "Zg\u{00A0}=="] {
            XCTAssertNil(SelectionBase64.decode(value), value)
        }
    }

    func testBinaryInvalidUTF8AndControlPayloadsAreNotShownAsText() {
        for bytes: [UInt8] in [[0], [0xff, 0xfe], [0x41, 0x1b, 0x42], [0x7f], [0xc2, 0x85]] {
            XCTAssertNil(SelectionBase64.decode(Data(bytes).base64EncodedString()))
        }
    }

    func testLongPreviewIsBoundedButCopyValueIsComplete() throws {
        let value = String(repeating: "🌍 hello\n", count: 200)
        let decoded = try XCTUnwrap(SelectionBase64.decode(try XCTUnwrap(SelectionBase64.encode(value))))
        XCTAssertEqual(decoded.value, value)
        XCTAssertLessThanOrEqual(decoded.preview.count, 81)
        XCTAssertTrue(decoded.preview.hasSuffix("…"))
        XCTAssertFalse(decoded.preview.contains("\n"))
        XCTAssertEqual(SelectionBase64.decode("IA==")?.preview, "␠")
    }

    func testLimitsApplyBeforeExpensiveWorkAndNoSelectionHasNoAction() {
        XCTAssertNil(SelectionBase64.encode(""))
        XCTAssertNil(SelectionBase64.encode(String(repeating: "x", count: SelectionBase64.maximumBytes+1)))
        XCTAssertNil(SelectionBase64.decode(String(repeating: "A", count: SelectionBase64.maximumBytes+1)))
        let boundary = String(repeating: "x", count: SelectionBase64.maximumBytes)
        XCTAssertNotNil(SelectionBase64.encode(boundary))
    }
}
