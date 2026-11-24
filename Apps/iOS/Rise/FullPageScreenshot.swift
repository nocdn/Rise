import Photos
import PDFKit
import UIKit
import UniformTypeIdentifiers
import WebKit

/// The screenshot editor's Full Page, as Safari has it: when a screenshot's taken, iOS asks for the
/// page as a PDF, and with one, the editor offers Full Page beside Screen, scrolled to what was on
/// screen. A Peek open over the page gives its own page. The tab switcher, an open panel, and a tab
/// with no page have nothing to give.
extension BrowserViewController: UIScreenshotServiceDelegate {
    func screenshotService(_ screenshotService: UIScreenshotService,
                           generatePDFRepresentationWithCompletion completion: @escaping (Data?, Int, CGRect) -> Void) {
        guard let source = fullPageSource else { return completion(nil, 0, .zero) }
        let page = source.browser.webView, tints = source.tints
        Task {
            let pdf = await FullPage.pdf(of: page, for: .screenshot, pausing: tints)
            completion(pdf?.data, 0, pdf?.shown ?? .zero)
        }
    }

    /// The browser whose page is in front, with the tints that follow its page: a Peek's, when one's
    /// open over this one; else this one's, unless the switcher or a panel covers it.
    var fullPageSource: (browser: BrowserViewController, tints: [PageEdgeTint])? {
        if let peek = presentedViewController as? PeekViewController {
            return peek.isBeingDismissed ? nil : (peek.browser, [peek.tint])
        }
        return isTabSwitcherOpen || isPanelOpen ? nil : (self, [tint])
    }

    // MARK: Save as PDF and Save Full-Page Image

    /// The share sheet's two, for a web page: once the sheet's gone, the whole page is made into a
    /// PDF for the Files picker, or one tall image for Photos, a toast saying what's happening.
    var fullPageActivities: [UIActivity] { [SaveFullPagePDFActivity(), SaveFullPageImageActivity()] }

    func saveFullPage(_ activity: UIActivity.ActivityType, of page: WKWebView) {
        guard page === webView, FullPage.canCapture(page) else { return }
        let asImage = activity == SaveFullPageImageActivity.type
        let progress = Toast(message: asImage ? "Making image…" : "Making PDF…", motionName: "toast")
        progress.symbol.setLoading(name: "full-page-making")
        showToast(progress)
        UIAccessibility.post(notification: .announcement, argument: progress.label.text)
        let tints = [tint]
        Task { [weak self, weak page] in
            guard let page else { return }
            let pdf = await FullPage.pdf(of: page, for: .saving, pausing: tints)
            guard let self else { return }
            guard let pdf else { return finishFullPage(progress, "Couldn’t make the page into \(asImage ? "an image" : "a PDF")", saved: false) }
            if asImage { await saveFullPageImage(pdf, progress: progress) } else { saveFullPagePDF(pdf, progress: progress) }
        }
    }

    private func saveFullPageImage(_ pdf: FullPage.PDF, progress: Toast) async {
        let file = FullPage.temporaryFile(named: pdf.title, extension: "png")
        let scale = view.window?.screen.scale ?? 3, background = pdf.background
        let thumbnail = await Task.detached(priority: .userInitiated) {
            FullPage.drawImage(of: pdf.data, scale: scale, background: background, to: file)
        }.value
        guard let thumbnail else { return finishFullPage(progress, "Couldn’t make the page into an image", saved: false) }
        let saved = await FullPage.addToPhotos(file, named: file.lastPathComponent)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        finishFullPage(progress, saved ? "Saved to Photos" : "Couldn’t save to Photos", saved: saved,
                       glyph: saved ? PageImageActions.thumbnail(of: UIImage(cgImage: thumbnail)) : nil)
    }

