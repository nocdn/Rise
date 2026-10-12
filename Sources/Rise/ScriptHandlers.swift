import WebKit

/// WebKit's message handlers, for `WebPage.addMessageHandler`.
@MainActor final class ScriptHandler: NSObject, WKScriptMessageHandler {
    private let receive: (PageMessage) -> Void
    init(_ receive: @escaping (PageMessage) -> Void) { self.receive = receive }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(WebKitPage.message(message))
    }
}
@MainActor final class ReplyingScriptHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let receive: (PageMessage, @escaping (Any?, String?) -> Void) -> Void
    init(_ receive: @escaping (PageMessage, @escaping (Any?, String?) -> Void) -> Void) { self.receive = receive }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        receive(WebKitPage.message(message), replyHandler)
    }
}
