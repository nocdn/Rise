import AppKit
import XCTest
@testable import Rise

final class AddressQuickAnswerTests: XCTestCase {
    func testRecognizesOnlyExplicitLookupsAndExtractsTheFirstDefinition() {
        XCTAssertEqual(AddressQuickAnswer("  innocuous  meaning"), .definition("innocuous"))
        XCTAssertEqual(AddressQuickAnswer("Define ad hoc"), .definition("ad hoc"))
        XCTAssertEqual(AddressQuickAnswer("Definition of innocuous"), .definition("innocuous"))
        XCTAssertEqual(AddressQuickAnswer("innocuous meaning in English"), .definition("innocuous"))
        XCTAssertEqual(AddressQuickAnswer("innocuous synonym"), .synonyms("innocuous"))
        XCTAssertEqual(AddressQuickAnswer("Synonyms for innocuous?"), .synonyms("innocuous"))
        XCTAssertEqual(AddressQuickAnswer("How old is Taylor Swift?"), .age("taylor swift"))
        XCTAssertEqual(AddressQuickAnswer("Taylor Swift’s age"), .age("taylor swift"))
        XCTAssertNil(AddressQuickAnswer("innocuous"))
        XCTAssertNil(AddressQuickAnswer("https://example.com meaning"))
        XCTAssertEqual(AddressQuickAnswer.definitionText("innocuous in·noc·u·ous | iˈnäkyəwəs | adjective not harmful or offensive: it was an innocuous question."), "Not harmful or offensive")
        XCTAssertNil(AddressQuickAnswer.definitionText("No recognizable dictionary entry"))
    }

    /// Entries as Dictionary Services gives them, with what comes between the pronunciation and
    /// the sense: phrases, forms whose brackets hold bars and brackets, classes with qualifiers,
    /// labels and subjects.
    func testDefinitionsReadPastWhatComesBeforeTheSense() {
        let entries: [(String, String, String?)] = [
            ("acquainted", "acquaint ac·quaint | əˈkwānt | (acquaint someone with) verb [with object] make someone aware of or familiar with: new staff should be acquainted with fire exit routes. • (be acquainted) be an acquaintance",
             "Make someone aware of or familiar with"),
            ("children", "child | CHīld | noun (plural children | ˈCHildr(ə)n |) a young human being below the age of puberty or below the legal age of majority: she'd been playing tennis since she was a child",
             "A young human being below the age of puberty or below the legal age of majority"),
            ("mice", "mouse noun (plural mice | mīs |) | mous | 1 a small rodent that typically has a pointed snout, relatively large ears and eyes, and a long tail. Family Muridae: many genera",
             "A small rodent that typically has a pointed snout, relatively large ears and eyes, and a long tail"),
            ("have", "have | hav, (h)əv, (ə)v | verb (has | haz, (ə)z |) (, having | ˈhaviNG |) (, had | had, (h)əd |) [with object] 1 (also have got) possess, own, or hold: he had a new car",
             "Possess, own, or hold"),
            ("which", "which | (h)wiCH | interrogative pronoun, determiner asking for information specifying one or more people or things from a definite set: [as pronoun] : which are the best",
             "Asking for information specifying one or more people or things from a definite set"),
            ("wow", "wow 1 | wou | informal exclamation (wowee | wouˈwēː | | wouˈwēː |) expressing astonishment or admiration: “Wow!” he cried",
             "Expressing astonishment or admiration"),
            ("alas", "alas a·las | əˈlas | exclamation archaic, or literary an expression of grief, pity, or concern: alas, my funds",
             "An expression of grief, pity, or concern"),
            ("goodbye", "goodbye good·bye | ˌɡo͝odˈbī | (also goodby or good-by) exclamation used to express good wishes when parting or at the end of a conversation. noun (plural goodbyes | ɡo͝odˈbīz |) an instance",
             "Used to express good wishes when parting or at the end of a conversation"),
            ("mitochondria", "mitochondrion mi·to·chon·dri·on | ˌmīdəˈkändrēən | noun (plural mitochondria | ˌmīdəˈkändrēə |) Biology an organelle found in large numbers in most cells, in which the biochemical processes of respiration and energy production occur. It has a double membrane",
             "An organelle found in large numbers in most cells, in which the biochemical processes of respiration and energy production occur"),
            ("compliment", "compliment com·pli·mentnoun | ˈkämpləmənt | a polite expression of praise or admiration: she paid me an enormous compliment",
             "A polite expression of praise or admiration"),
            ("went", "go 1 | ɡō | verb (goes | ɡōz |) (, going | ˈɡōiNG |) (past; went | went |) (past participle; gone | ɡôn, ɡän |) [no object] 1 move from one place to another; travel: he went out to the shops",
             "Move from one place to another; travel"),
            ("NASA", "NASA | ˈnasə | abbreviation National Aeronautics and Space Administration.", "National Aeronautics and Space Administration"),
            // Another word's entry: "unicolor" lists "-colour" as a part of itself.
            ("colour", "unicolor u·ni·col·or | ˈyo͞onəˌkələr | (unicolored) (British English -colour) (British English -coloured) adjective of one color.", nil)
        ]
        for (term, entry, expected) in entries {
            XCTAssertEqual(AddressQuickAnswer.definitionText(entry, for: term), expected, term)
        }
    }

