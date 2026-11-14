import XCTest
import AppKit
@testable import Rise

import WebKit

/// A WebKit page standing in for Gmail's, whose compose window is plain DOM.
@MainActor private final class ComposePage: NSObject, ScriptablePage, WKNavigationDelegate {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900))
    private var loaded: CheckedContinuation<Void, Never>?
    var url: URL? { view.url }
    var title: String? { view.title }
    func runScript(_ body: String, arguments: [String: Any], world: String?) async throws -> Any? {
        try await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world.map { WKContentWorld.world(name: $0) } ?? .page)
    }
    func load(_ html: String) async {
        view.navigationDelegate = self
        await withCheckedContinuation { continuation in loaded = continuation; view.loadHTMLString(html, baseURL: URL(string: "https://mail.google.com/mail/u/0/")) }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { MainActor.assumeIsolated { loaded?.resume(); loaded = nil } }
}

@MainActor final class AIChatEmailTests: XCTestCase {
    private let draft = AIChatEmailDraft(to: "sam@example.com", subject: "🎉 Happy Birthday!", body: "Happy birthday, Sam!\n\nHave a great day & enjoy it + more.")

    func testGmailOpensFilledInFromTheRightAccountWithTheTextKeptAsItIs() throws {
        let components = try XCTUnwrap(URLComponents(url: draft.gmailURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "mail.google.com")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["view": "cm", "fs": "1", "to": "sam@example.com", "su": "🎉 Happy Birthday!", "body": "Happy birthday, Sam!\n\nHave a great day & enjoy it + more."])
        XCTAssertTrue(draft.gmailURL.absoluteString.contains("%2B"), "A + stays a plus rather than a space")
        var from = draft; from.from = "me@gmail.com"; from.cc = "ann@example.com"
        let fromItems = URLComponents(url: from.gmailURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(fromItems.first?.name, "authuser"); XCTAssertEqual(fromItems.first?.value, "me@gmail.com")
        XCTAssertTrue(fromItems.contains(URLQueryItem(name: "cc", value: "ann@example.com")))
        XCTAssertFalse((URLComponents(url: AIChatEmailDraft(subject: "Hi").gmailURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { ["to", "body", "authuser"].contains($0.name) },
                       "Empty fields aren't filled in")
    }

    func testTheToolShowsTheDraftAndTheModelSeesItAsEditedLater() async throws {
        let tools = AIChatBrowserTools(browser: BrowserController())
        let tool = tools.composeEmail
        let result = try await tool.run(["to": " sam@example.com ", "subject": "Hi", "body": "Hello."], tool.step([:]))
        XCTAssertEqual(result.step?.draft, .email(AIChatEmailDraft(to: "sam@example.com", subject: "Hi", body: "Hello.")))
        XCTAssertEqual(result.step?.state, .done)
        do { _ = try await tool.run(["to": "a@b.c"], tool.step([:])); XCTFail("Nothing to show") } catch is AIChatToolFailure {}
        XCTAssertTrue(tools.tools.contains { $0.name == "compose_email" })

        var turn = AIChatTurn(question: "Write Sam a birthday email", pages: [])
        turn.answer = "Here it is."
        var edited = draft; edited.from = "me@gmail.com"
        turn.drafts = [("call_1", .email(edited))]
        let messages = AIChatPrompt.messages(history: [turn], current: AIChatTurn(question: "Make it shorter", pages: []), instructions: "")
        XCTAssertEqual(messages[2]["content"] as? String, "Here it is.\n\n<email_draft>\nFrom: me@gmail.com\nTo: sam@example.com\nSubject: 🎉 Happy Birthday!\n\nHappy birthday, Sam!\n\nHave a great day & enjoy it + more.\n</email_draft>")
        turn.answer = ""
        XCTAssertEqual(AIChatPrompt.messages(history: [turn], current: turn, instructions: "").count, 4, "A turn with only an email still counts")
    }

    func testFromIsAFieldLikeToEachTheSameWayFromItsLabelAndTheCopyMenuCopiesEachPart() throws {
        let card = AIChatEmailCard(draft)
        card.applyColors(AIChatColors(.neutral)); card.applyColors(AIChatColors(.dark)); card.applyColors(AIChatColors(.neutral))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentView?.addSubview(card)
        card.frame = NSRect(x: 0, y: 0, width: 440, height: card.height(for: 440)); card.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.fromField.placeholderAttributedString?.string, "Your email", "Through theme changes")
        XCTAssertTrue(type(of: card.fromField) == type(of: card.toField))
        XCTAssertEqual(card.fromField.font, card.toField.font)
        let labels = card.subviews.compactMap { $0 as? NSTextField }.filter { ["From", "To"].contains($0.stringValue) && !($0 is AIChatCardField) }
        let from = try XCTUnwrap(labels.first { $0.stringValue == "From" }), to = try XCTUnwrap(labels.first { $0.stringValue == "To" })
        XCTAssertEqual(card.fromField.frame.minX-from.frame.maxX, card.toField.frame.minX-to.frame.maxX, accuracy: 0.5)
        XCTAssertLessThan(card.toField.frame.minX, card.fromField.frame.minX, "To's field sits closer in, under its shorter label")
        // No hairline between From and To.
        let lines = card.subviews.filter { $0.frame.height == 0.5 && !$0.isHidden }
        XCTAssertFalse(lines.contains { $0.frame.minY > card.fromField.frame.maxY && $0.frame.maxY < card.toField.frame.minY })
        XCTAssertEqual(lines.count, 3, "Under the header, To and Subject")

        var changes: [AIChatEmailDraft] = []
        card.onChange = { changes.append($0) }
        window.makeFirstResponder(card.fromField)
        card.fromField.stringValue = "me@gmail.com"
        XCTAssertTrue(card.fromField.control(card.fromField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(card.draft.from, "me@gmail.com"); XCTAssertEqual(changes.last?.from, "me@gmail.com")

        var copied: [String] = []
        card.copy = { copied.append($0) }
        let menu = try XCTUnwrap(card.copyButton.makeMenu?())
        XCTAssertEqual(menu.items.map(\.title), ["Copy Subject", "Copy Body"])
        menu.items.forEach { ($0.target as? MenuAction)?.invoke() }
        XCTAssertEqual(copied, [draft.subject, draft.body])
        var opened: AIChatEmailDraft?
        card.onOpen = { opened = $0 }
        card.openButton.actionBlock?()
        XCTAssertEqual(opened, card.draft)
    }

    func testGmailsSmallComposerOpensOverTheInboxOfTheRightAccount() {
        XCTAssertEqual(AIChatGmailCompose.inboxURL(for: draft).absoluteString, "https://mail.google.com/mail/u/0/#inbox?compose=new")
        var from = draft; from.from = "me@gmail.com"
        XCTAssertEqual(AIChatGmailCompose.inboxURL(for: from).absoluteString, "https://mail.google.com/mail/u/me@gmail.com/#inbox?compose=new")
    }

    func testTheComposeWindowIsFilledInAboveTheSignature() async throws {
        let page = ComposePage()
        await page.load("""
        <div role="dialog">
          <input aria-label="To recipients"><span role="link">Cc</span>
          <input name="subjectbox">
          <div role="textbox" contenteditable="true"><div>-- <br>Sig</div></div>
        </div>
        <script>document.querySelector('[role=link]').onclick = () => document.querySelector('[role=dialog]').insertAdjacentHTML('afterbegin', '<input aria-label="CC recipients">')</script>
        """)
        var full = draft; full.cc = "ann@example.com"
        var arguments = AIChatGmailCompose.arguments(for: full); arguments["wait"] = 2
        let filled = try await page.runScript(AIChatGmailCompose.fillScript, arguments: arguments, world: "Rise.GmailCompose") as? Bool
        XCTAssertEqual(filled, true)
        let values = try await page.runScript("""
            return [document.querySelector('[aria-label="To recipients"]').value, document.querySelector('[aria-label="CC recipients"]')?.value || '',
                    document.querySelector('[name=subjectbox]').value, document.querySelector('[role=textbox]').innerText]
            """, arguments: [:], world: nil) as? [String]
        XCTAssertEqual(values?[0], "sam@example.com, ")
        XCTAssertEqual(values?[1], "ann@example.com, ")
        XCTAssertEqual(values?[2], "🎉 Happy Birthday!")
        let body = values?[3] ?? ""
        XCTAssertTrue(body.hasPrefix("Happy birthday, Sam!\n\nHave a great day & enjoy it + more."), body)
        XCTAssertTrue(body.hasSuffix("Sig"), "The signature stays under it")

        let empty = ComposePage()
        await empty.load("<p>Signed out</p>")
        arguments["wait"] = 0.3
        let none = try await empty.runScript(AIChatGmailCompose.fillScript, arguments: arguments, world: "Rise.GmailCompose") as? Bool
        XCTAssertEqual(none, false, "No compose window: the full-page composer takes over")
    }

    func testTheBodyGrowsAsItsEditedAndTheAnswerMakesRoom() throws {
        let answer = AIChatAnswerView(thinking: false)
        answer.frame = NSRect(x: 0, y: 0, width: 440, height: 10)
        var step = AIChatStep(text: "Wrote an email", symbol: "envelope", state: .done); step.draft = .email(draft)
        answer.setStep("call_1", step)
        XCTAssertEqual(answer.cards.count, 1)
        let before = answer.height(for: 440)
        var resized = 0, edits: [AIChatEmailDraft] = []
        answer.onResize = { resized += 1 }
        answer.onDraftChange = { _, draft in if case .email(let draft) = draft { edits.append(draft) } }
        let card = try XCTUnwrap(answer.cards[0].card as? AIChatEmailCard)
        card.body.string += "\nOne more line.\nAnd another."
        card.body.didChangeText()
        XCTAssertGreaterThan(answer.height(for: 440), before)
        XCTAssertGreaterThan(resized, 0)
        XCTAssertEqual(edits.last?.body, card.body.string)
        // The same call's draft again updates the card rather than adding one.
        answer.setStep("call_1", step)
        XCTAssertEqual(answer.cards.count, 1)
    }

    func testEarlierDraftsFoldUpAndOpenAgainWhileTheLatestStaysOpen() throws {
        let answer = AIChatAnswerView(thinking: false)
        answer.frame = NSRect(x: 0, y: 0, width: 440, height: 10)
        for (id, subject) in [("call_1", "Long"), ("call_2", "Short")] {
            var step = AIChatStep(text: "Wrote an email", symbol: "envelope", state: .done)
            step.draft = .email(AIChatEmailDraft(subject: subject, body: "Body\nwith\nlines."))
            answer.setStep(id, step)
        }
        let open = answer.cards[0].card.height(for: 440)
        answer.supersedeCards(keeping: ["call_2"])
        let earlier = try XCTUnwrap(answer.cards[0].card as? AIChatEmailCard), latest = try XCTUnwrap(answer.cards[1].card as? AIChatEmailCard)
        XCTAssertTrue(earlier.isCollapsed); XCTAssertEqual(earlier.height(for: 440), AIChatEmailCard.headerHeight)
        XCTAssertFalse(earlier.chevron.isHidden); XCTAssertTrue(earlier.copyButton.isHidden)
        XCTAssertFalse(latest.isCollapsed); XCTAssertTrue(latest.chevron.isHidden, "The latest can't be folded")
        latest.setCollapsed(true); XCTAssertFalse(latest.isCollapsed)
        earlier.chevron.actionBlock?()
        XCTAssertFalse(earlier.isCollapsed); XCTAssertEqual(earlier.height(for: 440), open)
        XCTAssertFalse(earlier.copyButton.isHidden)
        earlier.chevron.actionBlock?()
        XCTAssertTrue(earlier.isCollapsed)
        // When the latest goes, as on regenerating, the one before opens again.
        answer.supersedeCards(keeping: ["call_1"])
        XCTAssertFalse(earlier.isCollapsed); XCTAssertFalse(earlier.isSuperseded)
    }
}
