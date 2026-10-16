import Foundation
@testable import Rise

// Unit tests' tabs show blank pages (`BlankPage`), as the engine isn't running.
@MainActor extension BrowserTab {
    /// The tab at `url`, with the page there named `title`, as a page that loaded would be.
    func open(_ url: URL, title: String) {
        load(url); (page as? BlankPage)?.title = title
    }
}
