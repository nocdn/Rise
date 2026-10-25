#if DEBUG
import UIKit
import WebKit

/// An isolated essay with a word already selected, for Explain in Context's real menu and popover.
/// Double-tap or long-press a word for the menu; `-RiseExplainNow` opens the explanation at once.
/// Uses the provider chosen in Settings, with a key there or from `RISE_AI_OPENROUTER_KEY`.
@MainActor enum SelectionExplanationAudit {
    static let argument = "-RiseSelectionExplanationAudit"
    static let explainNow = "-RiseExplainNow"

    static func run(in browser: BrowserViewController) {
        MobileAISettings.shared.allowSharing(with: MobileAISettings.shared.provider)
        browser.webView.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>How to Do Great Work</title>
        <body style="padding:22px;font:18px/1.5 -apple-system;background:#fff;color:#111">
        <h2>How to Do Great Work</h2>
        <p>Develop a habit of working on your own projects. Don't let "work" mean something other people tell you to do.</p>
        <p id="target">There's a kind of excited curiosity that's both the engine and the rudder of great work. It will not only drive you, but if you let it have its way, will also show you what to work on.</p>
        <p>What are you excessively curious about — curious to a degree that would bore most other people? That's what you're looking for.</p>
        </body>
        """, baseURL: URL(string: "https://paulgraham.com/greatwork.html"))
        Task {
            for _ in 0..<100 {
                if (try? await browser.webView.evaluateJavaScript("document.getElementById('target') !== null")) as? Bool == true { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let word = ProcessInfo.processInfo.environment["RISE_EXPLAIN_WORD"] ?? "rudder"
            _ = try? await browser.webView.callAsyncJavaScript("""
                const node = document.getElementById('target').firstChild, at = node.data.indexOf(word);
                const range = document.createRange(); range.setStart(node, at); range.setEnd(node, at + word.length);
                getSelection().removeAllRanges(); getSelection().addRange(range);
                """, arguments: ["word": word], contentWorld: .page)
            guard ProcessInfo.processInfo.arguments.contains(explainNow) else { return }
            // The selection script reports the change on its own turn.
            try? await Task.sleep(for: .milliseconds(600))
            SelectionExplanation.present(from: browser.webView)
        }
    }
}
#endif