    private func saveFullPagePDF(_ pdf: FullPage.PDF, progress: Toast) {
        let file = FullPage.temporaryFile(named: pdf.title, extension: "pdf")
        guard (try? pdf.data.write(to: file)) != nil else { return finishFullPage(progress, "Couldn’t make the page into a PDF", saved: false) }
        if toast === progress { progress.dismiss() }
        let finished: @MainActor (URL?) -> Void = { [weak self] destination in
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            guard let self, let destination else { return }
            FileSaveLocation.remember(destination)
            let saved = Toast(message: FileSaveToast.savedMessage, glyph: Self.fullPageMark(saved: true), name: "full-page-saved")
            showToast(saved)
            saved.leave(after: 2.5)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: saved.label.text)
        }
        if let fileSavePickerOverride { fileSavePickerOverride(file, finished); return }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.directoryURL = FileSaveLocation.folder
        picker.shouldShowFileExtensions = true
        let delegate = FileSavePickerDelegate(finished)
        picker.delegate = delegate
        fileSavePickerDelegate = delegate
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(picker, animated: true)
    }

    /// The toast turns to say how it went, with the picture or a tick when saved, and leaves.
    private func finishFullPage(_ toast: Toast, _ message: String, saved: Bool, glyph: UIImage? = nil) {
        // Gone already, swiped away or replaced: a new one says it.
        let toast = toast.dismissed || self.toast !== toast ? Toast(message: message, motionName: "toast") : toast
        if toast !== self.toast { showToast(toast) }
        if glyph != nil { toast.trailingInset = 15 }
        toast.symbol.setGlyph(glyph ?? Self.fullPageMark(saved: saved),
                              name: glyph == nil ? (saved ? "full-page-saved" : "full-page-failed") : "full-page-picture")
        toast.setMessage(message)
        toast.accessibilityLabel = message
        toast.leave(after: saved ? 2.5 : 3)
        UINotificationFeedbackGenerator().notificationOccurred(saved ? .success : .error)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private static func fullPageMark(saved: Bool) -> UIImage? {
        UIImage(systemName: saved ? "checkmark" : "exclamationmark.circle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    }

    static func visibleContent(of scroll: UIScrollView) -> (rect: CGRect, page: CGSize) {
        FullPage.visibleContent(of: scroll)
    }
}

/// The share sheet's Save as PDF: the whole page as one long PDF page, saved where Files is told.
final class SaveFullPagePDFActivity: UIActivity {
    static let type = UIActivity.ActivityType("dev.bartosz.Rise.save-full-page-pdf")
    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { Self.type }
    override var activityTitle: String? { "Save as PDF" }
    override var activityImage: UIImage? { UIImage(systemName: "doc.richtext") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }
    override func perform() { activityDidFinish(true) }
}

/// The share sheet's Save Full-Page Image: the whole page as one tall PNG, into Photos.
final class SaveFullPageImageActivity: UIActivity {
    static let type = UIActivity.ActivityType("dev.bartosz.Rise.save-full-page-image")
    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { Self.type }
    override var activityTitle: String? { "Save Full-Page Image" }
    override var activityImage: UIImage? { UIImage(systemName: "photo") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }
    override func perform() { activityDidFinish(true) }
}

/// The whole of a page as one long PDF page, as WebKit draws it, made ready first so it's as the
/// page would look scrolled through. Under a still picture of the page, so nothing seems to move,
/// the page is scrolled through to the end, which loads images that wait to be scrolled to, and
/// shows what appears as it's scrolled into view, then back to where it was, kept on what was
/// showing if what's above has grown. Images then have a moment to load, and what reaching the
/// end fetched a moment to arrive.
///
/// For the PDF alone: WebKit's leaves out CSS masks, so an icon drawn as a colour through a mask
/// (Wikipedia's, for one) would come out as a solid square, and each is drawn as an image of that
/// colour instead; and what the page leaves undrawn until it's near the screen is drawn.
@MainActor enum FullPage {
    enum Purpose {
        /// The screenshot editor waits on it: as quick as it can be.
        case screenshot
        /// Asked for in the share sheet, with a toast showing: a little more time for images.
        case saving

        /// The longest the scroll through the page, and the wait for its images, may take.
        var budget: (scroll: Int, images: Int) { self == .screenshot ? (1500, 1500) : (3000, 4000) }
    }

    struct PDF: Sendable {
        let data: Data
        /// What was on screen, in the PDF's coordinates, from its bottom left.
        let shown: CGRect
        let title: String
        let background: CGColor
    }

    /// Only web pages: not a blank tab or Rise's own.
    static func canCapture(_ page: WKWebView) -> Bool {
        guard let scheme = page.url?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    private final class Run {
        let task: Task<PDF?, Never>
        init(_ task: Task<PDF?, Never>) { self.task = task }
    }
    private final class Prepared {
        let url: URL, height: CGFloat
        init(url: URL, height: CGFloat) { self.url = url; self.height = height }
    }
    /// One at a time for each page: a second ask while one's being made has the same.
    private static let running = NSMapTable<WKWebView, Run>.weakToStrongObjects()
    /// A page already scrolled through isn't again until it's grown by a screen or more.
    private static let prepared = NSMapTable<WKWebView, Prepared>.weakToStrongObjects()

    static func pdf(of page: WKWebView, for purpose: Purpose, pausing tints: [PageEdgeTint]) async -> PDF? {
        guard canCapture(page), page.window != nil else { return nil }
        if let run = running.object(forKey: page) { return await run.task.value }
        let task = Task { await make(page, for: purpose, pausing: tints) }
        running.setObject(Run(task), forKey: page)
        let pdf = await task.value
        running.removeObject(forKey: page)
        return pdf
    }

    private static func make(_ page: WKWebView, for purpose: Purpose, pausing tints: [PageEdgeTint]) async -> PDF? {
        guard let url = page.url else { return nil }
        let scroll = page.scrollView, started = scroll.contentOffset
        let screen = max(1, scroll.bounds.height/max(scroll.zoomScale, 0.01))
        let height = scroll.contentSize.height/max(scroll.zoomScale, 0.01)
        let earlier = prepared.object(forKey: page)
        let scrolledThrough = earlier.map { $0.url == url && height < $0.height+screen } ?? false
        let scrolls = height > screen*1.05 && !scrolledThrough
        let budget = purpose.budget

        // A still picture over the page while it's scrolled through and its icons swapped; the
        // strip above it stays the colour it is.
        let cover = page.snapshotView(afterScreenUpdates: false)
        if let cover, let host = page.superview {
            cover.frame = page.frame
            host.insertSubview(cover, aboveSubview: page)
        }
        tints.forEach { $0.paused = true }
        defer {
            tints.forEach { $0.paused = false }
            if let cover {
                UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) { cover.alpha = 0 }
                    completion: { _ in cover.removeFromSuperview() }
            }
        }

        let world = WKContentWorld.defaultClient
        var shift: CGFloat = 0
        if let result = try? await page.callAsyncJavaScript(Script.prelude+Script.scroll, arguments: [
            "scrolls": scrolls, "budget": budget.scroll, "maxSteps": 40, "stepPause": 45,
        ], contentWorld: world) as? [String: Any] {
            shift = (result["shift"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        }
        guard page.url == url else { return nil }
        // Back where it was, kept on what was showing if what's above has grown. Once more after
        // the wait for images: the page's own scroll back, to a whole CSS pixel, can land after.
        let back = {
            let zoom = scroll.zoomScale, inset = scroll.adjustedContentInset
            let lowest = scroll.contentSize.height+inset.bottom-scroll.bounds.height
            let y = min(max(started.y+shift*zoom, -inset.top), max(-inset.top, lowest))
            if abs(scroll.contentOffset.y-y) > 0.01 || abs(scroll.contentOffset.x-started.x) > 0.01 {
                scroll.setContentOffset(CGPoint(x: started.x, y: y), animated: false)
            }
        }
        if scrolls { back() }
        _ = try? await page.callAsyncJavaScript(Script.prelude+Script.settle, arguments: [
            "timeout": budget.images, "quiet": scrolls ? 350 : 0,
        ], contentWorld: world)
        if scrolls { back() }
        guard page.url == url else { return nil }
        let visible = visibleContent(of: scroll)
        let data = try? await page.pdf()
        _ = try? await page.callAsyncJavaScript(Script.prelude+Script.restore, arguments: [:], contentWorld: world)
        guard let data, page.url == url, let document = PDFDocument(data: data), let first = document.page(at: 0) else { return nil }
        prepared.setObject(Prepared(url: url, height: scroll.contentSize.height/max(scroll.zoomScale, 0.01)), forKey: page)

        // PDF coordinates start at the page's bottom left; what was on screen, from its top.
        let box = first.bounds(for: .mediaBox)
        let scale = visible.page.width > 0 ? box.width/visible.page.width : 1
        let shown = CGRect(x: visible.rect.minX*scale, y: box.maxY-visible.rect.maxY*scale,
                           width: visible.rect.width*scale, height: visible.rect.height*scale).intersection(box)
        let background = (page.underPageBackgroundColor ?? .white).resolvedColor(with: page.traitCollection).cgColor
        return PDF(data: data, shown: shown.isNull ? .zero : shown, title: fileName(for: page), background: background)
    }

    /// What's on screen of the page, and the page's whole size, in its own points (CSS pixels): not
    /// what's under the bottom bar.
    static func visibleContent(of scroll: UIScrollView) -> (rect: CGRect, page: CGSize) {
        let zoom = max(scroll.zoomScale, 0.01), inset = scroll.adjustedContentInset
        let page = CGSize(width: scroll.contentSize.width/zoom, height: scroll.contentSize.height/zoom)
        let rect = CGRect(x: (scroll.contentOffset.x+inset.left)/zoom, y: (scroll.contentOffset.y+inset.top)/zoom,
                          width: (scroll.bounds.width-inset.left-inset.right)/zoom,
                          height: (scroll.bounds.height-inset.top-inset.bottom)/zoom)
            .intersection(CGRect(origin: .zero, size: page))
        return (rect.isNull ? .zero : rect, page)
    }

    // MARK: Files

    /// The page's title as a file's name, or its site's where it has none.
    static func fileName(for page: WKWebView) -> String {
        let title = (page.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? (page.url?.host() ?? "Page") : title
        let cleaned = name.map { "/\\:?%*|\"<>".contains($0) || $0.isNewline ? "-" : $0 }
        return String(String(cleaned).prefix(100)).trimmingCharacters(in: .whitespaces)
    }

    /// A file in a folder of its own, so two of the same name don't meet.
    static func temporaryFile(named name: String, extension type: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FullPage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name).appendingPathExtension(type)
    }

    /// The PDF drawn as one image at the screen's scale, or less where that would be past about
    /// 24 million pixels (nearly 100 MB to draw), on the page's own background, written as a PNG.
    /// Returns a square from the top for the toast.
    nonisolated static func drawImage(of pdf: Data, scale: CGFloat, background: CGColor, to file: URL) -> CGImage? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width >= 1, box.height >= 1 else { return nil }
        let scale = min(scale, (24_000_000/(box.width*box.height)).squareRoot())
        let width = Int(box.width*scale), height = Int(box.height*scale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width)/box.width, y: CGFloat(height)/box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: min(width, height)))
    }

    /// Into the photo library from its file, without reading it into memory here.
    nonisolated static func addToPhotos(_ file: URL, named name: String) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: options)
            }
            return true
        } catch { return false }
    }

    // MARK: The page's side

    /// Run in Rise's own script world, so the page's own scripts can't change what they call.
    enum Script {
        static let prelude = """
        const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        // Frames stop when the page isn't drawn; a timer goes on regardless.
        const frames = (count) => Promise.race([pause(120*count), new Promise((resolve) => {
            const next = () => (--count < 1 ? resolve() : requestAnimationFrame(next));
            requestAnimationFrame(next);
        })]);
        const placeholder = (image, value) => !value || value.startsWith('data:') || value === 'about:blank'
            || (image.complete && image.naturalWidth > 0 && image.naturalWidth <= 2);
        const oneAddress = (value) => !!value && !/\\s/.test(value.trim()) && !/^[\\[{]/.test(value.trim());
        // Images and frames that wait to be scrolled to: the browser's own, and the common ways
        // scripts keep the real address aside until then.
        const eager = () => {
            let count = 0;
            for (const element of document.querySelectorAll('img[loading="lazy"], iframe[loading="lazy"]')) {
                element.loading = 'eager'; count++;
            }
            const marked = 'img[data-src], img[data-lazy-src], img[data-original], img[data-srcset], img[data-lazy-srcset], '
                + 'source[data-srcset], source[data-lazy-srcset], iframe[data-src]';
            for (const element of document.querySelectorAll(marked)) {
                const data = element.dataset, source = data.lazySrc || data.src || data.original;
                const set = data.lazySrcset || data.srcset;
                if (element.tagName !== 'SOURCE' && oneAddress(source) && placeholder(element, element.getAttribute('src'))) {
                    element.setAttribute('src', source.trim()); count++;
                }
                if (set && !/^\\s*[\\[{]/.test(set) && placeholder(element, element.getAttribute('srcset'))) {
                    element.setAttribute('srcset', set); count++;
                }
            }
            return count;
        };
        """

        /// Scrolls through to the end and back, a screen at a time, and says how far what was in
        /// the middle of the screen has moved, for the scroll back to keep it there.
        static let scroll = """
        const started = performance.now(), loaded = eager();
        const root = document.scrollingElement || document.documentElement;
        const view = innerHeight, startX = scrollX, startY = scrollY, end = Math.max(0, root.scrollHeight - view);
        const pinned = (element) => {
            for (let current = element; current && current !== document.documentElement; current = current.parentElement) {
                const position = getComputedStyle(current).position;
                if (position === 'fixed' || position === 'sticky') return true;
            }
            return false;
        };
        let anchor = null;
        for (const y of [0.5, 0.35, 0.65, 0.2, 0.8]) {
            const element = document.elementFromPoint(innerWidth / 2, view * y);
            if (element && element !== document.body && element !== document.documentElement && !pinned(element)) { anchor = element; break; }
        }
        const before = anchor ? anchor.getBoundingClientRect().top : 0;
        let steps = 0;
        if (scrolls && end > 0) {
            const step = Math.max(view, end / maxSteps);
            for (let y = 0; ; y = Math.min(end, y + step)) {
                scrollTo({ left: startX, top: y, behavior: 'instant' });
                steps++;
                await frames(2);
                await pause(stepPause);
                if (y >= end || performance.now() - started > budget) break;
            }
            scrollTo({ left: startX, top: startY, behavior: 'instant' });
            await frames(1);
        }
        const after = anchor && anchor.isConnected ? anchor.getBoundingClientRect().top : before;
        return { steps, shift: after - before, loaded, ms: Math.round(performance.now() - started) };
        """

        /// Waits for images still loading, and fonts, then swaps each masked icon for an image of
        /// it in its colour, kept until `restore`.
        static let settle = """
        // Until every image has loaded and, after a scroll through, the page has gone quiet: what
        // reaching the end fetched, such as Wikipedia's related articles, arrives a moment later.
        const started = performance.now();
        let loaded = eager(), changed = started, pending = [];
        const watcher = new MutationObserver(() => { changed = performance.now(); });
        watcher.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'srcset'] });
        const waiting = () => [...document.images].filter((image) => !image.complete);
        while (performance.now() - started < timeout) {
            loaded += eager();
            pending = waiting();
            if (!pending.length && performance.now() - changed >= quiet) break;
            await Promise.race([pause(100), Promise.all(pending.map((image) => new Promise((resolve) => {
                image.addEventListener('load', resolve, { once: true });
                image.addEventListener('error', resolve, { once: true });
            })))]);
        }
        watcher.disconnect();
        if (document.fonts && document.fonts.status !== 'loaded') await Promise.race([document.fonts.ready, pause(300)]);
        const waited = Math.round(performance.now() - started);

        // What the page leaves undrawn until it's near the screen (content-visibility: auto) is
        // drawn, or the PDF would have nothing there; first, so the icons in it have their size.
        const deferred = [];
        if (document.body && 'contentVisibility' in document.body.style) {
            for (const element of document.body.getElementsByTagName('*')) {
                if (getComputedStyle(element).contentVisibility === 'auto') deferred.push(element);
            }
        }
        let shown = null;
        if (deferred.length) {
            for (const element of deferred) element.setAttribute('data-rise-full-page-shown', '');
            shown = document.createElement('style');
            shown.textContent = '[data-rise-full-page-shown] { content-visibility: visible !important; }';
            (document.head || document.documentElement).appendChild(shown);
            await frames(1);
        }

        const swaps = [], drawn = new Map(), limit = performance.now() + 800;
        const number = (value) => { const parsed = parseFloat(value); return Number.isFinite(parsed) ? parsed : null; };
        const picture = (address) => drawn.get(address) || drawn.set(address, new Promise((resolve) => {
            const image = new Image();
            image.onload = () => resolve(image);
            image.onerror = () => resolve(null);
            image.src = address;
            setTimeout(() => resolve(image.complete && image.naturalWidth ? image : null), 400);
        })).get(address);
        // Where the mask lies in its box, as mask-size and mask-position say.
        const placement = (style, width, height, image) => {
            const nw = image.naturalWidth || width, nh = image.naturalHeight || height;
            const size = (style.webkitMaskSize || style.maskSize || 'auto').trim();
            let w, h;
            if (size === 'contain' || size === 'cover') {
                const fit = size === 'contain' ? Math.min(width / nw, height / nh) : Math.max(width / nw, height / nh);
                w = nw * fit; h = nh * fit;
            } else {
                const [sx = 'auto', sy = 'auto'] = size.split(/\\s+/);
                const length = (value, whole) => value === 'auto' ? null : value.endsWith('%') ? whole * parseFloat(value) / 100 : number(value);
                w = length(sx, width); h = length(sy, height);
                if (w == null && h == null) { w = nw; h = nh; } else if (w == null) { w = h * nw / nh; } else if (h == null) { h = w * nh / nw; }
            }
            const position = (style.webkitMaskPosition || style.maskPosition || '0% 0%').trim().split(/\\s+/);
            const offset = (value, room) => value && value.endsWith('%') ? room * parseFloat(value) / 100 : (number(value) || 0);
            return { x: offset(position[0], width - w), y: offset(position[1] || position[0], height - h), w, h };
        };
        const rules = [];
        const swap = async (element, pseudo, style, width, height) => {
            const mask = style.webkitMaskImage || style.maskImage || '';
            const match = /^url\\("?(.*?)"?\\)$/.exec(mask);
            const colour = style.backgroundColor;
            if (!match || /rgba\\(.*,\\s*0\\)$/.test(colour) || colour === 'transparent' || !(width > 0 && height > 0)) return;
            if (width > 200 || height > 200) return;
            // As written in CSS: a quote inside, such as an SVG's own, comes escaped.
            const image = await picture(match[1].replace(/\\\\(.)/g, '$1'));
            let address = null;
            if (image) {
                const scale = 3, canvas = document.createElement('canvas');
                canvas.width = Math.ceil(width * scale); canvas.height = Math.ceil(height * scale);
                const context = canvas.getContext('2d'), at = placement(style, width, height, image);
                context.scale(scale, scale);
                context.drawImage(image, at.x, at.y, at.w, at.h);
                context.globalCompositeOperation = 'source-in';
                context.fillStyle = colour;
                context.fillRect(0, 0, width, height);
                try { address = canvas.toDataURL('image/png'); } catch { address = null; }
                // Decoded before it's used, so it's there when WebKit draws the PDF.
                if (address) { const ready = new Image(); ready.src = address; await ready.decode().catch(() => {}); }
            }
            const mark = String(swaps.length);
            element.setAttribute('data-rise-full-page', element.getAttribute('data-rise-full-page') ? element.getAttribute('data-rise-full-page') + ' ' + mark : mark);
            swaps.push(element);
            // Without the picture (another site's, which can't be drawn here), the mask's own image.
            const background = address ? `url("${address}") 0 0 / 100% 100% no-repeat border-box` : `${mask} ${style.webkitMaskPosition || 'center'} / ${style.webkitMaskSize || 'contain'} no-repeat border-box`;
            rules.push(`[data-rise-full-page~="${mark}"]${pseudo || ''} { -webkit-mask: none !important; mask: none !important; background: ${background} !important; }`);
        };
        const work = [];
        for (const element of document.body ? document.body.getElementsByTagName('*') : []) {
            if (performance.now() > limit || work.length > 400) break;
            const style = getComputedStyle(element);
            if (style.display === 'none') continue;
            if ((style.webkitMaskImage || style.maskImage || 'none') !== 'none') {
                const box = element.getBoundingClientRect();
                work.push(swap(element, null, style, box.width, box.height));
            }
            for (const pseudo of ['::before', '::after']) {
                const style = getComputedStyle(element, pseudo);
                if (style.content === 'none' || (style.webkitMaskImage || style.maskImage || 'none') === 'none') continue;
                const edges = (side) => (number(style[`padding${side}`]) || 0) + (number(style[`border${side}Width`]) || 0);
                const width = (number(style.width) || 0) + (style.boxSizing === 'border-box' ? 0 : edges('Left') + edges('Right'));
                const height = (number(style.height) || 0) + (style.boxSizing === 'border-box' ? 0 : edges('Top') + edges('Bottom'));
                work.push(swap(element, pseudo, style, width, height));
            }
        }
        await Promise.all(work);
        let sheet = null;
        if (rules.length) {
            sheet = document.createElement('style');
            sheet.textContent = rules.join('\\n');
            (document.head || document.documentElement).appendChild(sheet);
            // Backgrounds load once they're styled, a frame or two after.
            await frames(3);
            await pause(50);
        }
        window.__riseFullPage = { sheet, swaps, shown, deferred };
        await frames(1);
        return { loaded, waiting: pending.length, waited, swapped: rules.length, shown: deferred.length,
                 ms: Math.round(performance.now() - started) };
        """

        /// The icons back as they were.
        static let restore = """
        const kept = window.__riseFullPage;
        window.__riseFullPage = null;
        if (kept) {
            kept.sheet?.remove();
            kept.shown?.remove();
            for (const element of kept.swaps) element.removeAttribute('data-rise-full-page');
            for (const element of kept.deferred) element.removeAttribute('data-rise-full-page-shown');
        }
        await frames(2);
        return !!kept;
        """
    }
}
