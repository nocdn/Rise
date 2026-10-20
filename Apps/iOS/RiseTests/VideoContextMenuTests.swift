import XCTest
import UIKit
import WebKit
@testable import RiseiOS

@MainActor private final class VideoMenuMessages: NSObject, WKScriptMessageHandler {
    var message: WKScriptMessage?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { self.message = message }
}

final class VideoContextMenuTests: XCTestCase {
    @MainActor private func videoURL() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PiPTestVideo", withExtension: "mp4"))
        return "data:video/mp4;base64,"+(try Data(contentsOf: url)).base64EncodedString()
    }
    @MainActor private func wait(_ expression: String, in page: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? await page.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Video menu fixture did not reach \(expression)")
    }
    @MainActor private func host() throws -> (BrowserViewController, UIWindow, VideoMenuMessages, VideoPlaybackPolicy, String) {
        let suite = "RiseVideoMenuTests-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let policy = VideoPlaybackPolicy(preferences: preferences); policy.setAllowsAutoplay(false)
        let browser = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent(), videoPlayback: policy)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.rootViewController = browser; window.makeKeyAndVisible(); browser.view.layoutIfNeeded()
        let messages = VideoMenuMessages(), controller = browser.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "riseVideoMenu"); controller.add(messages, name: "riseVideoMenu")
        return (browser, window, messages, policy, suite)
    }
    @MainActor private func probe(_ page: WKWebView, messages: VideoMenuMessages, x: Double = 80, y: Double = 80) async throws -> WKScriptMessage {
        let nonce = UUID().uuidString; messages.message = nil
        let deadline = Date().addingTimeInterval(5)
        while messages.message == nil, Date() < deadline {
            _ = try await page.callAsyncJavaScript("window.__riseVideoMenu.probeNativePoint(x, y, width, height, nonce)", arguments: ["x":x,"y":y,"width":page.bounds.width,"height":page.bounds.height,"nonce":nonce], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(50))
        }
        let message = try XCTUnwrap(messages.message)
        XCTAssertEqual((message.body as? [String: Any])?["nonce"] as? String, nonce)
        return message
    }
    @MainActor private func command(_ action: String, message: WKScriptMessage, policy: VideoPlaybackPolicy, page: WKWebView, authorized: Bool = true) async throws -> Bool {
        let body = try XCTUnwrap(message.body as? [String: Any]), token = try XCTUnwrap(body["token"] as? String)
        return (try await page.callAsyncJavaScript("return await window.__riseVideoMenu.perform(token, action, authorization)", arguments: ["token":token,"action":action,"authorization":authorized ? policy.menuAuthorization : "invalid"], in: message.frameInfo, contentWorld: .page)) as? Bool == true
    }

    @MainActor func testMenuAnchorLeavesThePageAndScrollingInPlace() async throws {
        let (browser, window, _, _, suite) = try host()
        defer { window.isHidden = true; UserDefaults.standard.removePersistentDomain(forName: suite) }
        let page = browser.webView
        page.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='background:coral'><h1>Keep this page visible</h1></body>", baseURL: nil)
        try await wait("document.body?.textContent.includes('Keep this page visible') === true", in: page)
        let parent = try XCTUnwrap(page.superview), frame = page.frame, siblings = parent.subviews
        let pageSubviews = page.subviews, transform = page.transform, mask = page.layer.mask
        let point = CGPoint(x: page.bounds.midX, y: 50)
        let menu = try XCTUnwrap(VideoContextMenuAnchor(page: page, point: point))
        XCTAssertFalse(menu.targeted.view === page, "WebKit must never become the lifted preview")
        XCTAssertEqual(menu.targeted.view.bounds.size, CGSize(width: 1, height: 1))
        XCTAssertEqual(menu.targeted.view.center, page.convert(point, to: parent))
        XCTAssertEqual(menu.targeted.view.backgroundColor, .clear)
        XCTAssertFalse(menu.targeted.view.isUserInteractionEnabled)
        XCTAssertTrue(menu.targeted.parameters.shadowPath?.isEmpty == true)
        let added = parent.subviews.filter { view in !siblings.contains(where: { $0 === view }) }
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(added.first === menu.targeted.view, "No page snapshot or second player is added")
        XCTAssertEqual(page.subviews, pageSubviews)
        XCTAssertTrue(page.superview === parent)
        XCTAssertEqual(page.frame, frame)
        XCTAssertEqual(page.transform, transform)
        XCTAssertTrue(page.layer.mask === mask)
        XCTAssertFalse(page.isHidden)
        XCTAssertEqual(page.alpha, 1)
        _ = try await page.evaluateJavaScript("document.body.style.height = '3000px'; window.scrollTo(0, 200)")
        try await wait("window.scrollY === 200", in: page)
        // WebKit sends the native scroll offset after the script's completion reply.
        let scrollDeadline = Date().addingTimeInterval(3)
        while page.scrollView.contentOffset.y <= 0, Date() < scrollDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(page.scrollView.contentOffset.y, 0)
        XCTAssertTrue(page.superview === parent)
        XCTAssertEqual(page.transform, transform)
        menu.finish(); menu.finish()
        XCTAssertEqual(parent.subviews.count, siblings.count)
        XCTAssertEqual(page.subviews, pageSubviews)
        XCTAssertNil(VideoContextMenuAnchor(page: page, point: CGPoint(x: 0, y: page.bounds.maxY+10)))
        XCTAssertNil(VideoContextMenuAnchor(page: page, point: CGPoint(x: CGFloat.infinity, y: 20)))
    }

    @MainActor func testNativeCommandsPlayWithAutoplayDisabledAndRevalidateTheSelectedSource() async throws {
        let (browser, window, messages, policy, suite) = try host()
        defer { window.isHidden = true; UserDefaults.standard.removePersistentDomain(forName: suite) }
        let page = browser.webView
        let src = try videoURL()
        page.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}video{width:240px;height:160px}</style><video id='movie' muted loop autoplay src='\(src)'></video><video id='other' muted src='\(src)'></video>", baseURL: nil)
        try await wait("document.querySelector('video')?.readyState >= 1", in: page)
        let initiallyPaused = try await page.evaluateJavaScript("movie.paused") as? Bool
        XCTAssertEqual(initiallyPaused, true)
        let message = try await probe(page, messages: messages)
        let denied = try await command("play", message: message, policy: policy, page: page, authorized: false)
        XCTAssertFalse(denied)
        let played = try await command("play", message: message, policy: policy, page: page)
        XCTAssertTrue(played)
        try await wait("!movie.paused", in: page)
        let unrelated = try await page.callAsyncJavaScript("return await other.play().then(() => 'played', error => error.name)", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(unrelated, "NotAllowedError", "A native action approves only its selected video")
        let fullscreen = try await page.evaluateJavaScript("movie.webkitDisplayingFullscreen") as? Bool
        XCTAssertEqual(fullscreen, false)
        let paused = try await command("pause", message: message, policy: policy, page: page)
        XCTAssertTrue(paused)
        try await wait("movie.paused", in: page)
        _ = try await page.evaluateJavaScript("movie.src = movie.src + '#changed'")
        let stale = try await command("play", message: message, policy: policy, page: page)
        XCTAssertFalse(stale, "A menu must not start a different video loaded into the same element")
    }

    @MainActor func testSourceChildrenAndMediaStreamsInvalidateOpenMenus() async throws {
        let (browser, window, messages, policy, suite) = try host()
        defer { window.isHidden = true; UserDefaults.standard.removePersistentDomain(forName: suite) }
        let page = browser.webView
        page.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}video{width:240px;height:160px}</style><video id='movie' muted><source src='\(try videoURL())' type='video/mp4'></video>", baseURL: nil)
        try await wait("window.movie?.readyState >= 1", in: page)
        var message = try await probe(page, messages: messages)
        _ = try await page.evaluateJavaScript("movie.querySelector('source').src += '#replacement'")
        var accepted = try await command("play", message: message, policy: policy, page: page)
        XCTAssertFalse(accepted, "currentSrc can still point at the old resource after a source child changes")
        _ = try await page.evaluateJavaScript("movie.srcObject = new MediaStream(); void 0")
        message = try await probe(page, messages: messages)
        _ = try await page.evaluateJavaScript("movie.srcObject = new MediaStream(); void 0")
        accepted = try await command("play", message: message, policy: policy, page: page)
        XCTAssertFalse(accepted, "A replacement MediaStream needs a new menu")
    }

    @MainActor func testOverlayAndClosedShadowTargetsRemainControllableAndRemovedTargetsExpire() async throws {
        let (browser, window, messages, policy, suite) = try host()
        defer { window.isHidden = true; UserDefaults.standard.removePersistentDomain(forName: suite) }
        let page = browser.webView
        page.loadHTMLString("""
        <meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}#host{width:240px;height:160px}</style><div id='host'></div>
        <script>window.shadow = host.attachShadow({mode:'closed'}); shadow.innerHTML = '<div style="position:relative"><video muted loop src="\(try videoURL())" style="width:240px;height:160px"></video><div style="position:absolute;inset:0">Overlay</div></div>';window.movie=shadow.querySelector('video');</script>
        """, baseURL: nil)
        try await wait("window.movie?.readyState >= 1", in: page)
        let message = try await probe(page, messages: messages)
        let played = try await command("play", message: message, policy: policy, page: page)
        XCTAssertTrue(played); try await wait("!movie.paused", in: page)
        _ = try await page.evaluateJavaScript("movie.remove()")
        let removed = try await command("pause", message: message, policy: policy, page: page)
        XCTAssertFalse(removed)
    }

    @MainActor func testOpaqueCrossOriginFrameUsesItsOwnVideoAndNativeFrameForCommands() async throws {
        let (browser, window, messages, policy, suite) = try host()
        defer { window.isHidden = true; UserDefaults.standard.removePersistentDomain(forName: suite) }
        let page = browser.webView
        page.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}iframe{width:260px;height:190px;border:4px solid blue;transform:scale(0.9);transform-origin:0 0}</style><iframe sandbox='allow-scripts'></iframe>", baseURL: nil)
        try await wait("document.querySelector('iframe') != null", in: page)
        let child = "<style>body{margin:0}video{width:250px;height:180px}</style><video id='movie' muted loop src='\(try videoURL())'></video>"
        _ = try await page.callAsyncJavaScript("document.querySelector('iframe').srcdoc = html", arguments: ["html":child], in: nil, contentWorld: .page)
        let message = try await probe(page, messages: messages)
        XCTAssertFalse(message.frameInfo.isMainFrame)
        let played = try await command("play", message: message, policy: policy, page: page)
        XCTAssertTrue(played)
        let actuallyPlaying = try await page.callAsyncJavaScript("return !document.querySelector('video').paused", arguments: [:], in: message.frameInfo, contentWorld: .page) as? Bool
        XCTAssertEqual(actuallyPlaying, true)
        XCTAssertNil((message.body as? [String: Any])?["url"] as? String, "A data/blob stream must not offer a reusable video address")
    }

    @MainActor func testStreamingAndBlobSourcesDoNotOfferMisleadingFileDownloads() async throws {
        let (browser, window, messages, _, suite) = try host()
        defer { window.isHidden = true; UserDefaults.standard.removePersistentDomain(forName: suite) }
        let page = browser.webView
        page.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}video{width:240px;height:160px}</style><video id='movie'><source src='https://example.com/stream.m3u8' type='application/vnd.apple.mpegurl'></video>", baseURL: nil)
        try await wait("document.querySelector('video') != null", in: page)
        var message = try await probe(page, messages: messages)
        XCTAssertEqual((message.body as? [String: Any])?["downloadable"] as? Bool, false)
        _ = try await page.callAsyncJavaScript("movie.src = URL.createObjectURL(await (await fetch(data)).blob())", arguments: ["data":try videoURL()], in: nil, contentWorld: .page)
        try await wait("movie.readyState >= 2", in: page)
        message = try await probe(page, messages: messages)
        XCTAssertEqual((message.body as? [String: Any])?["downloadable"] as? Bool, false)
        XCTAssertNil((message.body as? [String: Any])?["url"] as? String)
    }

    @MainActor func testDeliberateFullscreenCanExitAndAutomaticFullscreenRemainsBlocked() async throws {
        let (browser, window, messages, policy, suite) = try host()
        defer { window.isHidden = true; UserDefaults.standard.removePersistentDomain(forName: suite) }
        let page = browser.webView
        page.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}video{width:240px;height:160px}</style><video id='movie' muted loop src='\(try videoURL())'></video>", baseURL: nil)
        try await wait("window.movie?.readyState >= 1", in: page)
        let message = try await probe(page, messages: messages)
        _ = try await page.evaluateJavaScript("window.fullscreenSettled = false; movie.addEventListener('webkitbeginfullscreen', () => fullscreenSettled = true, {once:true})")
        let entered = try await command("fullscreen", message: message, policy: policy, page: page)
        XCTAssertTrue(entered)
        let hasFrame = try await page.evaluateJavaScript("movie.readyState >= 2") as? Bool
        XCTAssertEqual(hasFrame, true, "A metadata-only player must load a frame before AVKit presentation")
        try await wait("window.fullscreenSettled === true", in: page)
        // webkitbeginfullscreen precedes AVKit's presentation animation. The legacy
        // exit call is ignored while WebKit is changing its fullscreen mode.
        try await wait("movie.webkitExitFullscreen(); !movie.webkitDisplayingFullscreen", in: page)
        try await Task.sleep(for: .milliseconds(500))
        _ = try await page.evaluateJavaScript("movie.webkitEnterFullscreen()")
        try await Task.sleep(for: .milliseconds(150))
        let automatic = try await page.evaluateJavaScript("movie.webkitDisplayingFullscreen") as? Bool
        XCTAssertEqual(automatic, false)
    }

    @MainActor func testImageAndLinkTouchesDoNotSelectAVideo() async throws {
        let (browser, window, messages, _, suite) = try host()
        defer { window.isHidden = true; UserDefaults.standard.removePersistentDomain(forName: suite) }
        let page = browser.webView
        page.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}img{width:150px;height:150px}</style><a href='https://example.com/'><img alt='Image' src='data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22150%22 height=%22150%22%3E%3Crect width=%22150%22 height=%22150%22 fill=%22blue%22/%3E%3C/svg%3E'></a>", baseURL: nil)
        try await wait("document.querySelector('img')?.complete === true", in: page)
        messages.message = nil
        _ = try await page.callAsyncJavaScript("window.__riseVideoMenu.probeNativePoint(80, 80, width, height, nonce)", arguments: ["width":page.bounds.width,"height":page.bounds.height,"nonce":UUID().uuidString], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(messages.message, "The video menu must leave ordinary image/link touches to WebKit")
    }

    @MainActor func testDownloadResponseRejectsPlaylistsAndLoginPagesEvenWithoutAFileExtension() {
        let url = URL(string: "https://example.com/media?id=1")!
        for type in ["video/mp4", "video/webm", "application/mp4", "application/octet-stream"] {
            XCTAssertTrue(MobileDownloads.isVideoFile(URLResponse(url: url, mimeType: type, expectedContentLength: 100, textEncodingName: nil)))
        }
        XCTAssertFalse(MobileDownloads.isVideoFile(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type":"video/mp4"])!))
        XCTAssertTrue(MobileDownloads.isVideoFile(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Type":"video/mp4"])!))
        for type in ["application/vnd.apple.mpegurl", "video/x-mpegurl", "application/dash+xml", "text/html", "text/plain"] {
            XCTAssertFalse(MobileDownloads.isVideoFile(URLResponse(url: url, mimeType: type, expectedContentLength: 100, textEncodingName: nil)))
        }
    }
}
