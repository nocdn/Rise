import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class VideoPlaybackTests: XCTestCase {
    @MainActor private func policy() throws -> (VideoPlaybackPolicy, String) {
        let suite = "RiseVideoTests-\(UUID())"
        return (VideoPlaybackPolicy(preferences: try XCTUnwrap(UserDefaults(suiteName: suite))), suite)
    }

    @MainActor private func host(_ browser: BrowserViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser; window.makeKeyAndVisible()
        browser.view.layoutIfNeeded()
        return window
    }

    @MainActor private func wait(_ expression: String, in page: WKWebView,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? await page.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        let state = try? await page.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('video')].map(v => ({paused:v.paused, ready:v.readyState, autoplay:v.autoplay, inline:v.playsInline, error:v.error?.code})))")
        XCTFail("WebKit fixture timed out: \(expression). Videos: \(state ?? "unknown")", file: file, line: line)
    }

    private var videoURL: String {
        get throws {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PiPTestVideo", withExtension: "mp4"))
            return "data:video/mp4;base64," + (try Data(contentsOf: url)).base64EncodedString()
        }
    }

    @MainActor func testAutoplayStaysInlineForParserDynamicDetachedAndShadowVideos() async throws {
        let (policy, suite) = try policy()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let browser = BrowserViewController(startURL: nil, videoPlayback: policy)
        let window = try host(browser); defer { window.isHidden = true }
        let page = browser.webView, src = try videoURL
        page.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <video id="parser" muted autoplay loop src="\(src)" style="width:200px;height:110px"></video>
        <div id="host"></div>
        <script>
          window.fullscreenCount = 0;
          document.addEventListener('webkitbeginfullscreen', () => fullscreenCount++, true);
          window.detached = document.createElement('video');
          detached.muted = true; detached.src = '\(src)';
          window.detachedInlineBeforePlay = detached.playsInline;
          detached.play().catch(() => {});
          window.shadow = host.attachShadow({mode:'closed'});
          shadow.innerHTML = '<video muted autoplay loop src="\(src)"></video>';
          window.shadowVideo = shadow.querySelector('video');
          window.dynamic = document.createElement('video');
          dynamic.muted = true; dynamic.loop = true; dynamic.src = '\(src)';
          document.body.append(dynamic);
          dynamic.removeAttribute('playsinline'); dynamic.removeAttribute('webkit-playsinline');
          dynamic.play().catch(() => {});
        </script>
        """, baseURL: nil)
        try await wait("window.dynamic && parser.currentTime > 0 && dynamic.currentTime > 0", in: page)
        try await wait("shadowVideo.playsInline && detachedInlineBeforePlay", in: page)
        let result = try await page.evaluateJavaScript("""
        [parser, dynamic, detached, shadowVideo].every(v => v.playsInline && !v.webkitDisplayingFullscreen)
          && fullscreenCount === 0
        """) as? Bool
        XCTAssertEqual(result, true)
        XCTAssertTrue(page.configuration.allowsInlineMediaPlayback)
        XCTAssertEqual(page.configuration.mediaTypesRequiringUserActionForPlayback, .audio)
        // Pages that explicitly reset the inline property must not reintroduce fullscreen.
        try await page.evaluateJavaScript("parser.playsInline = false; parser.removeAttribute('webkit-playsinline')")
        try await wait("parser.playsInline && parser.hasAttribute('webkit-playsinline')", in: page)
        // WKWebView.evaluateJavaScript itself supplies a user gesture. Run unsolicited calls
        // in a page task after that gesture ends, as a scroll/visibility callback would.
        try await page.evaluateJavaScript("""
        setTimeout(() => {
          dynamic.webkitEnterFullscreen(); dynamic.webkitSetPresentationMode('fullscreen');
          window.standardResult = 'unsupported';
          if (host.requestFullscreen) host.requestFullscreen().then(() => standardResult='entered', e => standardResult=e.name);
          window.triedFullscreen=true;
        }, 0); void 0
        """)
        try await wait("window.triedFullscreen === true", in: page)
        let fullscreen = try await page.evaluateJavaScript("dynamic.webkitDisplayingFullscreen || fullscreenCount > 0") as? Bool
        XCTAssertEqual(fullscreen, false)
        let standard = try await page.evaluateJavaScript("standardResult === 'unsupported' || standardResult === 'NotAllowedError'") as? Bool
        XCTAssertEqual(standard, true)
    }

    @MainActor func testAutoplayOffBlocksMutedAttributesScriptAndScrollInAllFramesAndUpdatesLive() async throws {
        let (policy, suite) = try policy()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        policy.setAllowsAutoplay(false)
        let browser = BrowserViewController(startURL: nil, videoPlayback: policy)
        let window = try host(browser); defer { window.isHidden = true }
        let page = browser.webView, src = try videoURL
        let child = """
        <video id="child" muted autoplay loop src="\(src)"></video>
        <script>
        setInterval(() => parent.postMessage({childPaused:child.paused, childInline:child.playsInline}, '*'), 50);
        setInterval(() => child.play().catch(() => {}), 100);
        </script>
        """
        let childURL = "data:text/html;base64," + Data(child.utf8).base64EncodedString()
        page.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <video id="video" controls muted autoplay loop src="\(src)"></video>
        <iframe src="\(childURL)"></iframe>
        <div style="height:3000px"></div>
        <script>
        window.playResult = '';
        video.play().then(() => playResult='played', e => playResult=e.name);
        addEventListener('message', e => { if ('childPaused' in e.data) window.childState = e.data; });
        addEventListener('scroll', () => video.play().catch(e => window.scrollResult=e.name));
        </script>
        """, baseURL: nil)
        try await wait("window.playResult === 'NotAllowedError' && window.childState?.childPaused === true", in: page)
        try await wait("video.readyState >= 1 && video.paused && !video.autoplay && childState.childInline", in: page)
        try await page.evaluateJavaScript("scrollTo(0, 500)")
        try await wait("window.scrollResult === 'NotAllowedError' && video.paused", in: page)
        // Synthetic clicks cannot authorize playback.
        try await page.evaluateJavaScript("setTimeout(() => { video.addEventListener('click', () => video.play().catch(e => window.clickResult=e.name)); video.click(); }, 0); void 0")
        try await wait("window.clickResult === 'NotAllowedError' && video.paused", in: page)

        policy.setAllowsAutoplay(true)
        try await page.evaluateJavaScript("setTimeout(() => video.play().catch(() => {}), 0); void 0")
        try await wait("video.currentTime > 0 && !video.paused && childState.childPaused === false", in: page)
        policy.setAllowsAutoplay(false)
        try await wait("video.paused && childState.childPaused", in: page)
        XCTAssertFalse(policy.allowsAutoplay)
        let restored = VideoPlaybackPolicy(preferences: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(restored.allowsAutoplay)
        // Repeated switches retain unrelated scripts and install just one playback policy.
        XCTAssertEqual(page.configuration.userContentController.userScripts.filter { $0.source.hasPrefix("// Rise video playback policy") }.count, 1)
        XCTAssertTrue(page.configuration.userContentController.userScripts.contains { $0.source == InputZoomPolicy.source })
        page.loadHTMLString("<video id='fresh' muted autoplay src='\(src)'></video>", baseURL: nil)
        try await wait("window.fresh && fresh.readyState >= 1 && fresh.paused && !fresh.autoplay && fresh.playsInline", in: page)
    }

    @MainActor func testAutoplaySettingsMatchesSyncAndWorksInPrivateBrowsing() async throws {
        let (policy, suite) = try policy()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let browser = BrowserViewController(startURL: nil, isPrivateBrowsing: true, videoPlayback: policy)
        let window = try host(browser); defer { window.isHidden = true }
        let bar = browser.bottomBar
        bar.moreButton.sendActions(for: .primaryActionTriggered)
        browser.openSiteSettings(); browser.openAppSettings()
        try await Task.sleep(for: .milliseconds(500))
        let panel = bar.appSettings
        XCTAssertFalse(panel.syncRow.toggle.isEnabled)
        XCTAssertTrue(panel.autoplayRow.toggle.isEnabled)
        XCTAssertTrue(panel.autoplayRow.toggle.isOn)
        XCTAssertNotNil(MenuIcons.video)
        XCTAssertEqual(panel.autoplayRow.frame.width, panel.syncRow.frame.width)
        XCTAssertEqual(panel.autoplayRow.frame.height, panel.syncRow.frame.height)
        XCTAssertGreaterThan(panel.autoplayRow.frame.minY, panel.syncRow.frame.maxY + SiteSettingsPanel.groupGap)
        XCTAssertLessThan(panel.autoplayRow.frame.maxY+60, panel.bounds.height)
        XCTAssertEqual(panel.autoplayRow.toggle.onTintColor, panel.syncRow.toggle.onTintColor)
        panel.autoplayRow.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(policy.allowsAutoplay)
        panel.autoplayRow.toggle.setOn(true, animated: false)
        panel.autoplayRow.toggle.sendActions(for: .valueChanged)
        XCTAssertTrue(policy.allowsAutoplay)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "Autoplay videos setting"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testInitialBlankFramesAndClonedVideosInheritThePolicy() async throws {
        let (policy, suite) = try policy()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        policy.setAllowsAutoplay(false)
        let browser = BrowserViewController(startURL: nil, videoPlayback: policy)
        let window = try host(browser); defer { window.isHidden = true }
        let page = browser.webView, src = try videoURL
        page.loadHTMLString("""
        <body><script>
        window.frame = document.createElement('iframe');
        document.body.append(frame);
        window.frameVideo = frame.contentDocument.createElement('video');
        frameVideo.muted = true; frameVideo.autoplay = true; frameVideo.src = '\(src)';
        frame.contentDocument.body.append(frameVideo);
        frameVideo.play().then(() => window.frameResult='played', e => window.frameResult=e.name);
        const template = document.createElement('template');
        template.innerHTML = '<video muted autoplay src="\(src)"></video>';
        window.clone = template.content.firstChild.cloneNode(true);
        document.body.append(clone);
        clone.play().then(() => window.cloneResult='played', e => window.cloneResult=e.name);
        </script>
        """, baseURL: nil)
        try await wait("window.frameResult === 'NotAllowedError' && window.cloneResult === 'NotAllowedError'", in: page)
        try await wait("frameVideo.playsInline && clone.playsInline && frameVideo.paused && clone.paused", in: page)
    }
}
