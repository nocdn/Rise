import CoreText
import UIKit
import WebKit

/// Font info: the selection menu's item that says what the selected text is set in, its size,
/// weight and the rest, in a panel the bottom bar grows into.
@MainActor enum SelectionFontInfo {
    static let title = "Font info"

    static func build(_ builder: UIMenuBuilder, in page: WKWebView) {
        guard builder.system == .context,
              !SelectionTimeMenu.rawSelection(in: page).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let action = UIAction(title: title, image: UIImage(systemName: "textformat"),
                              identifier: UIAction.Identifier("dev.bartosz.Rise.fontInfo")) { [weak page] _ in
            guard let page else { return }
            Task { await present(from: page) }
        }
        // With Explain in Context, the other way of looking into a selection, or else beside Look Up.
        if builder.menu(for: SelectionExplanation.menuIdentifier) != nil {
            builder.replaceChildren(ofMenu: SelectionExplanation.menuIdentifier) { $0+[action] }
        } else {
            let menu = UIMenu(identifier: UIMenu.Identifier("dev.bartosz.Rise.fontInfoSection"), options: .displayInline, children: [action])
            if builder.menu(for: .lookup) != nil { builder.insertSibling(menu, afterMenu: .lookup) }
            else { builder.insertChild(menu, atEndOfMenu: .root) }
        }
    }

    static func present(from page: WKWebView) async {
        guard let info = await info(in: page) else {
            show("Couldn’t read this text’s font", in: page)
            return
        }
        browser(of: page)?.showFontInfo(info)
    }

    /// The selection's style, read in the frame it's in, or the main frame's if that's gone.
    static func info(in page: WKWebView) async -> FontInfo? {
        let frame = SelectionTimeMenu.selectionFrame(in: page)
        for candidate in frame == nil ? [nil] : [frame, nil] {
            if let result = try? await page.callAsyncJavaScript(script, arguments: [:], in: candidate, contentWorld: SelectionTimeMenu.world),
               let body = result as? [String: Any], var info = FontInfo(body) {
                if info.kind == .web, info.source == nil { info.source = await source(of: info, in: page) }
                return info
            }
        }
        return nil
    }

    /// A web font's file, from a stylesheet on another site, such as Google Fonts', which the
    /// page may use but not read: fetched as the page's session does, then its faces read.
    private static func source(of info: FontInfo, in page: WKWebView) async -> URL? {
        for sheet in info.sheets {
            guard let data = await PageImageDownload.data(from: sheet, referrer: info.page, in: page),
                  let css = String(data: data, encoding: .utf8),
                  let found = FontInfo.source(in: css, family: info.family, weight: info.weight,
                                              italic: info.style != "normal", base: sheet) else { continue }
            return found
        }
        return nil
    }

    private static func browser(of page: WKWebView) -> BrowserViewController? {
        var responder: UIResponder? = page
        while let current = responder, !(current is BrowserViewController) { responder = current.next }
        return responder as? BrowserViewController
    }

