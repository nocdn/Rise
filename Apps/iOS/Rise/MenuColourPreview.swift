#if DEBUG
import UIKit

/// Captures the real menu with eight colour assignments, without altering saved tabs.
@MainActor enum MenuColourPreview {
    static let argument = "-RiseMenuColourPreview"

    // Share, Summarise, Find on Page, Copy Link. Each colour appears twice per action.
    private static let combinations: [[UIColor]] = [
        [.systemBlue, .systemPurple, .systemRed, .systemGreen],
        [.systemRed, .systemGreen, .systemBlue, .systemPurple],
        [.systemGreen, .systemRed, .systemPurple, .systemBlue],
        [.systemPurple, .systemBlue, .systemGreen, .systemRed],
        [.systemBlue, .systemGreen, .systemPurple, .systemRed],
        [.systemRed, .systemPurple, .systemGreen, .systemBlue],
        [.systemGreen, .systemBlue, .systemRed, .systemPurple],
        [.systemPurple, .systemRed, .systemBlue, .systemGreen],
    ]

    static func run(in browser: BrowserViewController) {
        Task {
            do {
                let folder = URL.cachesDirectory.appendingPathComponent("MenuColourPreview")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = await SummariseReplay.openMore(in: browser)
                try await Task.sleep(for: .milliseconds(700))
                guard let window = browser.view.window else { return }
                let top = max(0, browser.bottomBar.frame.minY-90)
                let region = CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.height-top)
                let menu = browser.bottomBar.menu
                let save = { (name: String) throws in
                    let image = UIGraphicsImageRenderer(bounds: region).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: folder.appendingPathComponent(name+".png"), options: .atomic)
                }
                if ProcessInfo.processInfo.arguments.contains("-selected") {
                    try save("selected")
                    try "Captured the selected menu colours.\n".write(
                        to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
                    return
                }
                for tile in menu.tiles { tile.setIconColor(.label) }
                try await Task.sleep(for: .milliseconds(120))
                try save("before")
                for (index, colours) in combinations.enumerated() {
                    for (tile, colour) in zip(menu.tiles, colours) { tile.setIconColor(colour) }
                    try await Task.sleep(for: .milliseconds(120))
                    try save("after-\(index+1)")
                }
                for (tile, colour) in zip(menu.tiles, combinations[0]) { tile.setIconColor(colour) }
                try "Captured before and eight colour combinations.\n".write(
                    to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                print("Rise.MenuColourPreview: \(error)")
            }
        }
    }
}
#endif
