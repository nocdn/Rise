import Foundation

/// A well-known site, as the address bar autofills it and searches it with Tab.
public struct PopularSite: Equatable {
    public let name: String
    /// The domain typed for it, in the region's own form (amazon.co.uk in Britain).
    public let domain: String
    /// The site's own search, with `{q}` for the query and `{domain}` for the domain.
    let search: String?
    /// The brand color, for when its icon hasn't loaded; nil for black-and-white brands.
    public let color: UInt32?
    public let assistant: ChatAssistant?
    public var action: String { assistant == nil ? "Search" : "Ask" }

    public init(name: String, domain: String, search: String?, color: UInt32?, assistant: ChatAssistant? = nil) {
        self.name = name; self.domain = domain; self.search = search; self.color = color; self.assistant = assistant
    }
    public var homeURL: URL { URL(string: "https://" + domain)! }
    public var isSearchable: Bool { search != nil }
    public func searchURL(for query: String) -> URL? {
        guard let search else { return nil }
        // Encoded for a path as much as for a query, since some sites search by path.
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? query
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return URL(string: search.replacingOccurrences(of: "{domain}", with: domain)
            .replacingOccurrences(of: "{language}", with: language)
            .replacingOccurrences(of: "{q}", with: encoded))
    }
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

public enum PopularSites {
    /// The region regional domains are picked for; the Mac's own unless a test sets it.
    nonisolated(unsafe) public static var region: String? = Locale.current.region?.identifier

    private struct Entry {
        let name: String, domain: String, regional: [String: String], search: String?, color: UInt32?
        init(_ name: String, _ domain: String, _ search: String? = nil, color: UInt32? = nil, regional: [String: String] = [:]) {
            self.name = name; self.domain = domain; self.search = search; self.color = color; self.regional = regional
        }
        func site(in region: String?) -> PopularSite {
            PopularSite(name: name, domain: region.flatMap { regional[$0] } ?? domain, search: search, color: color,
                        assistant: ChatAssistant.allCases.first { $0.domain == domain })
        }
        var domains: [String] { [domain] + regional.values.sorted() }
    }

