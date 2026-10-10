import Foundation

/// The unread count some sites put in their page title, which tabs leave out.
enum TitleNotificationCount {
    /// YouTube and X lead with it, as in "(7) Title" or "(9+) Title"; a year such as "(2024)" is left
    /// alone. Gmail puts it after the folder, as in "Inbox (49) - name@gmail.com - Gmail", or leads
    /// with it on its own, as in "(1,582) - name@gmail.com - Gmail".
    static func removing(from title: String, url: URL?) -> String {
        if YouTubeVideoPage.isYouTube(url) || isX(url) { return removingPrefix(#"^\(\d{1,2}\+?\)\s+"#, from: title) }
        guard url?.host?.lowercased() == "mail.google.com" else { return title }
        let count = #"\(\d{1,3}(,\d{3})*\+?\)"#
        let leading = removingPrefix("^" + count + #"(\s+-)?\s+"#, from: title)
        guard leading == title, let range = title.range(of: " " + count + "(?= - )", options: .regularExpression) else { return leading }
        return title.replacingCharacters(in: range, with: "")
    }
    private static func isX(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return ["x.com", "twitter.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    private static func removingPrefix(_ pattern: String, from title: String) -> String {
        guard let range = title.range(of: pattern, options: .regularExpression), range.upperBound < title.endIndex else { return title }
        return String(title[range.upperBound...])
    }
}
