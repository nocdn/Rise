import XCTest
@testable import Rise

final class ProtonMailTests: XCTestCase {
    private func account(_ number: Int = 0) -> ProtonMailAccount {
        ProtonMailAccount(url: URL(string: "https://mail.proton.me/u/\(number)/inbox#category=primary"))!
    }
    @MainActor func testAccountsAndConversationURLs() {
        XCTAssertEqual(account(1).baseURL.absoluteString, "https://mail.proton.me/u/1/")
        XCTAssertEqual(ProtonMailAccount(url: URL(string: "https://mail.proton.me/u/1/almost-all-mail/abc")), account(1))
        XCTAssertNotEqual(account(0), account(1), "Each signed-in account is its own")
        XCTAssertNil(ProtonMailAccount(url: URL(string: "https://mail.proton.me.evil.test/u/0/inbox")))
        XCTAssertNil(ProtonMailAccount(url: URL(string: "http://mail.proton.me/u/0/inbox")))
        XCTAssertNil(ProtonMailAccount(url: URL(string: "https://account.proton.me/u/0/mail")))
        XCTAssertNil(ProtonMailAccount(url: URL(string: "https://mail.proton.me/inbox")), "Proton names the account once it has loaded")
        XCTAssertTrue(TabHoverCards.hasPreview(URL(string: "https://mail.proton.me/u/1/inbox")))
        XCTAssertEqual(account(1).inboxURL.absoluteString, "https://mail.proton.me/u/1/inbox")
        let id = "OUdq_ygLegFE5aPImSyjTP-O-8m5Bi3zL4rmVpcQ1oWlpm4N7PBYHICZW_nkNyhG42Tc9nSSHmC-Io1tZQ5PTQ=="
        XCTAssertEqual(account(1).messageURL(id: id)?.absoluteString, "https://mail.proton.me/u/1/inbox/" + id)
        XCTAssertEqual(account(1).messageURL(id: "abc", page: 3)?.absoluteString, "https://mail.proton.me/u/1/inbox/abc#page=3")
        XCTAssertNil(account().messageURL(id: "../settings"))
        XCTAssertNil(account().messageURL(id: ""))
    }
    @MainActor func testPagesComeFromTheirAccountOnly() async throws {
        let inbox = ProtonMailInbox()
        defer { inbox.tearDown() }
        inbox.loadPage = { request, page in
            try await Task.sleep(for: .milliseconds(request.account == self.account(0) ? 150 : 30))
            let email = GmailEmail(id: "\(request.account.baseURL.path)\(page)".filter(\.isNumber), sender: "Proton", subject: "Welcome", preview: "")
            return GmailPage(emails: [email], hasMore: page == 1)
        }
        inbox.show(.init(account: account(0)))
        try await Task.sleep(for: .milliseconds(20))
        inbox.show(.init(account: account(1)))
        let deadline = Date().addingTimeInterval(5)
        while inbox.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(inbox.emails.map(\.id), ["11"], "Late mail from the other account is discarded")
        inbox.loadMore()
        while inbox.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(inbox.emails.map(\.id), ["11", "12"])
        XCTAssertEqual(inbox.page(of: "12"), 2)
        XCTAssertFalse(inbox.hasMore)
    }
    func testFailuresSayWhatToDo() {
        XCTAssertEqual(ProtonMailPageReader.Failure.signedOut.message, "Sign in to Proton Mail in this tab to see your emails.")
    }
}
