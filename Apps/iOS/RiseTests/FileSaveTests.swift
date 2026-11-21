import UIKit
import WebKit
import XCTest
@testable import RiseiOS

final class FileSaveTests: XCTestCase {
    func testOnlyFilesWebKitShowsByThemselvesCanBeSavedWithTheirNames() throws {
        let mp3 = URL(string: "https://dts.podtrac.com/redirect.mp3/dovetail.prxu.org/SongExploder131_BlackPanther_DT.mp3")!
        let audio = try XCTUnwrap(FileDocument(url: mp3, mimeType: "audio/mpeg"))
        XCTAssertEqual(audio.kind, .audio)
        XCTAssertEqual(audio.filename, "SongExploder131_BlackPanther_DT.mp3")
        XCTAssertEqual(FileDocument(url: mp3, mimeType: "Video/MP4; codecs=avc1")?.kind, .video)
        XCTAssertEqual(FileDocument(url: mp3, mimeType: "application/pdf")?.kind, .pdf)
        XCTAssertEqual(FileDocument(url: mp3, mimeType: "image/jpeg")?.kind, .image)
        for type in ["text/html", "image/svg+xml", "application/vnd.apple.mpegurl", "audio/x-mpegurl",
                     "application/dash+xml", "text/plain", "", "application/octet-stream"] {
            XCTAssertNil(FileDocument(url: mp3, mimeType: type), type)
        }
        XCTAssertNil(FileDocument(url: URL(string: "file:///tmp/a.mp3")!, mimeType: "audio/mpeg"), "Only pages from the web")
        let stream = try XCTUnwrap(FileDocument(url: URL(string: "https://example.com/stream")!, mimeType: "audio/mpeg"))
        XCTAssertEqual(stream.filename, "stream.mp3", "A name without an extension gets its type's")
        let named = try XCTUnwrap(FileDocument(url: mp3, mimeType: "audio/mpeg", suggestedFilename: "Song: Exploder.mp3"))
        XCTAssertEqual(named.filename, "Song- Exploder.mp3", "The server's name, cleaned as downloads' are")
    }