    /// Roughly by how often people go to them, so a short prefix fills in the likelier one.
    private static let entries: [Entry] = [
        Entry("Google", "google.com", "https://www.google.com/search?q={q}", color: 0x4285F4),
        Entry("YouTube", "youtube.com", "https://www.youtube.com/results?search_query={q}", color: 0xFF0000),
        Entry("Facebook", "facebook.com", "https://www.facebook.com/search/top?q={q}", color: 0x0866FF),
        Entry("Instagram", "instagram.com", color: 0xE1306C),
        Entry("Wikipedia", "wikipedia.org", "https://www.wikipedia.org/search-redirect.php?search={q}&language={language}"),
        Entry("X", "x.com", "https://x.com/search?q={q}"),
        Entry("Reddit", "reddit.com", "https://www.reddit.com/search/?q={q}", color: 0xFF4500),
        Entry("Amazon", "amazon.com", "https://www.{domain}/s?k={q}", color: 0xFF9900, regional: [
            "GB": "amazon.co.uk", "DE": "amazon.de", "AT": "amazon.de", "FR": "amazon.fr", "IT": "amazon.it", "ES": "amazon.es",
            "NL": "amazon.nl", "BE": "amazon.com.be", "SE": "amazon.se", "PL": "amazon.pl", "IE": "amazon.ie", "JP": "amazon.co.jp",
            "IN": "amazon.in", "CA": "amazon.ca", "AU": "amazon.com.au", "MX": "amazon.com.mx", "BR": "amazon.com.br",
            "SG": "amazon.sg", "AE": "amazon.ae", "SA": "amazon.sa", "TR": "amazon.com.tr", "EG": "amazon.eg",
        ]),
        Entry("ChatGPT", "chatgpt.com", "https://chatgpt.com/?q={q}"),
        Entry("Gmail", "gmail.com", "https://mail.google.com/mail/u/0/#search/{q}", color: 0xEA4335),
        Entry("LinkedIn", "linkedin.com", "https://www.linkedin.com/search/results/all/?keywords={q}", color: 0x0A66C2),
        Entry("Netflix", "netflix.com", "https://www.netflix.com/search?q={q}", color: 0xE50914),
        Entry("WhatsApp", "web.whatsapp.com", color: 0x25D366),
        Entry("Bing", "bing.com", "https://www.bing.com/search?q={q}", color: 0x008373),
        Entry("Yahoo", "yahoo.com", "https://search.yahoo.com/search?p={q}", color: 0x6001D2),
        Entry("DuckDuckGo", "duckduckgo.com", "https://duckduckgo.com/?q={q}", color: 0xDE5833),
        Entry("BBC", "bbc.com", "https://www.{domain}/search?q={q}", color: 0xBB1919, regional: ["GB": "bbc.co.uk"]),
        Entry("GitHub", "github.com", "https://github.com/search?q={q}"),
        Entry("TikTok", "tiktok.com", "https://www.tiktok.com/search?q={q}", color: 0xFE2C55),
        Entry("Twitch", "twitch.tv", "https://www.twitch.tv/search?term={q}", color: 0x9146FF),
        Entry("eBay", "ebay.com", "https://www.{domain}/sch/i.html?_nkw={q}", color: 0xE53238, regional: [
            "GB": "ebay.co.uk", "DE": "ebay.de", "AT": "ebay.at", "FR": "ebay.fr", "IT": "ebay.it", "ES": "ebay.es",
            "NL": "ebay.nl", "IE": "ebay.ie", "AU": "ebay.com.au", "CA": "ebay.ca", "PL": "ebay.pl",
        ]),
        Entry("Pinterest", "pinterest.com", "https://www.pinterest.com/search/pins/?q={q}", color: 0xE60023),
        Entry("Claude", "claude.ai", "https://claude.ai/new?q={q}", color: 0xD97757),
        Entry("Gemini", "gemini.google.com", "https://gemini.google.com/app?prompt={q}", color: 0x4285F4),
        Entry("Spotify", "spotify.com", "https://open.spotify.com/search/{q}", color: 0x1DB954),
        Entry("Apple", "apple.com"),
        Entry("Microsoft", "microsoft.com", color: 0x00A4EF),
        Entry("Outlook", "outlook.com", color: 0x0078D4),
        Entry("Office", "office.com", color: 0xD83B01),
        Entry("Discord", "discord.com", color: 0x5865F2),
        Entry("Stack Overflow", "stackoverflow.com", "https://stackoverflow.com/search?q={q}", color: 0xF48024),
        Entry("IMDb", "imdb.com", "https://www.imdb.com/find/?q={q}", color: 0xF5C518),
        Entry("Perplexity", "perplexity.ai", "https://www.perplexity.ai/search?q={q}", color: 0x20808D),
        Entry("Etsy", "etsy.com", "https://www.etsy.com/search?q={q}", color: 0xF1641E),
        Entry("Walmart", "walmart.com", "https://www.walmart.com/search?q={q}", color: 0x0071CE),
        Entry("Twitter", "twitter.com", "https://x.com/search?q={q}"),
        Entry("Zoom", "zoom.us", color: 0x0B5CFF),
        Entry("PayPal", "paypal.com", color: 0x003087),
        Entry("Dropbox", "dropbox.com", color: 0x0061FE),
        Entry("Notion", "notion.so"),
        Entry("Figma", "figma.com", color: 0xF24E1E),
        Entry("Canva", "canva.com", color: 0x00C4CC),
        Entry("Cloudflare", "cloudflare.com", color: 0xF38020),
        Entry("Hacker News", "news.ycombinator.com", "https://hn.algolia.com/?q={q}", color: 0xFF6600),
        Entry("The Guardian", "theguardian.com", color: 0x052962),
        Entry("The New York Times", "nytimes.com", "https://www.nytimes.com/search?query={q}"),
        Entry("CNN", "cnn.com", color: 0xCC0000),
        Entry("Medium", "medium.com", "https://medium.com/search?q={q}"),
        Entry("Quora", "quora.com", "https://www.quora.com/search?q={q}", color: 0xB92B27),
        Entry("Vimeo", "vimeo.com", "https://vimeo.com/search?q={q}", color: 0x1AB7EA),
        Entry("SoundCloud", "soundcloud.com", "https://soundcloud.com/search?q={q}", color: 0xFF5500),
        Entry("YouTube Music", "music.youtube.com", "https://music.youtube.com/search?q={q}", color: 0xFF0000),
        Entry("Google Maps", "maps.google.com", "https://www.google.com/maps/search/{q}", color: 0x34A853),
        Entry("Google Translate", "translate.google.com", "https://translate.google.com/?text={q}", color: 0x4285F4),
        Entry("Google Scholar", "scholar.google.com", "https://scholar.google.com/scholar?q={q}", color: 0x4285F4),
        Entry("Google News", "news.google.com", "https://news.google.com/search?q={q}", color: 0x4285F4),
        Entry("Google Drive", "drive.google.com", color: 0x1FA463),
        Entry("Google Docs", "docs.google.com", color: 0x4285F4),
        Entry("AliExpress", "aliexpress.com", "https://www.aliexpress.com/wholesale?SearchText={q}", color: 0xE43225),
        Entry("Target", "target.com", "https://www.target.com/s?searchTerm={q}", color: 0xCC0000),
        Entry("Best Buy", "bestbuy.com", "https://www.bestbuy.com/site/searchpage.jsp?st={q}", color: 0x0046BE),
        Entry("ASOS", "asos.com", "https://www.asos.com/search/?q={q}"),
        Entry("Tesco", "tesco.com", "https://www.tesco.com/groceries/en-GB/search?query={q}", color: 0x00539F),
        Entry("Argos", "argos.co.uk", "https://www.argos.co.uk/search/{q}/", color: 0xD42114),
        Entry("Rightmove", "rightmove.co.uk", color: 0x00DEB6),
        Entry("Booking.com", "booking.com", color: 0x003580),
        Entry("Airbnb", "airbnb.com", color: 0xFF5A5F),
        Entry("Steam", "steampowered.com", "https://store.steampowered.com/search/?term={q}", color: 0x1B2838),
        Entry("Genius", "genius.com", "https://genius.com/search?q={q}", color: 0xFFFF64),
        Entry("Goodreads", "goodreads.com", "https://www.goodreads.com/search?q={q}", color: 0x553B08),
        Entry("Letterboxd", "letterboxd.com", "https://letterboxd.com/search/{q}/", color: 0x00E054),
        Entry("Internet Archive", "archive.org", "https://archive.org/search?query={q}"),
        Entry("GitLab", "gitlab.com", "https://gitlab.com/search?search={q}", color: 0xFC6D26),
        Entry("npm", "npmjs.com", "https://www.npmjs.com/search?q={q}", color: 0xCB3837),
        Entry("PyPI", "pypi.org", "https://pypi.org/search/?q={q}", color: 0x3775A9),
        Entry("crates.io", "crates.io", "https://crates.io/search?q={q}", color: 0xFFC832),
        Entry("MDN", "developer.mozilla.org", "https://developer.mozilla.org/search?q={q}"),
        Entry("Hugging Face", "huggingface.co", "https://huggingface.co/models?search={q}", color: 0xFFD21E),
        Entry("arXiv", "arxiv.org", "https://arxiv.org/search/?query={q}&searchtype=all", color: 0xB31B1B),
        Entry("Kagi", "kagi.com", "https://kagi.com/search?q={q}", color: 0xFFB319),
        Entry("Ecosia", "ecosia.org", "https://www.ecosia.org/search?q={q}", color: 0x008009),
        Entry("Yelp", "yelp.com", "https://www.yelp.com/search?find_desc={q}", color: 0xD32323),
        Entry("Merriam-Webster", "merriam-webster.com", "https://www.merriam-webster.com/dictionary/{q}", color: 0x305F7A),
        Entry("Urban Dictionary", "urbandictionary.com", "https://www.urbandictionary.com/define.php?term={q}", color: 0x134FE6),
        Entry("Unsplash", "unsplash.com", "https://unsplash.com/s/photos/{q}"),
        Entry("Dribbble", "dribbble.com", "https://dribbble.com/search/{q}", color: 0xEA4C89),
        Entry("Vercel", "vercel.com"),
        Entry("Telegram", "web.telegram.org", color: 0x26A5E4),
        Entry("Disney+", "disneyplus.com", color: 0x113CCF),
        Entry("Prime Video", "primevideo.com", color: 0x00A8E1),
        Entry("Duolingo", "duolingo.com", color: 0x58CC02),
    ]

