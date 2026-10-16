#if DEBUG
import UIKit

/// Replays the existing return spring and samples the exposed bottom edge at its peak.
@MainActor enum SummariseBarAudit {
    static let argument = "-RiseSummariseBarAudit"
    struct Failure: Error { let name: String }

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("SummariseBarAudit")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let checks = try await exercise(browser, folder: folder)
                let failed = checks.filter { !$0.value }.keys.sorted()
                try (failed.isEmpty ? "Passed" : failed.joined(separator: "\n"))
                    .write(to: folder.appendingPathComponent(failed.isEmpty ? "done.txt" : "failure.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    static func exercise(_ browser: BrowserViewController, folder: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:], measurements: [[String: Any]] = []
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
        }
        browser.webView.loadHTMLString("<meta name='viewport' content='width=device-width'><title>Bar coverage</title><style>html,body{margin:0;background:#fc0084;min-height:200vh}</style><h1>Local bar coverage fixture</h1>", baseURL: URL(string: "https://bar-audit.invalid/"))
        for _ in 0..<200 where browser.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        for style: UIUserInterfaceStyle in [.light, .dark] {
            browser.overrideUserInterfaceStyle = style
            for collapsed in [false, true] {
                for revealed in [false, true] where revealed || !collapsed {
                    let name = "\(style == .dark ? "dark" : "light")-\(collapsed ? "collapsed" : "full")-\(revealed ? "summary" : "loading")"
                    browser.setBottomBarCollapsed(collapsed, animated: false)
                    browser.view.layoutIfNeeded()
                    let anchor = CGPoint(x: browser.view.bounds.midX, y: browser.view.bounds.midY)
                    browser.startSummarise(.pinch, at: anchor)
                    guard let scene = browser.summarise else { throw Failure(name: name+" did not start") }
                    scene.makeSummary = {
                        if revealed { return SummariseReplay.summary }
                        try await Task.sleep(for: .seconds(60))
                        throw CancellationError()
                    }
                    scene.manualTime = 0
                    scene.beginPinch(at: anchor)
                    scene.updatePinch(scale: 0.65, centroid: anchor)
                    scene.endPinch(cancelled: false)
                    if revealed { try await Task.sleep(for: .milliseconds(500)) }
                    let distance = browser.bottomBar.bounds.height+4
                    var exitOffsets: [CGFloat] = []
                    for step in 0...4 {
                        scene.advance(to: 0.18*Double(step)/4)
                        exitOffsets.append(browser.bottomBar.transform.ty)
                    }
                    let advances = zip(exitOffsets.dropFirst(), exitOffsets).map { $0-$1 }
                    try check(name+"-exit-decelerates-without-reversing", advances.allSatisfy { $0 > 0 }
                              && zip(advances.dropFirst(), advances).allSatisfy { $0 < $1 })
                    try check(name+"-exit-keeps-180ms-duration", abs(exitOffsets[4]-distance) < 0.01
                              && exitOffsets[3] < distance-0.01)
                    for step in 22...420 { scene.advance(to: Double(step)/120) }
                    try check(name+"-requested-state", scene.isRevealed == revealed)
                    try check(name+"-bar-leaves-fully", abs(browser.bottomBar.transform.ty-distance) < 0.01)
                    let closedAt = 3.5
                    scene.manualTime = closedAt
                    scene.close()
                    var worstDeviation: CGFloat = 0, peakGap: CGFloat = 0
                    var peakColors: [[Int]] = []
                    // The baseline spring is response 0.27, bounce 0.25; keep its full curve.
                    let spring = SummariseSpring(2*Double.pi/0.27, 0.75)
                    for step in 0...180 {
                        let elapsed = Double(step)/240
                        scene.advance(to: closedAt+elapsed)
                        let expected = CGFloat(1-spring(elapsed))*distance
                        worstDeviation = max(worstDeviation, abs(browser.bottomBar.transform.ty-expected))
                        peakGap = max(peakGap, browser.view.bounds.maxY-browser.bottomBar.frame.maxY)
                        if step == 49 {
                            let format = UIGraphicsImageRendererFormat()
                            format.scale = browser.view.traitCollection.displayScale
                            let image = UIGraphicsImageRenderer(bounds: browser.view.bounds, format: format).image { _ in
                                browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true)
                            }
                            try image.pngData()?.write(to: folder.appendingPathComponent(name+"-peak.png"))
                            let expected = BottomBar.background.resolvedColor(with: browser.view.traitCollection)
                            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                            expected.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                            let target = [red, green, blue].map { Int(($0*255).rounded()) }
                            for x: CGFloat in [0.15, 0.5, 0.85] {
                                peakColors.append(try pixel(image, at: CGPoint(x: x*image.size.width, y: image.size.height-1/image.scale)))
                            }
                            try check(name+"-bottom-edge-stays-bar-coloured", peakColors.allSatisfy { color in
                                zip(color.prefix(3), target).allSatisfy { abs($0-$1) <= 2 } && color[3] == 255
                            })
                        }
                    }
                    try check(name+"-keeps-the-original-bounce", peakGap > 0.4 && worstDeviation < 0.02)
                    try check(name+"-finishes-at-the-original-position", browser.summarise == nil && browser.bottomBar.transform == .identity)
                    measurements.append(["case": name, "peakGapPoints": peakGap, "maxCurveDeviationPoints": worstDeviation, "bottomPixels": peakColors])
                    scene.finish()
                }
            }
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("measurements.json"))
        return checks
    }

    private static func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        guard let source = image.cgImage?.cropping(to: CGRect(x: floor(point.x*image.scale), y: floor(point.y*image.scale), width: 1, height: 1)) else {
            throw Failure(name: "missing pixel")
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        guard drew else { throw Failure(name: "pixel decoder unavailable") }
        return bytes.map(Int.init)
    }
}
#endif