    @MainActor private func host(_ browser: BrowserViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true; previous?.makeKey() }
        return window
    }

    /// The toast offering the page's file, not one leaving.
    @MainActor private func offeredToast(in browser: BrowserViewController) -> FileSaveToast? {
        (browser.toast as? FileSaveToast).flatMap { $0.dismissed ? nil : $0 }
    }

    @MainActor private func waitForToast(in browser: BrowserViewController, _ condition: (FileSaveToast) -> Bool = { _ in true },
                                         file: StaticString = #filePath, line: UInt = #line) async throws -> FileSaveToast {
        for _ in 0..<500 {
            if let toast = browser.toast as? FileSaveToast, !toast.dismissed, condition(toast) { return toast }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(browser.toast as? FileSaveToast, "No Save to Files toast", file: file, line: line)
    }

    /// The browser, its picker replaced by one that hands back each file it's given.
    @MainActor private func browser(for path: String, fixture: AdBlockHTTPFixture,
                                    picked: @escaping (URL, @escaping @MainActor (URL?) -> Void) -> Void) throws -> (BrowserViewController, UIWindow) {
        let browser = BrowserViewController(startURL: fixture.url.appendingPathComponent(path))
        browser.fileSavePickerOverride = picked
        return (browser, try host(browser))
    }

    @MainActor func testMP3PageSavesItsFileWhereThePickerSaysAndOffersItAgainAfterReload() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        // The checks run in the app itself: put back where its real saves go.
        let remembered = UserDefaults.standard.object(forKey: FileSaveLocation.key)
        addTeardownBlock { UserDefaults.standard.set(remembered, forKey: FileSaveLocation.key) }
        var offered: [(URL, Data?)] = [], answer: (@MainActor (URL?) -> Void)?
        let (browser, window) = try browser(for: "files/episode.mp3", fixture: fixture) { file, finished in
            offered.append((file, try? Data(contentsOf: file))); answer = finished
        }
        let toast = try await waitForToast(in: browser)
        XCTAssertEqual(toast.label.text, "Save to Files")
        XCTAssertEqual(toast.document.kind, .audio)
        XCTAssertEqual(toast.symbol.symbolName, FileSaveToast.offerGlyph, "Its one icon, the download arrow")
        XCTAssertEqual(UIImage(named: "ToastSaveFile")?.size, CGSize(width: 20, height: 20), "A little smaller than Open App Store's")
        XCTAssertTrue(toast.trailingIcon.isHidden)
        XCTAssertTrue(toast.isActionable)
        window.layoutIfNeeded(); browser.view.layoutIfNeeded(); toast.layoutIfNeeded()
        XCTAssertLessThan(toast.frame.maxY, browser.bottomBar.frame.minY)
        XCTAssertEqual(toast.label.frame.minX, 22, "No icon at the start")
        XCTAssertGreaterThanOrEqual(toast.symbol.frame.minX, toast.label.frame.maxX, "The icon is at the end, past the text")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: browser.view.bounds).image { context in
            browser.view.layer.render(in: context.cgContext)
        })
        attachment.name = "Save to Files toast on an MP3"; attachment.lifetime = .keepAlways
        add(attachment)

        toast.activate()
        XCTAssertEqual(toast.activationFeedbackCount, 1)
        XCTAssertEqual(toast.phase, .downloading)
        XCTAssertEqual(toast.label.text, "Downloading…")
        XCTAssertEqual(toast.symbol.symbolName, "file-save-downloading", "The arrow turns into a spinner")
        XCTAssertFalse(toast.isActionable, "A press while it downloads does nothing")
        for _ in 0..<500 where offered.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let (file, contents) = try XCTUnwrap(offered.first)
        XCTAssertEqual(file.lastPathComponent, "episode.mp3")
        XCTAssertEqual(contents, AdBlockHTTPFixture.fileBytes, "The picker is given the whole file")
        XCTAssertEqual(toast.phase, .ready, "Behind the picker, it offers the file again for a Cancel")

        let destination = FileManager.default.temporaryDirectory.appending(path: "Picked/episode.mp3")
        answer?(destination)
        XCTAssertEqual(toast.phase, .saved)
        XCTAssertEqual(toast.label.text, "Saved to Files")
        XCTAssertEqual(toast.symbol.symbolName, "file-save-saved")
        XCTAssertEqual(FileSaveLocation.folder?.standardizedFileURL.path, destination.deletingLastPathComponent().standardizedFileURL.path,
                       "The next save starts where this one went")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "The downloaded copy goes once it's saved")
        browser.updatePageToast()
        XCTAssertTrue(browser.toast === toast, "Saved stays to say so")
        toast.dismiss(animated: false)
        browser.updatePageToast()
        XCTAssertNil(browser.toast, "A saved file isn't offered again")

        browser.webView.reload()
        let again = try await waitForToast(in: browser)
        XCTAssertFalse(again === toast)
        XCTAssertEqual(again.phase, .ready, "Reloading offers it again")
    }

    @MainActor func testCancelledPickerOffersTheSameDownloadAgainWithoutFetchingItTwice() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        var offered: [URL] = []
        let (browser, window) = try browser(for: "files/clip.mp4", fixture: fixture) { file, finished in
            offered.append(file); finished(nil)
        }
        let toast = try await waitForToast(in: browser)
        XCTAssertEqual(toast.document.kind, .video)
        toast.activate()
        for _ in 0..<500 where offered.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(offered.count, 1)
        XCTAssertEqual(toast.phase, .ready)
        XCTAssertEqual(toast.label.text, "Save to Files")
        let requests = fixture.requestCount(for: "/files/clip.mp4")
        toast.activate()
        XCTAssertEqual(offered.count, 2, "The file already downloaded goes straight to the picker")
        XCTAssertEqual(offered.last, offered.first)
        XCTAssertEqual(fixture.requestCount(for: "/files/clip.mp4"), requests)
        withExtendedLifetime(window) {}
    }

    @MainActor func testServersNameIsKept() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        var offered: [URL] = []
        let (browser, window) = try browser(for: "files/named", fixture: fixture) { file, finished in
            offered.append(file); finished(nil)
        }
        let toast = try await waitForToast(in: browser)
        toast.activate()
        for _ in 0..<500 where offered.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(offered.first?.lastPathComponent, "Song Exploder.mp3")
        withExtendedLifetime(window) {}
    }

    @MainActor func testFailedDownloadSaysSoAndAPressTriesAgain() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        var offered = 0
        let (browser, window) = try browser(for: "files/flaky.mp3", fixture: fixture) { _, finished in
            offered += 1; finished(nil)
        }
        let toast = try await waitForToast(in: browser)
        toast.activate()
        for _ in 0..<500 where toast.phase != .failed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(toast.phase, .failed)
        XCTAssertEqual(toast.label.text, "Couldn’t download")
        XCTAssertTrue(toast.isActionable, "A press tries again")
        XCTAssertNil(browser.fileDocuments.state(for: browser.webView)?.save)
        toast.activate()
        XCTAssertEqual(toast.phase, .downloading)
        for _ in 0..<500 where toast.phase != .failed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(offered, 0)
        for _ in 0..<250 where toast.phase == .failed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(toast.phase, .ready, "It offers the file again after a moment")
        withExtendedLifetime(window) {}
    }

    @MainActor func testSwipedAwayStaysGoneUntilReloadAndShareSheetSaveBringsItBack() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        var offered = 0
        let (browser, window) = try browser(for: "files/episode.mp3", fixture: fixture) { _, finished in
            offered += 1; finished(nil)
        }
        let toast = try await waitForToast(in: browser)
        toast.beginDrag(); toast.trackDrag(CGPoint(x: 0, y: 90)); toast.endDrag(velocity: CGPoint(x: 0, y: 1800))
        XCTAssertTrue(toast.dismissed)
        browser.updatePageToast()
        XCTAssertNil(offeredToast(in: browser), "Swiped away, it stays away for this page")
        XCTAssertNotNil(browser.fileDocuments.document(for: browser.webView), "The share sheet still offers Save to Files")

        // The share sheet's Save to Files, once the sheet has gone.
        browser.saveFile(on: browser.webView)
        let shown = try XCTUnwrap(browser.toast as? FileSaveToast, "Saving from the share sheet shows its progress")
        XCTAssertEqual(shown.phase, .downloading)
        for _ in 0..<500 where offered == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(offered, 1)

        shown.dismissByUser()
        browser.updatePageToast()
        XCTAssertNil(offeredToast(in: browser))
        browser.webView.reload()
        let back = try await waitForToast(in: browser)
        XCTAssertEqual(back.phase, .ready, "A reload offers it again")
        withExtendedLifetime(window) {}
    }

    @MainActor func testSwipeDuringDownloadCancelsIt() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        var offered = 0
        let (browser, window) = try browser(for: "files/episode.mp3", fixture: fixture) { _, finished in
            offered += 1; finished(nil)
        }
        let toast = try await waitForToast(in: browser)
        toast.activate()
        XCTAssertNotNil(browser.fileDocuments.state(for: browser.webView)?.save)
        toast.dismissByUser()
        XCTAssertNil(browser.fileDocuments.state(for: browser.webView)?.save, "Swiping it away stops the download")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(offered, 0)
        withExtendedLifetime(window) {}
    }

    @MainActor func testBackForwardCacheDocumentIsAskedWhatItIs() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let (browser, window) = try browser(for: "files/episode.mp3", fixture: fixture) { _, finished in finished(nil) }
        _ = try await waitForToast(in: browser)
        // A commit with no response, as from the back-forward cache.
        var changed = false
        browser.fileDocuments.didCommit(browser.webView) { changed = true }
        XCTAssertNil(browser.fileDocuments.document(for: browser.webView))
        for _ in 0..<250 where !changed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(changed)
        XCTAssertEqual(browser.fileDocuments.document(for: browser.webView)?.mimeType, "audio/mpeg")
        withExtendedLifetime(window) {}
    }

    @MainActor func testOrdinaryPagesOfferNothing() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let (browser, window) = try browser(for: "", fixture: fixture) { _, finished in finished(nil) }
        for _ in 0..<250 where browser.webView.url == nil || browser.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(browser.fileDocuments.document(for: browser.webView))
        XCTAssertFalse(browser.toast is FileSaveToast)
        withExtendedLifetime(window) {}
    }

    @MainActor func testToastSitsUnderTheDimmingOfAnOpenPanel() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let (browser, window) = try browser(for: "files/episode.mp3", fixture: fixture) { _, finished in finished(nil) }
        let toast = try await waitForToast(in: browser)
        let subviews = browser.view.subviews
        let dimming = try XCTUnwrap(subviews.first { $0 is PanelDimming })
        XCTAssertLessThan(try XCTUnwrap(subviews.firstIndex(of: toast)), try XCTUnwrap(subviews.firstIndex(of: dimming)),
                          "The panel's dimming tints the toast as it does the page")
        XCTAssertLessThan(try XCTUnwrap(subviews.firstIndex(of: toast)), try XCTUnwrap(subviews.firstIndex(of: browser.bottomBar)))
        window.layoutIfNeeded()
        let centre = toast.convert(CGPoint(x: toast.bounds.midX, y: toast.bounds.midY), to: browser.view)
        XCTAssertTrue(browser.view.hitTest(centre, with: nil)?.isDescendant(of: toast) == true, "With no panel, it takes its own taps")
        browser.openPanel(.menu)
        for _ in 0..<100 where dimming.alpha < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(dimming.alpha, 1)
        browser.view.layoutIfNeeded()
        let raised = toast.convert(CGPoint(x: toast.bounds.midX, y: toast.bounds.midY), to: browser.view)
        XCTAssertTrue(browser.view.hitTest(raised, with: nil)?.isDescendant(of: toast) == true, "The tinted toast still takes its own taps")
        let page = CGPoint(x: browser.view.bounds.midX, y: browser.view.safeAreaInsets.top+40)
        XCTAssertTrue(browser.view.hitTest(page, with: nil) === dimming, "A tap on the page beside it closes the panel")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: browser.view.bounds).image { context in
            browser.view.layer.render(in: context.cgContext)
        })
        attachment.name = "Save to Files toast dimmed behind More"; attachment.lifetime = .keepAlways
        add(attachment)
        // Pressed there, it closes the panel first, for the Files picker.
        (toast as? FileSaveToast)?.pressButton.sendActions(for: .primaryActionTriggered)
        for _ in 0..<100 where dimming.alpha > 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(browser.isPanelOpen, "Saving closes the panel the toast was tapped over")
        browser.fileDocuments.dismiss(for: browser.webView)
    }
}
