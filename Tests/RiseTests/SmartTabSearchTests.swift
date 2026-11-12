import XCTest
@testable import Rise
@MainActor final class SmartTabSearchTests: XCTestCase {
    func testLatestRequestWinsAndResultsUseTheExistingTabList() async throws {
        let prefs=UserDefaults(suiteName:"SmartTabSearchTests.\(UUID())")!
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser=BrowserController(sessionURL:folder.appendingPathComponent("session.json"),restore:false,preferences:prefs)
        browser.selectAIProvider(.openCode)
        defer { browser.window?.close();browser.saveWork?.cancel();try? FileManager.default.removeItem(at:folder) }
        let first=browser.addTab(),second=browser.addTab()
        first.title="Torph";first.requestedURL=URL(string:"https://github.com/lochie/torph")
        second.title="Other library";second.requestedURL=URL(string:"https://gitlab.com/team/library")
        browser.update();browser.sidebar.beginTabSearch()
        var pending:[CheckedContinuation<String,Error>]=[]
        browser.smartTabSearch.lookup={ _ in try await withCheckedThrowingContinuation { pending.append($0) } }
        let sidebar=browser.sidebar!
        sidebar.searchRow.field.stringValue="find the text morphing library";sidebar.searchTabs(for:sidebar.searchRow.field.stringValue);sidebar.chooseSearchedTab()
        try await Task.sleep(for:.milliseconds(25));XCTAssertTrue(sidebar.searchRow.thinking)
        sidebar.searchRow.field.stringValue="find the GitLab project instead";sidebar.searchTabs(for:sidebar.searchRow.field.stringValue);sidebar.chooseSearchedTab()
        try await Task.sleep(for:.milliseconds(25));XCTAssertEqual(pending.count,2)
        pending[1].resume(returning:"{\"tabs\":[\"\(second.id)\",\"fabricated\"]}")
        try await Task.sleep(for:.milliseconds(25))
        XCTAssertEqual(sidebar.orderedIDs,[second.id]);XCTAssertFalse(sidebar.searchRow.thinking)
        pending[0].resume(returning:"{\"tabs\":[\"\(first.id)\"]}")
        try await Task.sleep(for:.milliseconds(25));XCTAssertEqual(sidebar.orderedIDs,[second.id])
        sidebar.chooseSearchedTab();XCTAssertEqual(browser.selectedID,second.id);XCTAssertFalse(sidebar.isSearchingTabs)
    }
}
