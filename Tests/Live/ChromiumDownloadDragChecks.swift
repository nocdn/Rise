// Dragging a finished download out of the Downloads popover, in a real Rise window: the file goes
// on the drag as a file, as a copy only, and a real drag of it onto a page's drop zone arrives
// there as that file. Set RISE_DRAG_POINTS to a path, and something outside has to do the dragging
// (a program can't post a real drag of its own without Accessibility): the row's and the drop
// zone's screen points are written there, and the check waits for the drop.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumDownloadDragChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumDownloadDragMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL Download drag checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ChromiumDownloadDragRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumDownloadDragRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ description: String) {
        print(condition ? "PASS" : "FAIL", description); if !condition { failures += 1 }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await run()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func wait(_ seconds: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }
    func run() async {
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        // A file, and the list's record of it, as if it had downloaded.
        let session = folder.appendingPathComponent("drag-session", isDirectory: true)
        try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let file = session.appendingPathComponent("Dragged Picture.png")
        let picture = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        let bytes = NSBitmapImageRep(data: picture.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try? bytes.write(to: file)
        let inProgress = session.appendingPathComponent("Missing.zip")
        try? JSONEncoder().encode([DownloadRecord(path: file.path), DownloadRecord(path: inProgress.path)]).write(to: session.appendingPathComponent("downloads.json"))
        try? """
        <!doctype html><title>Drop</title><body style='margin:0;height:100vh;background:#eef'>Drop here<script>
        var dropped = null, over = 0;
        addEventListener('dragover', e => { e.preventDefault(); over++ });
        addEventListener('drop', e => { e.preventDefault();
          const f = e.dataTransfer.files[0];
          dropped = f ? {name: f.name, size: f.size, type: f.type, effect: e.dataTransfer.effectAllowed, types: [...e.dataTransfer.types]} : {types: [...e.dataTransfer.types]} });
        </script>
        """.write(to: folder.appendingPathComponent("drop.html"), atomically: true, encoding: .utf8)
        let browser = BrowserController(sessionURL: session.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: "rise-download-drag-\(UUID())")!)
        browser.window?.setContentSize(NSSize(width: 1200, height: 800)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let tab = browser.addTab(url: URL(string: "http://127.0.0.1:\(port)/drop.html")!)
        check(await wait(15) { tab.page.title == "Drop" }, "The page with a drop zone loads")
        browser.showDownloads()
        var rows: [DownloadRow] = []
        check(await wait(5) {
            rows = (browser.downloadsPopover.contentViewController as? DownloadsController)?.rows ?? []
            return browser.downloadsPopover.isShown && rows.count == 1 && rows[0].window != nil
        }, "The popover lists the finished download")
        guard let row = rows.first else { return }
        check(row.canDragFile, "It can be dragged")
        check(!DownloadRow(item: DownloadList.Item(record: DownloadRecord(path: file.path), progress: Progress(totalUnitCount: 10))).canDragFile, "One still downloading can't")
        check(!DownloadRow.isDrag(from: .zero, to: NSPoint(x: 2, y: 2)) && DownloadRow.isDrag(from: .zero, to: NSPoint(x: 4, y: 0)), "A press only becomes a drag once the pointer moves")

        guard let path = ProcessInfo.processInfo.environment["RISE_DRAG_POINTS"] else { print("SKIP The real drag: RISE_DRAG_POINTS isn't set"); return }
        // Screen points, from the top of the main display, as input tools take them.
        let height = NSScreen.screens[0].frame.height
        func screen(_ view: NSView, _ point: NSPoint) -> [String: Int] {
            let inScreen = view.window!.convertPoint(toScreen: view.convert(point, to: nil))
            return ["x": Int(inScreen.x), "y": Int(height-inScreen.y)]
        }
        let page = tab.page.view
        let from = screen(row, NSPoint(x: row.bounds.midX, y: row.bounds.midY))
        let to = screen(page, NSPoint(x: 120, y: page.isFlipped ? page.bounds.height-120 : 120))
        let points = ["from": from, "to": to]
        try? JSONSerialization.data(withJSONObject: points).write(to: URL(fileURLWithPath: path))
        print("  Drag from \(from) to \(to)")
        var result: [String: Any]?
        let arrived = await wait(45) {
            result = (try? await tab.page.evaluate("return dropped", arguments: [:], in: nil, world: .page)) as? [String: Any]
            return result != nil
        }
        check(arrived, "The page gets the drop")
        print("  Dropped:", result ?? [:])
        check(result?["name"] as? String == file.lastPathComponent, "As the file, under its name")
        check((result?["size"] as? NSNumber)?.intValue == bytes.count, "With its bytes")
        check(result?["type"] as? String == "image/png", "And its type")
        check(FileManager.default.fileExists(atPath: file.path), "The download stays where it was")
        check(browser.downloads.visible.contains { $0.record.path == file.path }, "And on the list")
    }
}
