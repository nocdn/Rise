#if DEBUG
import CoreHaptics
import Network
import UIKit
import WebKit

/// Native progress animations and real WebKit transfers, without touching saved downloads.
@MainActor enum MenuDownloadsAudit {
    struct Failure: Error { let name: String }
    static func exercise(_ browser: BrowserViewController, folder: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys])
                .write(to: folder.appendingPathComponent("downloads-history-checks.json"))
            if !valid { throw Failure(name: name) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<400 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure(name: "download timed out")
        }
        func item(_ received: Int64, _ total: Int64, _ state: MobileDownloads.State = .downloading) -> MobileDownloads.Item {
            let value = MobileDownloads.Item(url: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString), state: state)
            value.receivedBytes = received; value.totalBytes = total
            return value
        }
        let menu = browser.bottomBar.menu, progress = menu.downloadProgress
        let old = item(1_000, 1_000, .finished), first = item(25, 100), second = item(150, 300)
        var batch = MobileDownloadBatchProgress()
        try check("old-downloads-do-not-create-progress", batch.update([old]) == .idle)
        try check("all-active-downloads-have-byte-weighted-progress", batch.update([old,first,second]) == .running(fraction: 0.4375, count: 2))
        first.state = .finished; first.receivedBytes = 100
        try check("a-finished-file-keeps-its-share-until-the-batch-ends", batch.update([old,first,second]) == .running(fraction: 0.625, count: 1))
        second.state = .failed
        try check("failure-does-not-report-successful-completion", batch.update([old,first,second]) == .ended(successfully: false))
        try check("terminal-updates-do-not-restart-the-fade", batch.update([old,first,second]) == .idle)
        let unknown = item(90, 0), known = item(20, 100)
        try check("unknown-length-reserves-its-share-without-inventing-completion", batch.update([known,unknown]) == .running(fraction: 0.1, count: 2))
        try check("cancelling-a-transfer-releases-its-share", batch.update([known]) == .running(fraction: 0.2, count: 1))
        try check("removing-the-last-transfer-ends-without-success", batch.update([]) == .ended(successfully: false))
        let invalid = item(-30, 100)
        try check("negative-progress-is-clamped", batch.update([invalid]) == .running(fraction: 0, count: 1))
        invalid.receivedBytes = 400
        try check("excess-progress-is-clamped", batch.update([invalid]) == .running(fraction: 1, count: 1))

        let left = item(25, 100), right = item(75, 100)
        menu.updateDownloadProgress([left,right])
        try await Task.sleep(for: .milliseconds(300))
        let width = progress.bounds.width
        try check("button-fill-covers-only-the-completed-portion", abs(progress.fill.bounds.width-width*0.5) < 0.5 && progress.fill.frame.minX == 0)
        try check("progress-is-clipped-to-the-button-and-never-intercepts-touches", menu.downloadsButton.clipsToBounds
                  && progress.superview === menu.downloadsButton && !progress.isUserInteractionEnabled)
        let image = UIGraphicsImageRenderer(bounds: menu.bounds).image { _ in menu.drawHierarchy(in: menu.bounds, afterScreenUpdates: true) }
        try image.pngData()?.write(to: folder.appendingPathComponent("downloads-half.png"))
        left.receivedBytes = 95; right.receivedBytes = 95
        menu.updateDownloadProgress([left,right]); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(60))
        let movingWidth = progress.fill.layer.presentation()?.bounds.width ?? 0
        try check("progress-jumps-animate-through-intermediate-widths", movingWidth > width*0.5+1 && movingWidth < width*0.95-1)
        menu.downloadsButton.sendActions(for: .touchDown)
        try await Task.sleep(for: .milliseconds(100))
        try check("progress-keeps-the-normal-downloads-press-feedback", menu.downloadsButton.backgroundColor == SearchPanel.pressedFill
                  && abs(menu.downloadsButton.transform.a-MenuPanel.pressedScale) < 0.001)
        menu.downloadsButton.sendActions(for: .touchCancel)
        left.state = .finished; right.state = .finished
        menu.updateDownloadProgress([left,right])
        try await Task.sleep(for: .milliseconds(285))
        let fading = progress.layer.presentation()?.opacity ?? 0
        try check("completed-progress-fades-smoothly", fading > 0 && fading < 1)
        let fresh = item(30, 100)
        menu.updateDownloadProgress([left,right,fresh])
        try await Task.sleep(for: .milliseconds(350))
        try check("new-work-interrupts-completion-without-being-hidden", progress.alpha == 1 && abs(progress.fraction-0.3) < 0.001)
        fresh.state = .finished; fresh.receivedBytes = 100
        menu.updateDownloadProgress([left,right,fresh])
        try await Task.sleep(for: .milliseconds(500))
        try check("completed-button-returns-to-normal", progress.alpha == 0 && progress.fraction == 0 && progress.fill.bounds.width == 0
                  && menu.downloadsButton.accessibilityValue == nil)

        let pattern = try DownloadCompletionFeedback.pattern().exportDictionary()
        let events = (pattern[.pattern] as? [[String: Any]] ?? []).compactMap { $0["Event"] as? [String: Any] }
        let times = events.compactMap { $0["Time"] as? Double }
        try check("success-pattern-has-exactly-three-transient-pulses", events.count == 3 && events.allSatisfy { ($0["EventType"] as? String) == "HapticTransient" })
        try check("success-pulses-are-distinct-and-quick", times.count == 3 && times[0] == 0 && times[1] > 0.05
                  && times[2] > times[1]+0.05 && times[2] < 0.25)

        let directory = URL.temporaryDirectory.appendingPathComponent("RiseDownloadAudit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = MobileDownloads(directory: directory)
        defer { downloads.onListChange = nil; downloads.onProgress = nil; downloads.confirm = nil }
        let server = try DownloadHTTPFixture(); try await server.start()
        defer { server.stop() }
        let harness = DownloadHarness(downloads)
        downloads.confirm = { _,_,_,answer in answer(true) }
        var starts: [(UUID,CGPoint?)] = []
        downloads.onStart = { starts.append(($0.id,$1)) }
        var sawConcurrent = false, updates = 0
        downloads.onListChange = {
            sawConcurrent = sawConcurrent || downloads.items.filter { $0.state == .downloading }.count == 2
            menu.updateDownloadProgress(downloads.items)
        }
        downloads.onProgress = { _ in updates += 1; menu.updateDownloadProgress(downloads.items) }
        harness.start(server.url.appendingPathComponent("first.bin"), origin: CGPoint(x: 75,y: 310))
        harness.start(server.url.appendingPathComponent("second.bin"), origin: CGPoint(x: 225,y: 420))
        do { try await wait { downloads.items.count == 2 && downloads.items.allSatisfy { $0.state == .finished } } }
        catch {
            let state: [String: Any] = ["started": harness.started, "items": downloads.items.map {
                ["name": $0.name, "state": String(describing: $0.state), "received": $0.receivedBytes, "total": $0.totalBytes]
            }]
            try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("transfer-diagnostic.json"))
            throw error
        }
        try check("real-concurrent-webkit-downloads-update-the-button", sawConcurrent && updates >= 3)
        try check("accepted-transfers-each-request-exactly-one-flight", starts.count == 2 && Set(starts.map(\.0)).count == 2)
        try check("each-real-transfer-retains-its-own-touch-through-confirmation", starts.allSatisfy { id, origin in
            origin == (downloads.item(id)?.name == "first.bin" ? CGPoint(x: 75,y: 310) : CGPoint(x: 225,y: 420))
        })
        var declined = false
        downloads.confirm = { _,_,_,answer in declined = true; answer(false) }
        harness.start(server.url.appendingPathComponent("declined.bin"))
        try await wait { declined }
        try await Task.sleep(for: .milliseconds(200))
        try check("declining-confirmation-never-adds-a-row-or-starts-a-flight", starts.count == 2 && downloads.items.count == 2)
        downloads.confirm = { _,_,_,answer in answer(true) }
        try check("every-successful-download-requests-one-three-pulse-pattern", downloads.successFeedbackCount == 2)
        try check("real-files-have-their-complete-byte-counts", downloads.items.map(\.totalBytes).sorted() == [131_072,262_144]
                  && downloads.items.allSatisfy { $0.receivedBytes == $0.totalBytes && MobileDownloads.size(of: $0.url) == $0.totalBytes })
        let restored = MobileDownloads(directory: directory)
        try check("completed-files-persist-without-replaying-feedback", Set(restored.items.map(\.id)) == Set(downloads.items.map(\.id))
                  && restored.successFeedbackCount == 0)
        harness.start(server.url.appendingPathComponent("unknown.bin"))
        try await wait { downloads.items.first?.name == "unknown.bin" && downloads.items.first?.state == .finished }
        try check("unknown-length-download-completes-and-gets-feedback", downloads.items.first?.totalBytes == 65_536 && downloads.successFeedbackCount == 3)
        harness.start(server.url.appendingPathComponent("truncated.bin"))
        try await wait { downloads.items.first?.name == "truncated.bin" && downloads.items.first?.state == .failed }
        try check("failed-transfer-never-gets-success-feedback", downloads.successFeedbackCount == 3
                  && !FileManager.default.fileExists(atPath: downloads.items.first!.url.path))
        harness.start(server.url.appendingPathComponent("cancel.bin"))
        try await wait {
            guard let item = downloads.items.first, item.name == "cancel.bin", item.state == .downloading else { return false }
            return item.receivedBytes > 0 && MobileDownloads.size(of: item.url) > 0
        }
        let cancelled = downloads.items.first!
        try check("cancellation-test-has-real-partial-bytes-on-disk", MobileDownloads.size(of: cancelled.url) > 0
                  && MobileDownloads.size(of: cancelled.url) < cancelled.totalBytes)
        downloads.remove(cancelled.id)
        try await wait { downloads.pendingCancellationCount == 0 }
        try check("cancelling-deletes-the-partial-file", !FileManager.default.fileExists(atPath: cancelled.url.path))
        try await Task.sleep(for: .milliseconds(500))
        try check("cancelled-transfer-never-gets-success-feedback", downloads.item(cancelled.id) == nil && downloads.successFeedbackCount == 3)
        try check("cancelled-file-does-not-reappear-after-late-network-data", !FileManager.default.fileExists(atPath: cancelled.url.path))

        let listChanged = downloads.onListChange
        var cancelledBeforeDestination: MobileDownloads.Item?
        downloads.onListChange = {
            listChanged?()
            if let item = downloads.items.first, item.name == "early.bin", item.state == .downloading {
                cancelledBeforeDestination = item
                downloads.remove(item.id)
            }
        }
        harness.start(server.url.appendingPathComponent("early.bin"))
        try await wait { cancelledBeforeDestination != nil && downloads.pendingCancellationCount == 0 }
        downloads.onListChange = listChanged
        try await Task.sleep(for: .milliseconds(300))
        let early = cancelledBeforeDestination!
        try check("cancelling-before-destination-handoff-never-leaves-a-file", downloads.item(early.id) == nil
                  && !FileManager.default.fileExists(atPath: early.url.path) && downloads.successFeedbackCount == 3)
        try check("a-transfer-cancelled-before-start-never-flies", !starts.contains { $0.0 == early.id })

        let finishedFiles = downloads.items.filter { $0.state == .finished }.map(\.url)
        harness.start(server.url.appendingPathComponent("cancel.bin"))
        harness.start(server.url.appendingPathComponent("cancel.bin"))
        try await wait {
            let active = downloads.items.filter { $0.state == .downloading }
            return active.count == 2 && active.allSatisfy { MobileDownloads.size(of: $0.url) > 0 }
        }
        let partialFiles = downloads.items.filter { $0.state == .downloading }.map(\.url)
        try check("new-download-can-safely-reuse-a-cleaned-up-filename", partialFiles.contains(cancelled.url)
                  && Set(partialFiles).count == 2 && partialFiles.allSatisfy { MobileDownloads.size(of: $0) > 0 })
        downloads.removeAll()
        try await wait { downloads.pendingCancellationCount == 0 }
        try await Task.sleep(for: .milliseconds(500))
        try check("clearing-concurrent-downloads-deletes-every-partial-file", downloads.items.isEmpty
                  && partialFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } && downloads.successFeedbackCount == 3)
        let remainingFiles = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Downloads"),
                                                                        includingPropertiesForKeys: nil)
        try check("clearing-the-list-keeps-successfully-downloaded-files", finishedFiles.count == 3
                  && Set(remainingFiles) == Set(finishedFiles) && finishedFiles.allSatisfy { MobileDownloads.size(of: $0) > 0 })
        try check("real-terminal-transfers-leave-the-button-normal", progress.alpha == 0)

        browser.closePanel()
        try await Task.sleep(for: .milliseconds(400))
        browser.showTabSwitcher()
        try await Task.sleep(for: .milliseconds(200))
        browser.bottomBar.moreButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(400))
        let bar = browser.bottomBar, history = bar.tabMenu.historyButton
        try check("switcher-more-shows-only-incognito-mode-and-history", bar.panel == .tabMenu && bar.shown === bar.tabMenu
                  && bar.tabMenu.subviews.count == 2 && bar.menu.alpha == 0 && !bar.menu.isUserInteractionEnabled)
        try check("history-row-matches-the-address-row-geometry", history.bounds.size == bar.menu.address.bounds.size
                  && history.layer.cornerRadius == SearchPanel.cornerRadius && history.center.x == bar.menu.address.center.x)
        try check("history-uses-the-supplied-icon", MenuIcons.history != nil && history.accessibilityLabel == "History")
        let safeBottom = browser.view.window?.safeAreaInsets.bottom ?? 0
        try check("history-menu-uses-the-normal-sheet-animation-at-its-smaller-height", abs(bar.bounds.height-BottomBar.tabMenuHeight(safeBottom: safeBottom)) < 0.5)
        history.sendActions(for: .touchDown)
        try await Task.sleep(for: .milliseconds(150))
        try check("history-darkens-and-scales-like-a-normal-button", history.backgroundColor == SearchPanel.pressedFill
                  && abs(history.transform.a-MenuPanel.pressedScale) < 0.001)
        history.sendActions(for: .touchUpInside); history.sendActions(for: .primaryActionTriggered)
        try check("history-opens-the-saved-history-list-immediately", browser.isTabSwitcherOpen && browser.isPanelOpen
                  && bar.panel == .history && browser.presentedViewController == nil)
        bar.history.closeButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(450))
        try check("closing-history-restores-the-switcher-menu", browser.isTabSwitcherOpen && !browser.tabSwitcher.isHidden
                  && browser.isPanelOpen && bar.panel == .tabMenu && bar.shown === bar.tabMenu)
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(400))
        browser.selectTab(browser.tabIndex)
        try await Task.sleep(for: .milliseconds(850))
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(400))
        try check("page-more-still-shows-the-normal-menu", bar.panel == .menu && bar.shown === bar.menu && bar.tabMenu.alpha == 0)
        return checks
    }

    @MainActor private final class DownloadHarness {
        let downloads: MobileDownloads
        private(set) var started = 0
        private var pages: [WKWebView] = []
        init(_ downloads: MobileDownloads) { self.downloads = downloads }
        func start(_ url: URL, origin: CGPoint? = nil) {
            let page = WKWebView(); pages.append(page)
            page.startDownload(using: URLRequest(url: url)) { [weak self] download in
                self?.started += 1
                self?.downloads.begin(download, origin: origin)
            }
        }
    }
}

