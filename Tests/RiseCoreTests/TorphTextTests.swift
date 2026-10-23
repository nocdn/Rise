import XCTest
@testable import RiseCore

final class TorphTextTests: XCTestCase {
    private func rendered(_ segments: [TorphText.Segment]) -> String { segments.map(\.text).joined().replacingOccurrences(of: "\u{a0}",with: " ") }
    private func verify(_ segments: [TorphText.Segment],_ text: String,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertEqual(rendered(segments),text.replacingOccurrences(of: "\u{a0}",with: " "),file: file,line: line)
        XCTAssertEqual(Set(segments.map(\.id)).count,segments.count,"IDs collide: \(text)",file: file,line: line)
    }
    func testUpstreamCorpusAcrossRepeatedForwardAndReverseCycles() throws {
        struct Case: Decodable { let label: String; let values: [String] }
        let url = Bundle.module.url(forResource: "TorphCorpus",withExtension: "json",subdirectory: "Resources")!
        let corpus = try JSONDecoder().decode([Case].self,from: Data(contentsOf: url))
        XCTAssertEqual(corpus.count,50)
        for item in corpus {
            var current: [TorphText.Segment] = []
            for value in item.values+item.values.reversed()+item.values {
                current = current.isEmpty ? TorphText.segment(value) : TorphText.diff(current,to: value).segments
                verify(current,value)
            }
        }
    }
    func testStableWordsReorderingAndEarliestRepeatedMatch() {
        let old = TorphText.segment("hello world")
        let new = TorphText.diff(old,to: "world hello").segments
        for word in ["hello","world"] { XCTAssertEqual(old.first { $0.text == word }?.id,new.first { $0.text == word }?.id) }
        let repeated = TorphText.diff(old,to: "hello there hello").segments.filter { $0.text == "hello" }
        XCTAssertEqual(repeated.count,2); XCTAssertEqual(repeated[0].id,old[0].id); XCTAssertNotEqual(repeated[0].id,repeated[1].id)
    }
    func testSimilarWordsSplitButDoNotCrossASurvivingAnchor() {
        let original = TorphText.segment("npm i torph")
        let next = TorphText.diff(original,to: "pnpm add torph")
        XCTAssertEqual(next.splits["npm"]?.map(\.text),["n","p","m"])
        XCTAssertTrue(next.segments.contains { $0.id == "npm:0" && $0.text == "n" })
        XCTAssertTrue(next.segments.contains { $0.id == "torph" && $0.text == "torph" })
        let unrelated = TorphText.diff(TorphText.segment("cat and dog"),to: "fish and bird")
        XCTAssertTrue(unrelated.splits.isEmpty)
    }
    func testToastPunctuationDoesNotTreatWholeWordsAsSingleCharacters() {
        let old = TorphText.segment("Starring repository...")
        let next = TorphText.diff(old,to: "Starred repository")
        verify(next.segments,"Starred repository")
        XCTAssertEqual(next.splits["repository"]?.map(\.text).joined(),"repository")
        let surviving = Set(next.segments.map(\.id))
        XCTAssertTrue(next.splits["repository"]!.allSatisfy { surviving.contains($0.id) })
        XCTAssertEqual(next.segments.filter { $0.id.hasPrefix("repository:") }.map(\.text).joined(),"repository")
    }
    func testWhitespaceEmptyAndUnicodeClustersStayIntact() {
        let values = [""," ","   ","\n\nhello  world\n","hello world\n\n","café 👩🏽‍💻 ready","cafe\u{301} 👨‍👩‍👧‍👦 ready","👍🏽 ready","你好 世界","مرحبا بالعالم","abc-0 abc abc:0"]
        var old: [TorphText.Segment] = []
        for _ in 0..<5 { for value in values { old = TorphText.diff(old,to: value).segments; verify(old,value) } }
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(TorphText.segment(family).count,1)
        let changed = TorphText.diff(TorphText.segment("abc\(family) word"),to: "abcd\(family) word")
        XCTAssertTrue(changed.segments.contains { $0.text == family })
        XCTAssertFalse(changed.segments.contains { $0.text.contains("\u{fffd}") })
    }
    func testLargeValuesDegradeWithoutDroppingText() {
        let a = (0..<1100).map { "first\($0)" }.joined(separator: " ")
        let b = (0..<1100).map { "other\($0)" }.joined(separator: " ")
        let result = TorphText.diff(TorphText.segment(a),to: b)
        verify(result.segments,b)
        XCTAssertTrue(result.splits.isEmpty)
    }
    func testAdversarialIDsAndRepeatedEdits() {
        let tokens = ["word","word:0","word~0","word-0","a","a:0","a~1"," ","\n","👩🏽‍💻","café","'hello'","...","hello"]
        var seed: UInt64 = 0x12345678, old: [TorphText.Segment] = []
        for _ in 0..<1200 {
            var value = ""
            for _ in 0..<7 { seed = seed &* 6364136223846793005 &+ 1; value += tokens[Int(seed>>32)%tokens.count]+" " }
            old = TorphText.diff(old,to: value).segments
            verify(old,value)
        }
    }
    func testAnchorsAndGroupedReplacementsMatchTorph() {
        XCTAssertEqual(TorphText.nearestAnchor(at: 2,ids: ["a","b","c","d"],persistent: ["a","d"]),"a")
        XCTAssertEqual(TorphText.nearestAnchor(at: 2,ids: ["a","b","c","d"],persistent: ["a","d"],forwardFirst: true),"d")
        XCTAssertTrue(TorphText.replacementRuns(ids: ["a","b","c","d","e"],members: ["a","b","c","d","e"]).isEmpty)
        XCTAssertEqual(TorphText.replacementRuns(ids: ["a","b","c","d","e","f"],members: ["a","b","c","d","e","f"]).count,1)
    }
}