    private static func show(_ message: String, in page: WKWebView) {
        guard let browser = browser(of: page) else { return }
        let toast = Toast(message: message, glyph: UIImage(systemName: "exclamationmark.circle"), name: "font-info")
        browser.showToast(toast); toast.leave(after: 2)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    /// Reads the style of the text making up most of the selection, and which family in its
    /// stack the page actually shows: a generic family always draws, a web font once a face
    /// of it has loaded, and an installed font when text measures differently in it.
    static let script = """
    const selection = getSelection();
    if (!selection || !selection.rangeCount || selection.isCollapsed) return null;
    const range = selection.getRangeAt(0);
    let root = range.commonAncestorContainer;
    if (root.nodeType !== 1) root = root.parentElement;
    if (!root) return null;
    const groups = new Map();
    const add = (element, count) => {
      if (!element) return;
      const style = getComputedStyle(element);
      const key = [style.fontFamily, style.fontSize, style.fontWeight, style.fontStyle].join('|');
      const group = groups.get(key) || {element, count: 0};
      group.count += count; groups.set(key, group);
    };
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let visited = 0;
    for (let node = walker.nextNode(); node && visited < 5000; node = walker.nextNode()) {
      visited++;
      if (!range.intersectsNode(node)) continue;
      const start = node === range.startContainer ? range.startOffset : 0;
      const end = node === range.endContainer ? range.endOffset : node.data.length;
      const length = node.data.slice(start, end).trim().length;
      if (length) add(node.parentElement, length);
    }
    if (!groups.size) add(root, 1);
    const ranked = [...groups.values()].sort((a, b) => b.count - a.count);

    const lower = text => String(text).toLowerCase();
    const unquote = name => name.trim().replace(/^(['"])(.*)\\1$/, '$2').trim();
    const split = list => {
      const out = []; let current = '', quote = null;
      for (const ch of list) {
        if (quote) { if (ch === quote) quote = null; current += ch; }
        else if (ch === '"' || ch === "'") { quote = ch; current += ch; }
        else if (ch === ',') { out.push(current); current = ''; }
        else current += ch;
      }
      out.push(current);
      return out.map(unquote).filter(Boolean);
    };
    const generics = {'system-ui': 'system', '-apple-system': 'system', 'blinkmacsystemfont': 'system', 'ui-sans-serif': 'system',
      'ui-serif': 'ui-serif', 'ui-monospace': 'ui-monospace', 'ui-rounded': 'ui-rounded', 'serif': 'serif', 'sans-serif': 'sans-serif',
      'monospace': 'monospace', 'cursive': 'cursive', 'fantasy': 'fantasy', 'emoji': 'emoji', 'math': 'math'};
    const faces = [...document.fonts];
    const context = document.createElement('canvas').getContext('2d');
    const measure = font => { context.font = font; return context.measureText('mmmmmmmmmmlli1WQ@#&gy').width; };
    const installed = name => ['monospace', 'serif', 'sans-serif'].some(base =>
      measure(`72px "${name.replace(/"/g, '')}", ${base}`) !== measure(`72px ${base}`));
    const weightOf = value => { const text = String(value).replace('normal', '400').replace('bold', '700');
      const numbers = text.split(/\\s+/).map(Number).filter(n => !isNaN(n));
      return numbers.length ? [Math.min(...numbers), Math.max(...numbers)] : [400, 400]; };
    const unreadable = [];
    const sourceOf = family => {
      const want = lower(family);
      for (const sheet of document.styleSheets) {
        let rules; try { rules = [...sheet.cssRules]; } catch (e) { if (sheet.href) unreadable.push(sheet.href); continue; }
        while (rules.length) {
          const rule = rules.shift();
          if (rule.type !== 5) { try { if (rule.cssRules) rules.push(...rule.cssRules); } catch (e) {} continue; }
          if (lower(unquote(rule.style.getPropertyValue('font-family'))) !== want) continue;
          const match = rule.style.getPropertyValue('src').match(/url\\(\\s*(['"]?)([^'")]+)\\1\\s*\\)/);
          if (match) { try { return new URL(match[2], sheet.href || location.href).href; } catch (e) {} }
        }
      }
      const squashed = want.replace(/[\\s_-]+/g, '');
      const files = performance.getEntriesByType('resource').map(entry => entry.name)
        .filter(name => /\\.(woff2?|ttf|otf)(\\?|#|$)/i.test(name));
      return files.find(name => { let text = name; try { text = decodeURIComponent(name); } catch (e) {}
        return lower(text).replace(/[\\s_-]+/g, '').includes(squashed); }) || null;
    };
    const describe = element => {
      const style = getComputedStyle(element);
      let rendered = null;
      const stack = split(style.fontFamily).map(name => {
        const key = lower(name);
        if (rendered) return {name, status: 'fallback'};
        if (generics[key]) { rendered = {name, kind: 'generic', generic: generics[key]}; return {name, status: 'used'}; }
        const matching = faces.filter(face => lower(unquote(face.family)) === key);
        if (matching.length) {
          const loaded = matching.filter(face => face.status === 'loaded');
          if (loaded.length) { rendered = {name, kind: 'web', faces: loaded}; return {name, status: 'used'}; }
          return {name, status: matching.some(face => face.status === 'loading') ? 'loading'
            : matching.some(face => face.status === 'error') ? 'failed' : 'unloaded'};
        }
        if (installed(name)) { rendered = {name, kind: 'installed'}; return {name, status: 'used'}; }
        return {name, status: 'missing'};
      });
      if (!rendered) rendered = {name: 'Times', kind: 'fallback'};
      const weight = weightOf(style.fontWeight)[0];
      let variable = false, synthesizedBold = false, synthesizedItalic = false;
      if (rendered.kind === 'web') {
        const ranges = rendered.faces.map(face => weightOf(face.weight));
        variable = ranges.some(([low, high]) => low !== high);
        synthesizedBold = weight >= 600 && Math.max(...ranges.map(([, high]) => high)) < 600;
        synthesizedItalic = style.fontStyle !== 'normal' && !rendered.faces.some(face => face.style !== 'normal');
      }
      return {
        family: rendered.name, kind: rendered.kind, generic: rendered.generic || null, stack,
        source: rendered.kind === 'web' ? sourceOf(rendered.name) : null,
        variable, synthesizedBold, synthesizedItalic, weight,
        size: parseFloat(style.fontSize), rootSize: parseFloat(getComputedStyle(document.documentElement).fontSize),
        style: style.fontStyle, lineHeight: style.lineHeight, letterSpacing: style.letterSpacing, wordSpacing: style.wordSpacing,
        color: style.color, features: style.fontFeatureSettings, variations: style.fontVariationSettings,
        caps: style.fontVariantCaps, numeric: style.fontVariantNumeric, ligatures: style.fontVariantLigatures,
        stretch: style.fontStretch, transform: style.textTransform, decoration: style.textDecorationLine,
        kerning: style.fontKerning, opticalSizing: style.fontOpticalSizing, smoothing: style.webkitFontSmoothing || 'auto'
      };
    };
    const info = describe(ranked[0].element);
    info.others = ranked.slice(1, 4).map(group => { const other = describe(group.element);
      return {family: other.family, kind: other.kind, generic: other.generic, size: other.size, weight: other.weight, style: other.style}; });
    info.otherCount = ranked.length - 1;
    info.page = location.href;
    info.sheets = info.source ? [] : [...new Set(unreadable)].slice(0, 6);
    return info;
    """
}

/// What the page says about the selected text's font.
struct FontInfo {
    enum Kind: String { case web, installed, generic, fallback }
    struct Family { let name: String; let status: String }
    struct Other { let name: String; let size: Double; let weight: Int; let style: String }

