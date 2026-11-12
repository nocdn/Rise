import XCTest
@testable import RiseCore
final class TabSearchIndexTests: XCTestCase {
    func testRankingUsesDescriptionsAndThePacketIsBounded() throws {
        let match=SearchableTab(id:UUID().uuidString,title:"Torph",url:"https://github.com/lochie/torph",detail:"Text morphing animation library")
        let others=(0..<300).map { SearchableTab(id:UUID().uuidString,title:"Tab \($0)",url:"https://example.com/\($0)",detail:String(repeating:"Other metadata ",count:200)) }
        let candidates=TabSearchIndex.candidates(others+[match],query:"find me the GitHub page of the text morphing library")
        XCTAssertEqual(candidates.first?.id,match.id);XCTAssertEqual(candidates.count,120)
        let packet=TabSearchIndex.packet(candidates)
        XCTAssertLessThanOrEqual(packet.utf8.count,TabSearchIndex.characterBudget)
        XCTAssertTrue(packet.contains("Text morphing"))
        let hostile=(0..<120).map { _ in SearchableTab(id:UUID().uuidString,title:String(repeating:"😀\"\\",count:200),url:String(repeating:"https://example.com/",count:50),detail:String(repeating:"日本語",count:400)) }
        XCTAssertLessThanOrEqual(TabSearchIndex.packet(hostile).utf8.count,TabSearchIndex.characterBudget)
    }
    func testSearchMetadataDoesNotIncludeURLCredentials() {
        let tab=SearchableTab(id:"one",title:"Account",url:"https://user:password@example.com/path?access_token=hidden&q=visible#token=also-hidden")
        XCTAssertEqual(tab.url,"https://example.com/path?q=visible")
    }
    func testResultsCannotInventIDsOrDuplicateThem() throws {
        XCTAssertEqual(try TabSearchIndex.resultIDs("{\"tabs\":[\"b\",\"fake\",\"a\",\"b\"]}",allowed:["a","b"]),["b","a"])
        XCTAssertEqual(try TabSearchIndex.resultIDs("```json\n{\"tabs\":[]}\n```",allowed:[]),[])
        XCTAssertThrowsError(try TabSearchIndex.resultIDs("I'll navigate to this URL",allowed:[]))
        XCTAssertThrowsError(try TabSearchIndex.resultIDs("{\"tabs\":null}",allowed:[]))
    }
}
