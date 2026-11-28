import AppKit
import XCTest
@testable import Rise

@MainActor final class LookUpPopoverTests: XCTestCase {
    /// The dictionary's part shows the headword in syllables, its pronunciation, class and labels
    /// apart from the sense.
    func testEntryKeepsWhatTheDictionaryShowsBeforeTheSense() {
        let whiteboard = AddressQuickAnswer.entry("whiteboard white·board | ˈ(h)wītˌbôrd | noun a wipeable board with a white surface used for teaching or presentations. • (also interactive whiteboard) an area on a display screen.")
        XCTAssertEqual(whiteboard, DictionaryEntry(headword: "white·board", pronunciation: "| ˈ(h)wītˌbôrd |", wordClass: "noun", labels: [],
                                                   sense: "a wipeable board with a white surface used for teaching or presentations"))
        let idempotent = AddressQuickAnswer.entry("idempotent | ˌīdəmˈpōtnt, ˌēdəmˈpōtnt | adjective Mathematics denoting an element of a set which is unchanged in value when multiplied or otherwise operated on by itself. DERIVATIVES idempotence noun.")
        XCTAssertEqual(idempotent?.headword, "idempotent")
        XCTAssertEqual(idempotent?.wordClass, "adjective")
        XCTAssertEqual(idempotent?.labels, ["Mathematics"])
        XCTAssertEqual(idempotent?.sense, "denoting an element of a set which is unchanged in value when multiplied or otherwise operated on by itself")
        XCTAssertEqual(idempotent?.answer, "Denoting an element of a set which is unchanged in value when multiplied or otherwise operated on by itself")
    }

    /// The quote is the word's clause: from its sentence's start, or cut with an ellipsis.
    func testQuoteIsTheWordsSentenceCutToALittleEitherSide() {
        let passage = LookUpPopover.Passage(
            before: "Each one trades developer experience, network efficiency, and tooling for the others. Picking the right one matters, but a good API is mostly about predictability, ",
            word: "idempotency",
            after: ", and clear errors, not which protocol you wrote on the whiteboard. Once clients depend on a field, removing it is a breaking change.")
        let quote = LookUpPopover.quote(passage)
        XCTAssertEqual(quote.before, "…but a good API is mostly about predictability, ")
        XCTAssertEqual(quote.after, ", and clear errors, not which protocol you…")
        let short = LookUpPopover.quote(.init(before: "Use ", word: "retries", after: " sparingly. Then more."))
        XCTAssertEqual(short.before, "Use ")
        XCTAssertEqual(short.after, " sparingly.")
    }

    func testMessagesGiveTheWordItsPassageAndTheDefinitionShown() {
        let entry = DictionaryEntry(headword: "idempotent", pronunciation: "| x |", wordClass: "adjective", labels: [], sense: "unchanged")
        let messages = LookUpPopover.messages(term: "idempotency", entry: entry, passage: "about predictability, idempotency, and clear errors",
                                              title: "Lesson", url: "https://devmaxx.dev", text: "Page text")
        let system = messages[0]["content"] as? String ?? "", user = messages[1]["content"] as? String ?? ""
        XCTAssertTrue(system.hasPrefix(LookUpPopover.systemPrompt))
        XCTAssertTrue(system.contains("<page>\nPage text\n</page>"))
        XCTAssertTrue(user.hasPrefix("Looked up: idempotency"))
        XCTAssertTrue(user.contains("The dictionary shows: adjective unchanged"))
        XCTAssertTrue(user.contains("<passage>\nabout predictability, idempotency, and clear errors\n</passage>"))
    }
}