    let family: String
    let kind: Kind
    let generic: String?
    let stack: [Family]
    var source: URL?
    /// Stylesheets the page couldn't read, which may say where `source` is.
    let sheets: [URL]
    let variable: Bool
    let synthesizedBold: Bool
    let synthesizedItalic: Bool
    let size: Double
    let rootSize: Double
    let weight: Int
    let style: String
    let lineHeight: String
    let letterSpacing: String
    let wordSpacing: String
    let color: String
    let extras: [String: String]
    let others: [Other]
    let otherCount: Int
    let page: URL?

    init?(_ body: [String: Any]) {
        guard let family = body["family"] as? String, let kind = (body["kind"] as? String).flatMap(Kind.init) else { return nil }
        self.family = family; self.kind = kind
        generic = body["generic"] as? String
        stack = (body["stack"] as? [[String: Any]] ?? []).compactMap { item in
            (item["name"] as? String).map { Family(name: $0, status: item["status"] as? String ?? "") }
        }
        source = (body["source"] as? String).flatMap(URL.init(string:))
        sheets = (body["sheets"] as? [String] ?? []).compactMap(URL.init(string:)).filter { ["http", "https"].contains($0.scheme ?? "") }
        variable = body["variable"] as? Bool ?? false
        synthesizedBold = body["synthesizedBold"] as? Bool ?? false
        synthesizedItalic = body["synthesizedItalic"] as? Bool ?? false
        size = (body["size"] as? NSNumber)?.doubleValue ?? 16
        rootSize = (body["rootSize"] as? NSNumber)?.doubleValue ?? 16
        weight = (body["weight"] as? NSNumber)?.intValue ?? 400
        style = body["style"] as? String ?? "normal"
        lineHeight = body["lineHeight"] as? String ?? "normal"
        letterSpacing = body["letterSpacing"] as? String ?? "normal"
        wordSpacing = body["wordSpacing"] as? String ?? "0px"
        color = body["color"] as? String ?? ""
        var extras: [String: String] = [:]
        for key in ["features", "variations", "caps", "numeric", "ligatures", "stretch", "transform", "decoration", "kerning", "opticalSizing", "smoothing"] {
            if let value = body[key] as? String { extras[key] = value }
        }
        self.extras = extras
        others = (body["others"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["family"] as? String, let kind = (item["kind"] as? String).flatMap(Kind.init) else { return nil }
            return Other(name: Self.displayName(family: name, kind: kind, generic: item["generic"] as? String),
                         size: (item["size"] as? NSNumber)?.doubleValue ?? 16,
                         weight: (item["weight"] as? NSNumber)?.intValue ?? 400, style: item["style"] as? String ?? "normal")
        }
        otherCount = (body["otherCount"] as? NSNumber)?.intValue ?? 0
        page = (body["page"] as? String).flatMap(URL.init(string:))
    }

    /// The file of `family`'s face in a stylesheet that best fits: one covering Latin text, at
    /// the weight and in the style asked for.
    static func source(in css: String, family: String, weight: Int, italic: Bool, base: URL) -> URL? {
        func value(_ name: String, in block: String) -> String? {
            guard let range = block.range(of: "\\b\(name)\\s*:\\s*([^;}]+)", options: [.regularExpression, .caseInsensitive]) else { return nil }
            let text = block[range]
            return text[text.index(after: text.firstIndex(of: ":")!)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var best: (score: Int, url: URL)?
        for chunk in css.components(separatedBy: "@font-face").dropFirst() {
            guard let end = chunk.firstIndex(of: "}") else { continue }
            let block = String(chunk[..<end])
            guard let name = value("font-family", in: block)?.trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")),
                  name.caseInsensitiveCompare(family) == .orderedSame,
                  let src = value("src", in: block),
                  let match = src.range(of: "url\\(\\s*['\"]?([^'\")]+)", options: .regularExpression) else { continue }
            let address = src[match].replacingOccurrences(of: "^url\\(\\s*['\"]?", with: "", options: .regularExpression)
            guard let url = URL(string: address, relativeTo: base)?.absoluteURL else { continue }
            var score = 0
            let unicode = value("unicode-range", in: block)?.uppercased()
            if unicode == nil || unicode!.contains("U+0000-00FF") || unicode!.contains("U+0000-007F") { score += 4 }
            let weights = (value("font-weight", in: block) ?? "400").replacingOccurrences(of: "normal", with: "400")
                .replacingOccurrences(of: "bold", with: "700").split(separator: " ").compactMap { Int($0) }
            if let low = weights.min(), let high = weights.max(), (low...high).contains(weight) { score += 2 }
            if (value("font-style", in: block).map { $0 != "normal" } ?? false) == italic { score += 1 }
            if best == nil || score > best!.score { best = (score, url) }
        }
        return best?.url
    }

    // MARK: What it says

    /// The font's own name: for a generic family, the one iOS draws it in.
    var displayName: String { Self.displayName(family: family, kind: kind, generic: generic) }

    static func displayName(family: String, kind: Kind, generic: String?) -> String {
        switch kind {
        case .web, .installed: family
        case .fallback: "Times"
        case .generic:
            switch generic {
            case "system": "SF Pro"
            case "ui-serif": "New York"
            case "ui-monospace": "SF Mono"
            case "ui-rounded": "SF Pro Rounded"
            case "serif": "Times"
            case "sans-serif": "Helvetica"
            case "monospace": "Courier"
            case "cursive": "Snell Roundhand"
            case "fantasy": "Papyrus"
            case "emoji": "Apple Color Emoji"
            default: family
            }
        }
    }

    /// Where it comes from: the service or site serving it and its file's format, or iOS.
    var sourceName: String {
        switch kind {
        case .web:
            var parts: [String] = []
            if let source {
                if source.scheme == "data" { parts.append("Embedded in the page") }
                else if let host = source.host() {
                    if let provider = Self.provider(host: host) { parts.append(provider) }
                    else if let pageHost = page?.host(), Self.site(host) == Self.site(pageHost) { parts.append("This site") }
                    else { parts.append(host) }
                }
                if let format { parts.append(format) }
            } else { parts.append("Web font") }
            if variable { parts.append("Variable") }
            return parts.joined(separator: " · ")
        case .installed: return "Built into iOS"
        case .generic: return generic == "system" || generic?.hasPrefix("ui-") == true ? "System font" : "Browser’s \(family) font"
        case .fallback: return "Browser default"
        }
    }

    private var format: String? {
        guard let source else { return nil }
        if source.scheme == "data" {
            let mime = source.absoluteString.dropFirst(5).prefix { $0 != ";" && $0 != "," }.lowercased()
            return mime.contains("woff2") ? "WOFF2" : mime.contains("woff") ? "WOFF" : mime.contains("ttf") || mime.contains("truetype") ? "TTF" : mime.contains("otf") || mime.contains("opentype") ? "OTF" : nil
        }
        let ext = source.pathExtension.lowercased()
        return ["woff2", "woff", "ttf", "otf"].contains(ext) ? ext.uppercased() : nil
    }

    private static func provider(host: String) -> String? {
        let host = host.lowercased()
        if host.hasSuffix("gstatic.com") || host.hasSuffix("googleapis.com") { return "Google Fonts" }
        if host.hasSuffix("typekit.net") || host.hasSuffix("adobe.com") { return "Adobe Fonts" }
        if host.hasSuffix("bunny.net") { return "Bunny Fonts" }
        if host.hasSuffix("fontawesome.com") { return "Font Awesome" }
        if host.hasSuffix("typography.com") { return "Hoefler&Co" }
        if host.hasSuffix("fonts.com") { return "Monotype" }
        return nil
    }
    private static func site(_ host: String) -> String { host.split(separator: ".").suffix(2).joined(separator: ".").lowercased() }

    static func weightName(_ weight: Int) -> String {
        switch weight {
        case ..<150: "Thin"
        case ..<250: "Extra Light"
        case ..<350: "Light"
        case ..<450: "Regular"
        case ..<550: "Medium"
        case ..<650: "Semibold"
        case ..<750: "Bold"
        case ..<850: "Extra Bold"
        default: "Black"
        }
    }

    static func number(_ value: Double, digits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = digits; formatter.minimumFractionDigits = 0
        formatter.minimumIntegerDigits = 1; formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func pixels(_ text: String) -> Double? {
        guard text.hasSuffix("px") else { return nil }
        return Double(text.dropLast(2))
    }

    /// The panel's rows: what the text is set in, how big and heavy, its spacing, features and source.
    var rows: [(String, String)] {
        let joined = { (parts: [String?]) in parts.compactMap { $0 }.joined(separator: " · ") }
        var rows = [("Current font", displayName)]
        rows.append(("Size", joined(["\(Self.number(size)) px", rootSize > 0 ? "\(Self.number(size/rootSize)) rem" : nil])))
        rows.append(("Weight", joined(["\(weight)", Self.weightName(weight), synthesizedBold ? "faked" : nil])))
        if let height = Self.pixels(lineHeight) {
            rows.append(("Line height", joined(["\(Self.number(height)) px", size > 0 ? "\(Self.number(height/size))×" : nil])))
        } else { rows.append(("Line height", "Normal")) }
        if let spacing = Self.pixels(letterSpacing), spacing != 0 {
            rows.append(("Letter spacing", joined(["\(Self.number(spacing)) px", size > 0 ? "\(Self.number(spacing/size, digits: 3)) em" : nil])))
        } else { rows.append(("Letter spacing", "Normal")) }
        let features = (extras["features"] ?? "normal").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: " 1", with: "")
        rows.append(("Features", features == "normal" ? "None" : features))
        rows.append(("Source", sourceName))
        return rows
    }
}

/// The panel the bar grows into for Font info: one list of what the selected text is set in,
/// scrolling under the header if it needs to.
final class FontInfoPanel: UIView, UIScrollViewDelegate {
    private let header = PanelHeader(title: SelectionFontInfo.title)
    var closeButton: AnimatedSymbolButton { header.closeButton }
    var buttons: [UIButton] { [closeButton] }
    let scroll = UIScrollView()
    private var list: ListCard?
    private let bottomFade = CAGradientLayer()
    static let fadeHeight: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        closeButton.accessibilityLabel = "Close"
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        addSubview(scroll)
        addSubview(header)
        let steps = SummariseMotion.followUpFade.steps
        bottomFade.colors = [UIColor.black.cgColor]+steps.map { UIColor(white: 0, alpha: $0.alpha).cgColor }+[UIColor.clear.cgColor]
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ info: FontInfo) {
        list?.removeFromSuperview()
        let list = ListCard(rows: info.rows.map { ListCard.Row(title: $0.0, value: $0.1) })
        self.list = list
        scroll.addSubview(list)
        setNeedsLayout(); layoutIfNeeded()
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
    }

    /// The header, and the list below it as far as its bottom.
    func naturalHeight(width: CGFloat) -> CGFloat {
        PanelHeader.height+MenuPanel.top+(list?.naturalHeight(width: Self.listWidth(width)) ?? 0)
    }
    private static func listWidth(_ width: CGFloat) -> CGFloat { 4*MenuPanel.tileSize(width: width).width+3*MenuPanel.spacing }

    func canPullToClose(at point: CGPoint, velocity: CGPoint) -> Bool {
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        guard scroll.frame.contains(point) else { return true }
        let top = -scroll.adjustedContentInset.top
        let scrollable = scroll.contentSize.height > scroll.bounds.height-scroll.adjustedContentInset.top-scroll.adjustedContentInset.bottom+1
        return !scrollable || (scroll.contentOffset.y <= top+1 && velocity.y > 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PanelHeader.height)
        let top = PanelHeader.height
        scroll.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height-top))
        // As wide as Site settings' groups.
        let width = Self.listWidth(bounds.width)
        var y = MenuPanel.top
        if let list {
            list.frame = CGRect(x: (bounds.width-width)/2, y: y, width: width, height: list.naturalHeight(width: width))
            y = list.frame.maxY+MenuPanel.spacing
        }
        scroll.contentSize = CGSize(width: bounds.width, height: y)
        // Only when the list is taller than the panel can be: it scrolls, its last rows fading
        // under the panel's edge, as Privacy Policy's do.
        let scrolls = y > scroll.bounds.height+0.5
        scroll.alwaysBounceVertical = scrolls
        scroll.contentInset.bottom = scrolls ? Self.fadeHeight : 0
        scroll.verticalScrollIndicatorInsets.bottom = scrolls ? Self.fadeHeight : 0
        guard scrolls else { scroll.layer.mask = nil; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let height = max(1, scroll.bounds.height)
        let fade = min(Self.fadeHeight, height)/height
        bottomFade.frame = scroll.bounds
        bottomFade.locations = [0]+SummariseMotion.followUpFade.steps.map { NSNumber(value: 1-fade+$0.at*fade) }+[1]
        scroll.layer.mask = bottomFade
        CATransaction.commit()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // The mask stays at the panel's edge, not with the list.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bottomFade.frame = scrollView.bounds
        CATransaction.commit()
    }

    /// A rounded block in the search field's fill, as More's tiles and Site settings' groups are.
    class Card: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = SearchPanel.fill
            layer.cornerRadius = MenuPanel.cornerRadius
            layer.cornerCurve = .continuous
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    /// A list, divided as Downloads' rows are.
    final class ListCard: Card {
        struct Row { var title: String; var value: String; var marked = false; var dimmed = false }
        static let rowHeight: CGFloat = 48
        private var labels: [(UILabel, UILabel, UIImageView?)] = []
        private var dividers: [UIView] = []
        init(rows: [Row]) {
            super.init(frame: .zero)
            for (index, row) in rows.enumerated() {
                let name = UILabel(), value = UILabel()
                name.text = row.title
                name.font = PanelHeader.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
                name.textColor = row.dimmed ? .secondaryLabel : .label
                value.text = row.value
                value.font = PanelHeader.font("OpenRunde-Medium", size: 14, fallbackWeight: .medium)
                value.textColor = row.marked ? SiteSettingsPanel.switchBlue : .secondaryLabel
                value.textAlignment = .right
                for label in [name, value] { label.adjustsFontForContentSizeCategory = true; addSubview(label) }
                var mark: UIImageView?
                if row.marked {
                    let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)))
                    check.tintColor = SiteSettingsPanel.switchBlue
                    addSubview(check); mark = check
                }
                labels.append((name, value, mark))
                if index > 0 {
                    let divider = UIView(); divider.backgroundColor = .separator
                    addSubview(divider); dividers.append(divider)
                }
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        /// Above the first row and below the last, as Site settings' groups have.
        static let padding: CGFloat = 4
        func naturalHeight(width: CGFloat) -> CGFloat { CGFloat(labels.count)*Self.rowHeight+2*Self.padding }
        override func layoutSubviews() {
            super.layoutSubviews()
            let hairline = 1/max(1, traitCollection.displayScale)
            for (index, (name, value, mark)) in labels.enumerated() {
                let y = Self.padding+CGFloat(index)*Self.rowHeight
                var right = bounds.width-16
                if let mark {
                    let size = mark.intrinsicContentSize
                    mark.frame = CGRect(x: right-size.width, y: y+(Self.rowHeight-size.height)/2, width: size.width, height: size.height)
                    right = mark.frame.minX-6
                }
                let titleWidth = ceil(name.intrinsicContentSize.width)
                let valueWidth = min(ceil(value.intrinsicContentSize.width), max(0, right-16-titleWidth-16))
                value.frame = CGRect(x: right-valueWidth, y: y, width: valueWidth, height: Self.rowHeight)
                name.frame = CGRect(x: 16, y: y, width: min(titleWidth, max(0, value.frame.minX-16-16)), height: Self.rowHeight)
                if index > 0 { dividers[index-1].frame = CGRect(x: 16, y: y-hairline/2, width: bounds.width-32, height: hairline) }
            }
        }
    }
}
