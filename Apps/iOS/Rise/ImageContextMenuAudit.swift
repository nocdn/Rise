#if DEBUG
import UIKit
import WebKit

/// Real WebKit image resources and menu composition, without XCTest's simulator service.
@MainActor enum ImageContextMenuAudit {
    static let argument = "-RiseImageContextMenuAudit"
    struct Failure: Error { let name: String }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("ImageContextMenuAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(in: browser, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch { try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8) }
        }
    }
    private static func exercise(in browser: BrowserViewController, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
            if !valid { throw Failure(name: name) }
        }
        func wait(_ name: String, _ ready: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if try await ready() { try check(name, true); return }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(name, false)
        }
        func imageURL(width: Int = 800, height: Int = 600) -> String {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            return "data:image/png;base64,"+image.pngData()!.base64EncodedString()
        }
        let page = browser.webView
        func load(_ markup: String) {
            page.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='font:18px system-ui;padding:20px'>\(markup)</body>", baseURL: nil)
        }
        func touch(_ expression: String) async throws {
            _ = try await page.callAsyncJavaScript("""
            const image = \(expression);
            const touch = new Touch({identifier:1, target:image, clientX:20, clientY:20});
            image.dispatchEvent(new TouchEvent('touchstart', {bubbles:true, composed:true, touches:[touch]}));
            """, arguments: [:], in: nil, contentWorld: ImageContextMenus.world)
        }
        try check("photo-saving-has-the-required-purpose-string", (Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String)?.isEmpty == false)
        load("<img id='image' style='width:100px;height:75px' src='\(imageURL())'><a id='link' href='https://example.com'>Link</a>")
        try await wait("ordinary-image-loaded") { try await page.evaluateJavaScript("document.querySelector('#image')?.naturalWidth === 800") as? Bool == true }
        try await touch("document.querySelector('#image')")
        try await wait("menu-shows-file-pixels-instead-of-css-size") { ImageContextMenus.menu(in: page, actions: []).title == "800 × 600 px" }
        let nativeSave = UIAction(title: "Save to Photos") { _ in }
        try check("webkits-native-actions-are-preserved", ImageContextMenus.menu(in: page, actions: [nativeSave]).children.first === nativeSave)
        try await touch("document.querySelector('#link')")
        try await wait("plain-links-do-not-inherit-image-titles") { !ImageContextMenus.hasImage(in: page) && ImageContextMenus.menu(in: page, actions: []).title.isEmpty }
        try check("originally-absent-image-titles-are-restored", try await page.evaluateJavaScript("!document.querySelector('#image').hasAttribute('title')") as? Bool == true)
        load("<a href='https://example.com'><img id='image' srcset='\(imageURL()) 2x' style='width:100px'></a>")
        try await wait("retina-srcset-has-density-corrected-natural-size") { try await page.evaluateJavaScript("document.querySelector('#image')?.naturalWidth === 400") as? Bool == true }
        try await touch("document.querySelector('#image')")
        try await wait("retina-menu-shows-the-full-resource-size") { ImageContextMenus.menu(in: page, actions: []).title == "800 × 600 px" }
        _ = try await page.evaluateJavaScript("document.querySelector('#image').title = 'A website update'; void 0")
        try await touch("document.body")
        try await wait("later-website-title-changes-are-preserved") { try await page.evaluateJavaScript("document.querySelector('#image').title === 'A website update'") as? Bool == true }
        load("<img id='image' title='Original caption' src='\(imageURL())'>")
        // loadHTMLString replaces the document asynchronously. The previous
        // fixture's image can still be complete while this navigation commits.
        try await wait("captioned-image-loaded") { try await page.evaluateJavaScript("document.querySelector('#image')?.complete === true && document.querySelector('#image')?.getAttribute('title') === 'Original caption'") as? Bool == true }
        try await touch("document.querySelector('#image')")
        try await wait("dimensions-are-added-to-existing-captions") { ImageContextMenus.menu(in: page, actions: []).title == "Original caption\n800 × 600 px" }
        ImageContextMenus.setPresented(true, in: page)
        try await Task.sleep(for: .milliseconds(2700))
        let captionVisible = try await page.evaluateJavaScript("document.querySelector('#image').title.includes('800 × 600 px')") as? Bool == true
        try check("heading-stays-present-through-native-menu-refreshes", ImageContextMenus.menu(in: page, actions: []).title == "Original caption\n800 × 600 px"
                  && captionVisible)
        ImageContextMenus.setPresented(false, in: page)
        try await wait("original-caption-is-restored-when-the-menu-closes") { try await page.evaluateJavaScript("document.querySelector('#image').title === 'Original caption'") as? Bool == true }
        load("<div id='host'></div><script>host.attachShadow({mode:'open'}).innerHTML = '<img src=\"\(imageURL(width: 360, height: 240))\" style=\"width:90px\">'</script>")
        try await wait("shadow-image-loaded") { try await page.evaluateJavaScript("document.querySelector('#host')?.shadowRoot.querySelector('img')?.complete === true") as? Bool == true }
        _ = try await page.callAsyncJavaScript("""
        const image = document.querySelector('#host').shadowRoot.querySelector('img');
        const blob = await (await fetch(image.src)).blob();
        await new Promise(resolve => { image.onload = resolve; image.src = URL.createObjectURL(blob); });
        """, arguments: [:], in: nil, contentWorld: ImageContextMenus.world)
        try await touch("document.querySelector('#host').shadowRoot.querySelector('img')")
        try await wait("blob-images-and-shadow-dom-retain-file-dimensions") { ImageContextMenus.menu(in: page, actions: []).title == "360 × 240 px" }
        load("<img id='image' src='data:image/png,broken'>")
        try await wait("broken-image-finished-loading") { try await page.evaluateJavaScript("document.querySelector('#image')?.complete === true") as? Bool == true }
        try await touch("document.querySelector('#image')")
        try await wait("broken-images-never-show-invented-dimensions") { !ImageContextMenus.hasImage(in: page) && ImageContextMenus.menu(in: page, actions: []).title.isEmpty }
        load("<h1>Save image check</h1><p>800 × 600 pixel image, displayed at 240 × 180.</p><img id='image' alt='800 by 600 pixel test image' style='width:240px;height:180px' src='\(imageURL())'>")
        try await wait("native-menu-fixture-ready") { try await page.evaluateJavaScript("document.querySelector('#image')?.complete === true && document.body.textContent.includes('Save image check')") as? Bool == true }
    }
}
#endif