/// Known and unknown lengths, truncation and cancellation, served in real spaced TCP chunks.
final class DownloadHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.DownloadAudit.HTTP")
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.serve($0) }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data,_,_,_ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let route = request.split(separator: " ").dropFirst().first else { connection.cancel(); return }
            let name = String(route.dropFirst())
            let length = name == "first.bin" ? 131_072 : name == "second.bin" ? 262_144
                : name == "cancel.bin" ? 4_194_304 : name == "150MB-Live-Activity-Test.bin" ? 157_286_400 : 65_536
            let size = name == "unknown.bin" ? "" : "Content-Length: \(length)\r\n"
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\n\(size)Connection: close\r\n\r\n".utf8)
            connection.send(content: headers, completion: .contentProcessed { [weak self] error in
                guard error == nil else { connection.cancel(); return }
                self?.send(connection, remaining: name == "truncated.bin" ? 4096 : length,
                           delay: name == "first.bin" ? 0.045 : 0.065)
            })
        }
    }
    private func send(_ connection: NWConnection, remaining: Int, delay: Double) {
        guard remaining > 0 else { connection.cancel(); return }
        let count = min(8192, remaining)
        queue.asyncAfter(deadline: .now()+delay) { [weak self] in
            connection.send(content: Data(repeating: 42, count: count), completion: .contentProcessed { [weak self] error in
                guard error == nil else { connection.cancel(); return }
                self?.send(connection, remaining: remaining-count, delay: delay)
            })
        }
    }
}
#endif
