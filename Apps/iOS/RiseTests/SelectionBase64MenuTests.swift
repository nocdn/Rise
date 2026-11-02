import XCTest
import UIKit
import WebKit
@testable import RiseiOS

@MainActor final class SelectionBase64MenuTests: XCTestCase {
    func testNativeDecodePreviewAndEncodeActionsCopyExactly() throws {
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        func press(_ action: UIAction) { let button = UIButton(); button.addAction(action, for: .touchUpInside); button.sendActions(for: .touchUpInside) }
        let decode = try XCTUnwrap(SelectionBase64Menu.decodeMenu(for: "8J-YgA", in: nil))
        XCTAssertEqual(decode.title, "Decode Base64")
        XCTAssertEqual(decode.children.map(\.title), ["Copy Value", "😀"])
        XCTAssertTrue(try XCTUnwrap(decode.children.last as? UIAction).attributes.contains(.disabled))
        press(try XCTUnwrap(decode.children.first as? UIAction))
        XCTAssertEqual(UIPasteboard.general.string, "😀")
        let encode = try XCTUnwrap(SelectionBase64Menu.encodeMenu(for: "  café\n", in: nil))
        XCTAssertEqual(encode.title, "Encode"); XCTAssertEqual(encode.children.map(\.title), ["Base64"])
        press(try XCTUnwrap(encode.children.first as? UIAction))
        XCTAssertEqual(UIPasteboard.general.string, Data("  café\n".utf8).base64EncodedString())
        XCTAssertNil(SelectionBase64Menu.decodeMenu(for: "not base64!", in: nil))
        XCTAssertNil(SelectionBase64Menu.encodeMenu(for: "", in: nil))
        XCTAssertNotNil(SelectionBase64Menu.icon)
        XCTAssertNotNil(SelectionBase64Menu.menuIcon)
    }

    func testWebSelectionRetainsExactWhitespaceForEncoding() async throws {
        let page = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(page)
        page.frame = window.bounds; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        page.loadHTMLString("<pre id=p>  hello\nworld\t</pre>", baseURL: nil)
        for _ in 0..<200 where (try? await page.evaluateJavaScript("document.getElementById('p')?.textContent")) as? String == nil { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await page.evaluateJavaScript("getSelection().selectAllChildren(document.getElementById('p'))")
        for _ in 0..<200 where SelectionTimeMenu.rawSelection(in: page).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(SelectionTimeMenu.rawSelection(in: page), "  hello\nworld\t")
        XCTAssertEqual(SelectionTimeMenu.selection(in: page), "hello\nworld")
    }

    func testTranslationIconKeepsNativeCommandRoutingAndOtherMenuItems() throws {
        let icon = try XCTUnwrap(SelectionMenuIcons.translation)
        for selector in ["translate:", "_translate:"] {
            let command = UICommand(title: "Übersetzen", image: UIImage(systemName: "translate"),
                                    action: NSSelectorFromString(selector), propertyList: ["selection": "hello"],
                                    attributes: .disabled, state: .on)
            let other = UIAction(title: "Look Up") { _ in }
            let lookup = UIMenu(identifier: .lookup, options: .displayInline, children: [other, command])
            let root = UIMenu(children: [lookup])
            let result = SelectionMenuIcons.applying(to: root)
            let children = try XCTUnwrap(result.children.first as? UIMenu).children
            let changed = try XCTUnwrap(children.last as? UICommand)
            XCTAssertTrue(changed.image === icon)
            XCTAssertEqual(changed.title, command.title)
            XCTAssertEqual(changed.action, command.action)
            XCTAssertEqual(changed.propertyList as? [String: String], ["selection": "hello"])
            XCTAssertEqual(changed.attributes, command.attributes)
            XCTAssertEqual(changed.state, command.state)
            XCTAssertTrue(children.first === other)
            XCTAssertFalse(command.image === icon, "The original menu is untouched")
            XCTAssertTrue(SelectionMenuIcons.applying(to: result) === result)
        }
    }
}
