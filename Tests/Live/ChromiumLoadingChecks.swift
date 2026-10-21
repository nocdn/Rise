// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumLoadingChecks.swift
import AppKit
import RiseChromium
@testable import Rise

@main @MainActor struct ChromiumLoadingMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+60) { print("FAIL loading checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = LoadingRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class LoadingRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ name: String) {
        print(value ? "PASS" : "FAIL", name)
        if !value { failures += 1 }
    }
    func wait(_ name: String, until ready: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !(await ready()), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        check(await ready(), name)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await exercise() } catch { check(false, String(describing: error)) }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func exercise() async throws {
        let suite = "RiseLoadingChecks-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")
        let site = "http://localhost:\(ports[0])", other = "http://127.0.0.1:\(ports[1])"
        let html = """
        <!doctype html><title>Scroll loading fixture</title><body style="height:20000px">
        <h1>Scroll without restarting the tab's loading indicator</h1>
        <script>
        window.framesLoaded = 0; window.framesRequested = 0;
        addEventListener('scroll', () => {
          const frame = document.createElement('iframe');
          const n = ++window.framesRequested;
          frame.src = (n % 2 ? '\(site)' : '\(other)') + '/embedded.html?frame=' + n;
          frame.onload = () => window.framesLoaded++;
          document.body.append(frame);
        });
        </script>
        """
        try html.write(to: folder.appendingPathComponent("scroll.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Embedded page</title>Lazy content".write(to: folder.appendingPathComponent("embedded.html"), atomically: true, encoding: .utf8)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
        browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let tab = browser.addTab(), page = tab.page
        var starts = 0, wasLoading = false, sweepStarts = 0, wasSweeping = false
        let changed = tab.onChange
        tab.onChange = {
            changed?()
            if tab.isLoading && !wasLoading { starts += 1 }
            wasLoading = tab.isLoading
            let sweeping = browser.sidebar.rows[tab.id]?.loadingBackground.loading == true
            if sweeping && !wasSweeping { sweepStarts += 1 }
            wasSweeping = sweeping
        }
        func value(_ body: String) async -> Any? { try? await page.evaluate(body, arguments: [:], in: nil, world: .page) }
        let url = URL(string: site+"/scroll.html")!
        tab.load(url)
        try await wait("Initial navigation finishes") {
            guard page.url == url, !page.isLoading else { return false }
            return (await value("return document.readyState")) as? String == "complete"
        }
        check(starts > 0 && sweepStarts > 0, "Real navigation starts the tab loading sweep")
        let before = starts, sweepsBefore = sweepStarts
        for step in 1...6 {
            let expected = (await value("return window.framesLoaded")) as? Int ?? 0
            _ = await value("window.scrollTo(0, \(step % 2 == 0 ? 100 : 1500)); return true")
            try await wait("Scroll \(step) really loads embedded content") { (await value("return window.framesLoaded")) as? Int ?? 0 > expected }
            try await Task.sleep(for: .milliseconds(70))
        }
        let scrollStarts = starts-before, scrollSweeps = sweepStarts-sweepsBefore
        print("OBSERVED scroll-triggered loading starts:", scrollStarts, "sweeps:", scrollSweeps)
        check(starts == before, "Scrolling and same/cross-origin frame loads do not mark the tab as loading")
        check(sweepStarts == sweepsBefore, "Scrolling never restarts the sidebar loading gradient")
        let beforeSameDocument = starts
        _ = await value("history.pushState({}, '', '#reading'); return true")
        try await Task.sleep(for: .milliseconds(150))
        check(starts == beforeSameDocument, "Same-document history changes do not start loading UI")
        let beforeRoute = starts
        _ = await value("""
        window.routeDone = false;
        navigation.addEventListener('navigate', event => {
          if (new URL(event.destination.url).hash !== '#route') return;
          event.intercept({handler: async () => {
            await new Promise(resolve => setTimeout(resolve, 900));
            window.routeDone = true;
          }});
        }, {once:true});
        navigation.navigate('#route'); return true;
        """)
        try await wait("A slow Navigation API route requests loading UI") { starts > beforeRoute }
        try await wait("The route loading UI clears on completion") {
            guard !page.isLoading else { return false }
            return (await value("return window.routeDone")) as? Bool == true
        }
        let beforeReload = starts
        page.reload()
        try await wait("Normal reload still starts and completes its loading sweep") { starts > beforeReload && !page.isLoading }
        let afterReload = starts
        tab.isHardReloading = true; page.reloadIgnoringCache()
        try await wait("Hard reload still starts and completes its loading sweep") { starts > afterReload && !page.isLoading }
        check(!tab.isHardReloading, "Hard reload state clears on completion")
        let beforeNavigation = starts
        tab.load(URL(string: site+"/embedded.html")!)
        try await wait("A new top-level navigation still shows loading UI") { starts > beforeNavigation && !page.isLoading }
        page.goBack()
        try await wait("Back navigation still finishes normally") { !page.isLoading && page.url?.lastPathComponent == "scroll.html" }
        try JSONSerialization.data(withJSONObject: ["failures":failures, "scrollLoadingStarts":scrollStarts, "scrollSweeps":scrollSweeps], options: [.prettyPrinted])
            .write(to: folder.appendingPathComponent("results.json"))
    }
}