    public static func sites(in region: String? = region) -> [PopularSite] { entries.map { $0.site(in: region) } }

    /// The rest of a popular site's domain, as `query` then the letters it fills in, for a query
    /// of two or more characters that starts it (with or without "www.").
    public static func completion(for query: String, in region: String? = region) -> (site: PopularSite, completed: String)? {
        let typed = query.lowercased()
        guard typed.count >= 2, typed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        for site in sites(in: region) {
            for form in [site.domain, "www." + site.domain] where form.hasPrefix(typed) && form.count > typed.count {
                return (site, query + form.dropFirst(typed.count))
            }
        }
        return nil
    }

    /// An address as a bare domain: no scheme, "www." or trailing slash, in lowercase.
    public static func domain(ofAddress text: String) -> String {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www."] where address.hasPrefix(prefix) { address.removeFirst(prefix.count) }
        if address.hasSuffix("/") { address.removeLast() }
        return address
    }
    /// The site whose address `text` is exactly, in any region's form: its search goes to that domain.
    public static func site(forAddress text: String, in region: String? = region) -> PopularSite? {
        let address = domain(ofAddress: text)
        guard !address.isEmpty else { return nil }
        for entry in entries {
            if let domain = entry.domains.first(where: { $0 == address }) {
                return PopularSite(name: entry.name, domain: domain, search: entry.search, color: entry.color,
                                   assistant: ChatAssistant.allCases.first { $0.domain == domain })
            }
        }
        return nil
    }
}
