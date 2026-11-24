#if DEBUG
import PDFKit
import UIKit
import WebKit

/// Full Page screenshots in the real app: a long page of images that wait to be scrolled to (the
/// browser's own lazy loading, and a script's), blocks that appear as they're scrolled into view,
/// and icons drawn through masks, scrolled partway; then a real article, and a Peek over it. Each is
/// handed over as the screenshot editor would ask for it, then drawn as the image Save Full-Page
/// Image makes, both written beside a capture of the screen to compare, with what the page says
/// was loaded and where it was left scrolled.
@MainActor enum FullPageScreenshotAudit {
    static let argument = "-RiseFullPageScreenshotAudit"

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("FullPageScreenshotAudit")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var results: [String: Any] = [:]
            do {
                try await settle(1500)
                browser.closePanel()
                try await settle(600)
                results["lazy"] = try await capture("lazy", html: lazyPage, scrollTo: 0.3, in: browser, folder: folder)
                // Asked again at once: the page isn't scrolled through a second time.
                results["lazy-again"] = try await capture("lazy-again", scrollTo: nil, in: browser, folder: folder)
                results["lazy-masks"] = try await masks(in: browser.webView)
                results["article"] = try await capture("article", url: URL(string: "https://en.m.wikipedia.org/wiki/Cat")!,
                                                       scrollTo: 0.15, in: browser, folder: folder)
                results["article-masks"] = try await masks(in: browser.webView)
                results["peek"] = try await peek(in: browser, folder: folder)
                results["save"] = try await save(in: browser, folder: folder)
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent("results.json"))
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent("results.json"))
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    private static func settle(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }

    /// Thirty sections: the browser's lazy images, a script's (its own attribute, which only
    /// scrolling to it loads), blocks hidden until scrolled into view, and masked icons, as an
    /// element and as ::before, one of each in a colour.
    static var lazyPage: String {
        let icon = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 20'%3E%3Cpath d='M10 1l3 6 6 1-4.5 4 1 6.5L10 15l-5.5 3.5 1-6.5L1 8l6-1z'/%3E%3C/svg%3E"
        let sections = (0..<30).map { index -> String in
            let colour = "hsl(\(index*37 % 360),70%,88%)"
            let image = "https://picsum.photos/seed/rise\(index)/360/200"
            let body: String
            switch index % 3 {
            case 0: body = "<img loading=lazy width=360 height=200 src='\(image)'>"
            case 1: body = "<img class=io width=360 height=200 data-io='\(image)'>"
            default: body = "<div class=reveal>Revealed \(index)</div>"
            }
            return "<section style='background:\(colour)'><h2><span class=icon></span> Section \(index) <i class=after></i></h2>\(body)</section>"
        }.joined() + (0..<4).map { index in
            "<section style='content-visibility:auto;contain-intrinsic-size:auto 380px;background:#eee'>Deferred text \(index)</section>"
        }.joined()
        return """
        <!doctype html><meta name=viewport content='width=device-width'><title>Lazy test</title>
        <style>
        body { margin: 0; font: 17px -apple-system }
        section { min-height: 380px; padding: 16px }
        img { display: block; max-width: 100%; height: auto; background: #ccc }
        .icon { display: inline-block; width: 28px; height: 28px; background-color: crimson;
                -webkit-mask: url("\(icon)") center / contain no-repeat; }
        .after::before { content: ''; display: inline-block; width: 22px; height: 22px; background-color: royalblue;
                         -webkit-mask-image: url("\(icon)"); -webkit-mask-size: 100% 100%; }
        .reveal { opacity: 0; transition: none; font: bold 40px -apple-system; padding: 40px 0 }
        .reveal.shown { opacity: 1 }
        </style>
        <body>\(sections)
        <script>
        const seen = new IntersectionObserver((entries) => {
            for (const entry of entries) {
                if (!entry.isIntersecting) continue;
                const element = entry.target;
                if (element.dataset.io) element.src = element.dataset.io; else element.classList.add('shown');
                seen.unobserve(element);
            }
        });
        document.querySelectorAll('img.io, .reveal').forEach((element) => seen.observe(element));
        </script>
        """
    }

    /// What the page says it has: images loaded, of each kind, blocks shown, and any of the
    /// capture's marks left behind.
    private static let census = """
    const loaded = (list) => list.filter((image) => image.complete && image.naturalWidth > 0).length;
    const all = [...document.images];
    return {
        images: all.length, loaded: loaded(all),
        lazy: document.querySelectorAll('img[loading]').length, lazyLoaded: loaded([...document.querySelectorAll('img[loading]')]),
        io: document.querySelectorAll('img.io').length, ioLoaded: loaded([...document.querySelectorAll('img.io')]),
        reveal: document.querySelectorAll('.reveal').length, revealed: document.querySelectorAll('.reveal.shown').length,
        leftover: document.querySelectorAll('[data-rise-full-page], [data-rise-full-page-shown]').length,
        scrollY: scrollY, height: document.documentElement.scrollHeight
    };
    """

    private static func capture(_ name: String, html: String? = nil, url: URL? = nil, scrollTo fraction: CGFloat?,
                                in browser: BrowserViewController, folder: URL) async throws -> [String: Any] {
        let page = browser.webView
        if let html { page.loadHTMLString(html, baseURL: URL(string: "https://bands.example/")) }
        else if let url { page.load(URLRequest(url: url)) }
        if html != nil || url != nil {
            try await settle(300)
            for _ in 0..<300 where (try? await page.evaluateJavaScript("document.readyState")) as? String != "complete" { try await settle(100) }
            try await settle(1500)
        }
        let scroll = page.scrollView
        if let fraction {
            let range = max(0, scroll.contentSize.height-scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: range*fraction), animated: false)
            try await settle(800)
        }
        let before = try await page.callAsyncJavaScript(census, contentWorld: .page) as? [String: Any] ?? [:]
        let offset = scroll.contentOffset
        if let window = browser.view.window {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+"-screen.png"))
        }
        let (data, rect, seconds) = try await screenshot(of: browser, name: name)
        try data.write(to: folder.appendingPathComponent(name+".pdf"))
        try await settle(400)
        let after = try await page.callAsyncJavaScript(census, contentWorld: .page) as? [String: Any] ?? [:]
        var result = try await picture(of: data, name: name, folder: folder)
        result["seconds"] = seconds
        result["rect"] = NSCoder.string(for: rect)
        result["offsetBefore"] = NSCoder.string(for: offset)
        result["offsetAfter"] = NSCoder.string(for: scroll.contentOffset)
        result["before"] = before; result["after"] = after
        return result
    }

    /// As the screenshot editor asks for it.
    private static func screenshot(of browser: BrowserViewController, name: String) async throws -> (Data, CGRect, Double) {
        guard let service = browser.view.window?.windowScene?.screenshotService else { throw Failure(name: "no screenshot service") }
        let started = Date()
        let (data, _, rect): (Data?, Int, CGRect) = await withCheckedContinuation { continuation in
            browser.screenshotService(service) { data, index, rect in continuation.resume(returning: (data, index, rect)) }
        }
        guard let data else { throw Failure(name: "no PDF for \(name)") }
        return (data, rect, Date().timeIntervalSince(started))
    }

    /// The PDF drawn as Save Full-Page Image draws it, and its size and first words.
    private static func picture(of data: Data, name: String, folder: URL) async throws -> [String: Any] {
        let file = folder.appendingPathComponent(name+".png"), started = Date()
        let drawn = await Task.detached { FullPage.drawImage(of: data, scale: 3, background: UIColor.white.cgColor, to: file) != nil }.value
        let document = PDFDocument(data: data), box = document?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
        let pixels = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        return ["bytes": data.count, "pages": document?.pageCount ?? 0, "box": NSCoder.string(for: box),
                "png": drawn, "pngBytes": pixels, "pngSeconds": Date().timeIntervalSince(started),
                "text": String((document?.string ?? "").prefix(120)),
                "deferred": (0..<4).filter { (document?.string ?? "").contains("Deferred text \($0)") }.count]
    }

    /// Every masked element and what the icon swap makes of it, then the page put back.
    private static func masks(in page: WKWebView) async throws -> [String: Any] {
        let found = try await page.callAsyncJavaScript("""
        const list = [];
        for (const element of document.body.getElementsByTagName('*')) {
            for (const pseudo of [null, '::before', '::after']) {
                const style = getComputedStyle(element, pseudo);
                const mask = style.webkitMaskImage || style.maskImage || 'none';
                if (mask === 'none') continue;
                const box = element.getBoundingClientRect();
                list.push({ tag: element.tagName + '.' + element.className + (pseudo || ''), mask: mask.slice(0, 90),
                            maskStd: (style.maskImage || '').slice(0, 40), colour: style.backgroundColor, content: style.content,
                            size: style.webkitMaskSize, position: style.webkitMaskPosition, w: style.width, h: style.height,
                            box: [Math.round(box.width), Math.round(box.height)], display: style.display });
                if (list.length > 40) return list;
            }
        }
        const bar = document.querySelector('.last-modified-bar');
        if (bar) for (const element of [bar, ...bar.querySelectorAll('*')]) {
            for (const pseudo of [null, '::before', '::after']) {
                const style = getComputedStyle(element, pseudo), box = element.getBoundingClientRect();
                if (pseudo && style.content === 'none') continue;
                list.unshift({ bar: element.tagName + '.' + element.className + (pseudo || ''), colour: style.backgroundColor,
                               image: style.backgroundImage.slice(0, 80), mask: (style.webkitMaskImage || '').slice(0, 80),
                               filter: style.filter, box: [Math.round(box.width), Math.round(box.height)], w: style.width });
            }
        }
        return list;
        """, contentWorld: .defaultClient)
        let settled = try await page.callAsyncJavaScript(FullPage.Script.prelude+FullPage.Script.settle, arguments: ["timeout": 500, "quiet": 0], contentWorld: .defaultClient)
        let sheet = try await page.callAsyncJavaScript("const kept = window.__riseFullPage; return kept && kept.sheet ? kept.sheet.textContent.slice(0, 1500) : null",
                                                       contentWorld: .defaultClient)
        _ = try await page.callAsyncJavaScript(FullPage.Script.prelude+FullPage.Script.restore, contentWorld: .defaultClient)
        return ["found": found ?? NSNull(), "settled": settled ?? NSNull(), "sheet": sheet ?? NSNull()]
    }

    /// The share sheet's two, on the long page: the PDF handed to the Files picker (stood in for
    /// here, as saved), and the image added to Photos, each toast captured as it says how it went.
    private static func save(in browser: BrowserViewController, folder: URL) async throws -> [String: Any] {
        let page = browser.webView
        page.loadHTMLString(lazyPage, baseURL: URL(string: "https://bands.example/"))
        try await settle(300)
        for _ in 0..<300 where (try? await page.evaluateJavaScript("document.readyState")) as? String != "complete" { try await settle(100) }
        try await settle(1000)
        var result: [String: Any] = [:]
        var handed: URL?
        browser.fileSavePickerOverride = { file, finished in
            handed = file
            try? FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("saved.pdf"))
            finished(folder.appendingPathComponent("saved.pdf"))
        }
        let started = Date()
        browser.saveFullPage(SaveFullPagePDFActivity.type, of: page)
        try await settle(250)
        try shot(browser, "save-pdf-making", folder: folder)
        for _ in 0..<100 where handed == nil { try await settle(100) }
        result["pdfSeconds"] = Date().timeIntervalSince(started)
        result["pdfName"] = handed?.lastPathComponent ?? ""
        result["pdfPages"] = PDFDocument(url: folder.appendingPathComponent("saved.pdf"))?.pageCount ?? 0
        try await settle(500)
        try shot(browser, "save-pdf-saved", folder: folder)
        result["pdfToast"] = browser.toast?.label.text ?? ""
        try await settle(3500)
        browser.saveFullPage(SaveFullPageImageActivity.type, of: page)
        try await settle(250)
        try shot(browser, "save-image-making", folder: folder)
        for _ in 0..<150 where browser.toast?.label.text?.hasPrefix("Making") ?? false { try await settle(100) }
        try await settle(600)
        try shot(browser, "save-image-saved", folder: folder)
        result["imageToast"] = browser.toast?.label.text ?? ""
        browser.fileSavePickerOverride = nil
        return result
    }

    private static func shot(_ browser: BrowserViewController, _ name: String, folder: URL) throws {
        guard let window = browser.view.window else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
    }

    /// A Peek open over the article: the screenshot is of its page, not the one behind.
    private static func peek(in browser: BrowserViewController, folder: URL) async throws -> [String: Any] {
        browser.showPeek(URL(string: "https://en.m.wikipedia.org/wiki/Dog")!)
        try await settle(500)
        guard let peek = browser.presentedViewController as? PeekViewController else { throw Failure(name: "no Peek") }
        for _ in 0..<300 where (try? await peek.browser.webView.evaluateJavaScript("document.readyState")) as? String != "complete" { try await settle(100) }
        try await settle(1500)
        if let window = browser.view.window {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: folder.appendingPathComponent("peek-screen.png"))
        }
        let (data, rect, seconds) = try await screenshot(of: browser, name: "peek")
        try data.write(to: folder.appendingPathComponent("peek.pdf"))
        var result = try await picture(of: data, name: "peek", folder: folder)
        result["seconds"] = seconds; result["rect"] = NSCoder.string(for: rect)
        result["title"] = peek.browser.webView.title ?? ""
        peek.dismiss(animated: false)
        return result
    }

    struct Failure: Error { let name: String }
}
#endif
