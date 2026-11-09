import UIKit
import WebKit

/// Adds pixel dimensions to WebKit's image menu, and puts the image itself on the pasteboard or in
/// Photos from its Copy and Save to Photos (`PageImageActions`), keeping its other actions.
@MainActor final class ImageContextMenus: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "RiseImageContextMenu")
    private static let installed = NSMapTable<WKWebView, ImageContextMenus>.weakToStrongObjects()
    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }
    private weak var page: WKWebView?
    private var token: String?
    private var frame: WKFrameInfo?
    private var presented = false
    private var touchedAt: CFTimeInterval = 0
    private var heading = ""
    private var source: URL?
    /// Where the image is in its document, in CSS pixels, for the main frame's.
    private var documentRect: CGRect?
    /// WebKit's own actions for an image, which these replace.
    static let copyIdentifier = UIAction.Identifier("WKElementActionTypeCopy")
    static let saveIdentifier = UIAction.Identifier("WKElementActionTypeSaveImage")

    #if DEBUG
    /// What the last menu was built from and into, for the audits.
    static var lastSuggested: [UIMenuElement] = [], lastMenu: UIMenu?, lastTarget: PageImageActions.Target?
    #endif
    static func install(on page: WKWebView) {
        guard installed.object(forKey: page) == nil else { return }
        let menus = ImageContextMenus(); menus.page = page
        installed.setObject(menus, forKey: page)
        page.configuration.userContentController.add(menus, contentWorld: world, name: "riseImageMenu")
    }
    static func hasImage(in page: WKWebView) -> Bool {
        guard let menus = installed.object(forKey: page) else { return false }
        return menus.token != nil && (menus.presented || CACurrentMediaTime()-menus.touchedAt < 3)
    }
    static func menu(in page: WKWebView, actions: [UIMenuElement], link: URL? = nil) -> UIMenu {
        #if DEBUG
        lastSuggested = actions
        #endif
        guard hasImage(in: page), let menus = installed.object(forKey: page) else { return UIMenu(title: "", children: actions) }
        let menu = UIMenu(title: menus.heading, children: imageActions(actions, for: menus.target(in: page), link: link, in: page))
        #if DEBUG
        lastMenu = menu; lastTarget = menus.target(in: page)
        #endif
        return menu
    }
    /// The image the menu is for, as it opens.
    func target(in page: WKWebView) -> PageImageActions.Target {
        let zoom = page.scrollView.zoomScale, offset = page.scrollView.contentOffset
        let rect = documentRect.map { CGRect(x: $0.minX*zoom-offset.x, y: $0.minY*zoom-offset.y, width: $0.width*zoom, height: $0.height*zoom) }
        return PageImageActions.Target(source: source, frame: frame, rect: rect, pageURL: page.url)
    }
    /// WebKit's Copy and Save to Photos, wherever they are in its menu, swapped for ones taking
    /// the image itself; or added, where WebKit took it for a link alone. A linked image keeps a
    /// way to copy its link.
    static func imageActions(_ actions: [UIMenuElement], for target: PageImageActions.Target, link: URL?, in page: WKWebView) -> [UIMenuElement] {
        var copied = false, saved = false, linkCopy = false
        func swap(_ elements: [UIMenuElement]) -> [UIMenuElement] {
            elements.flatMap { element -> [UIMenuElement] in
                if let menu = element as? UIMenu { return [menu.replacingChildren(swap(menu.children))] }
                guard let action = element as? UIAction else { return [element] }
                if action.title == "Copy Link" { linkCopy = true }
                switch action.identifier {
                case copyIdentifier:
                    copied = true
                    return [PageImageActions.copyAction(target, in: page, title: action.title, image: action.image)]
                case saveIdentifier:
                    saved = true
                    return [PageImageActions.saveAction(target, in: page, title: action.title, image: action.image)]
                default: return [action]
                }
            }
        }
        var result = swap(actions)
        var added: [UIMenuElement] = []
        if !copied { added.append(PageImageActions.copyAction(target, in: page, title: "Copy Image", image: nil)) }
        if !saved { added.append(PageImageActions.saveAction(target, in: page, image: nil)) }
        if let link, !linkCopy, copied {
            added.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in UIPasteboard.general.url = link })
        }
        if !added.isEmpty { result.append(UIMenu(options: .displayInline, children: added)) }
        return result
    }
    static func setPresented(_ presented: Bool, in page: WKWebView) {
        guard let menus = installed.object(forKey: page), !presented || hasImage(in: page) else { return }
        menus.presented = presented
        page.callAsyncJavaScript("window.__riseImageMenu?.setPresented(presented)", arguments: ["presented":presented],
            in: menus.frame, in: world, completionHandler: nil)
        if !presented { menus.token = nil; menus.heading = ""; menus.frame = nil; menus.source = nil; menus.documentRect = nil }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === page, let body = message.body as? [String: Any] else { return }
        if body["event"] as? String == "touch" {
            token = body["token"] as? String
            frame = message.frameInfo
            touchedAt = CACurrentMediaTime(); heading = ""
            source = (body["source"] as? String).flatMap(URL.init(string:))
            let rect = body["rect"] as? [Double]
            documentRect = message.frameInfo.isMainFrame && rect?.count == 4 && rect!.allSatisfy(\.isFinite)
                ? CGRect(x: rect![0], y: rect![1], width: rect![2], height: rect![3]) : nil
        } else if let current = token, body["token"] as? String == current,
                  let width = body["width"] as? Int, let height = body["height"] as? Int,
                  width > 0, height > 0 {
            let caption = (body["caption"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            heading = [caption, "\(width) × \(height) px"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    static let source = #"""
    (() => {
      let token = null, pending = null, timeout = null, start = null, caption = null, restoreTimeout = null, showing = false;
      const send = body => window.webkit.messageHandlers.riseImageMenu.postMessage(body);
      function release() {
        clearTimeout(timeout);
        if (pending) { pending.onload = pending.onerror = null; pending.removeAttribute('src'); pending = null; }
      }
      function restoreCaption() {
        clearTimeout(restoreTimeout);
        if (caption && caption.image.getAttribute('title') === caption.value) {
          if (caption.previous === null) caption.image.removeAttribute('title');
          else caption.image.setAttribute('title', caption.previous);
        }
        caption = null;
      }
      function clear() { release(); restoreCaption(); token = null; start = null; showing = false; send({event:'touch'}); }
      addEventListener('touchstart', event => {
        clear();
        if (event.touches.length !== 1) return;
        const image = event.composedPath().find(item => item instanceof HTMLImageElement);
        const source = image?.currentSrc || image?.src;
        if (!image?.complete || !image.naturalWidth || !source) return;
        const selected = token = crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`;
        start = {x:event.touches[0].clientX, y:event.touches[0].clientY};
        const box = image.getBoundingClientRect();
        send({event:'touch', token, source, rect:[box.left+scrollX, box.top+scrollY, box.width, box.height]});
        // naturalWidth on the displayed element is density-corrected for srcset's 2x/3x.
        // A plain image of currentSrc reuses WebKit's resource cache and reports the
        // resource's own dimensions, without a canvas, CORS fetch or native cookie copy.
        const original = pending = new Image();
        original.referrerPolicy = image.referrerPolicy;
        if (image.hasAttribute('crossorigin')) original.crossOrigin = image.crossOrigin;
        const finish = () => {
          if (token === selected && image.isConnected && (image.currentSrc || image.src) === source && original.naturalWidth > 0) {
            const previous = image.getAttribute('title');
            const label = (previous || '').trim().slice(0, 500);
            const size = `${original.naturalWidth} × ${original.naturalHeight} px`;
            const value = [label, size].filter(Boolean).join('\n');
            // WebKit's public menu delegate only handles links. Unlinked images use
            // the element's own title for their native menu heading instead.
            caption = {image, previous, value}; image.setAttribute('title', value);
            if (!showing) restoreTimeout = setTimeout(restoreCaption, 2500);
            send({token:selected, caption:label, width:original.naturalWidth, height:original.naturalHeight});
          }
          release();
        };
        original.onload = finish; original.onerror = release;
        timeout = setTimeout(release, 1500);
        original.src = source;
        if (original.complete) finish();
      }, {capture:true, passive:true});
      addEventListener('touchmove', event => {
        if (start && (event.touches.length !== 1 || Math.hypot(event.touches[0].clientX-start.x, event.touches[0].clientY-start.y) > 14)) clear();
      }, {capture:true, passive:true});
      addEventListener('pagehide', clear);
      Object.defineProperty(window, '__riseImageMenu', {value:Object.freeze({setPresented(presented) {
        showing = presented;
        if (presented) clearTimeout(restoreTimeout); else clear();
      }})});
    })();
    """#
}