    @MainActor func testSynonymsUseTheBundledIndexAndShowImmediatelyOnFocus() throws {
        _ = NSApplication.shared
        let preview = AddressAnswerPreview()
        let row = NSButton()
        preview.focus(AddressQuickAnswer("innocuous synonym"), row: row, theme: .neutral)
        let answer = try XCTUnwrap(row.accessibilityValue() as? String)
        XCTAssertTrue(answer.components(separatedBy: ", ").contains("harmless"))
        XCTAssertFalse(preview.isHidden)
        let spinner = try XCTUnwrap(preview.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        XCTAssertEqual(spinner.alphaValue, 0)
        preview.focus(AddressQuickAnswer("zzwordthatdoesnotexist synonyms"), row: row, theme: .neutral)
        XCTAssertTrue(preview.isHidden)
        XCTAssertNil(row.accessibilityValue())
    }

    func testAgeRequiresOneLivingPersonWithAnUnambiguousSourcedBirthDate() throws {
        let birth: [String: Any] = [
            "rank": "normal", "references": [["hash": "source"]],
            "mainsnak": ["datavalue": ["value": [
                "time": "+1989-12-13T00:00:00Z", "precision": 11,
                "calendarmodel": "http://www.wikidata.org/entity/Q1985727"
            ]]]
        ]
        let human = ["mainsnak": ["datavalue": ["value": ["id": "Q5"]]]]
        func entity(_ claims: [String: Any]) -> [String: Any] {
            ["sitelinks": ["enwiki": ["title": "Example person"]], "claims": claims]
        }
        func answer(_ entities: [String: Any], on day: Int = 12) throws -> String? {
            let today = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 12, day: day)))
            let data = try JSONSerialization.data(withJSONObject: ["entities": entities])
            return try AddressQuickAnswer.ageAnswer(in: data, today: today)
        }
        let person = entity(["P31": [human], "P569": [birth]])
        XCTAssertEqual(try answer(["Q1": person, "Q2": entity([:])]), "36 years old")
        XCTAssertEqual(try answer(["Q1": person], on: 13), "37 years old")
        XCTAssertNil(try answer(["Q1": person, "Q2": person]))
        XCTAssertNil(try answer(["Q1": entity(["P31": [human], "P569": [birth], "P570": [["rank": "normal"]]])]))
        var unsourced = birth
        unsourced.removeValue(forKey: "references")
        XCTAssertNil(try answer(["Q1": entity(["P31": [human], "P569": [unsourced]])]))
    }

    @MainActor func testPreviewOnlyAppliesAnswersToTheCurrentRow() async throws {
        _ = NSApplication.shared
        var requested: [String] = []
        let preview = AddressAnswerPreview(fetchAge: { name in
            requested.append(name)
            try? await Task.sleep(for: .seconds(10))
            return "Outdated answer"
        }, define: { _ in "Not harmful or offensive" })
        let first = NSButton(), second = NSButton()
        let spinner = try XCTUnwrap(preview.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        preview.focus(.age("example person"), row: first, theme: .neutral)
        for _ in 0..<100 where requested.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requested, ["example person"])
        XCTAssertEqual(spinner.alphaValue, 1)
        preview.focus(.definition("innocuous"), row: second, theme: .neutral)
        XCTAssertEqual(second.accessibilityValue() as? String, "Not harmful or offensive", "Definitions are synchronous")
        XCTAssertEqual(preview.hoverHint?.text, "Source: Dictionary")
        XCTAssertEqual(spinner.alphaValue, 0)
        await Task.yield()
        XCTAssertNil(first.accessibilityValue())
        XCTAssertEqual(second.accessibilityValue() as? String, "Not harmful or offensive")
        XCTAssertTrue(preview.superview === second)
    }

    @MainActor func testAgeSwapsTheSpinnerForTheAnswerWithTheURLBarAnimation() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let row = NSButton(frame: NSRect(x: 0, y: 0, width: 380, height: 40))
        window.contentView?.addSubview(row)
        let preview = AddressAnswerPreview(fetchAge: { _ in "36 years old" })
        preview.focus(.age("example person"), row: row, theme: .neutral)
        for _ in 0..<100 where row.accessibilityValue() == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(row.accessibilityValue() as? String, "36 years old")
        let label = try XCTUnwrap(preview.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.stringValue, "36 years old")
        preview.frame = NSRect(x: 0, y: 0, width: 280, height: 40)
        preview.layoutSubtreeIfNeeded()
        XCTAssertEqual(label.frame.width, preview.bounds.width)
        // Hovering the answer's words, not the row's end, names its source in the hover popover.
        XCTAssertNil(label.toolTip)
        XCTAssertEqual(preview.hoverHint?.text, "Source: Wikidata")
        XCTAssertEqual(preview.hintRect.width, label.intrinsicContentSize.width)
        let animation = try XCTUnwrap(label.layer?.animation(forKey: "notice") as? CAAnimationGroup)
        XCTAssertEqual(animation.duration, PlainNavBar.Notice.entryDuration)
        preview.focus(nil, row: nil, theme: .neutral)
        XCTAssertNil(label.layer?.animation(forKey: "notice"))
    }
}
