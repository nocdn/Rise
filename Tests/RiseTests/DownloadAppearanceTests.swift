import XCTest
import AppKit
@testable import Rise

final class DownloadAppearanceTests: XCTestCase {
    @MainActor func testImageAndPDFGetThumbnailsAndMissingFilesKeepTheirIcon() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        for y in 0..<80 { for x in 0..<120 { bitmap.setColor(red, atX: x, y: y) } }
        let png = folder.appendingPathComponent("image.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)
        let misnamedJPEG = folder.appendingPathComponent("jpeg-with-png-extension.png")
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: misnamedJPEG)
        let pdf = folder.appendingPathComponent("document.pdf")
        let document = NSTextField(labelWithString: "Thumbnail fixture")
        document.frame = NSRect(x: 0, y: 0, width: 180, height: 100)
        try document.dataWithPDF(inside: document.bounds).write(to: pdf)
        for file in [png, pdf, misnamedJPEG] {
            let list = DownloadList(storeURL: folder.appendingPathComponent("downloads.json"))
            let id = list.begin(file, progress: nil); list.finish(id)
            let row = DownloadRow(item: list.items[0])
            row.frame = NSRect(x: 0, y: 0, width: 288, height: 44)
            row.layoutSubtreeIfNeeded()
            let icon = try XCTUnwrap(row.subviews.compactMap { $0 as? DownloadFileIcon }.first)
            let deadline = Date().addingTimeInterval(10)
            while !icon.hasThumbnail && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(icon.hasThumbnail, "Quick Look should show the actual \(file.pathExtension) content")
            XCTAssertNotNil(icon.image)
            icon.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(icon.previewBounds.width, 24)
            XCTAssertNotNil(icon.layer?.mask, "Thumbnails must be cropped with rounded corners")
            if file != pdf {
                XCTAssertGreaterThan(icon.previewBounds.height, icon.previewBounds.width*icon.image!.size.height/icon.image!.size.width,
                                     "Wide previews are cropped at the sides, rather than shrunk to the width cap")
            }
            if file != pdf {
                let thumbnail = NSBitmapImageRep(cgImage: try XCTUnwrap(icon.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
                let center = try XCTUnwrap(thumbnail.colorAt(x: thumbnail.pixelsWide/2, y: thumbnail.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(center.redComponent, center.greenComponent+0.4, "The file icon must be replaced by the red image's content")
            }
        }
        let icon = DownloadFileIcon()
        icon.showFile(folder.appendingPathComponent("missing.png"))
        XCTAssertFalse(icon.hasThumbnail); XCTAssertNotNil(icon.image)
        // A late completion for an old file must not replace the new fallback.
        icon.showFile(png); icon.showFile(folder.appendingPathComponent("missing.bin"))
        let fallback = icon.image
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(icon.image === fallback); XCTAssertFalse(icon.hasThumbnail)
    }
    @MainActor func testDownloadUsesSharedSpringAndKeepsDisabledControlsInert() throws {
        _ = NSApplication.shared
        let list = DownloadList(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let id = list.begin(URL(fileURLWithPath: "/tmp/in-progress.bin"), progress: Progress(totalUnitCount: 100))
        let row = DownloadRow(item: list.items[0])
        row.frame = NSRect(x: 0, y: 0, width: 288, height: 44); row.layoutSubtreeIfNeeded()
        let fill = try XCTUnwrap(row.progressRing.layer?.sublayers?.last as? CAShapeLayer)
        XCTAssertEqual(fill.lineWidth, 2.5)
        XCTAssertEqual(try XCTUnwrap(fill.path).boundingBoxOfPath.width, 20, accuracy: 0.01)
        var presses = 0; row.togglePause = { _ in presses += 1 }
        XCTAssertTrue(row.pauseButton.accessibilityPerformPress()); XCTAssertEqual(presses, 1)
        list.setState(.pausing, for: id); row.update()
        XCTAssertFalse(row.pauseButton.accessibilityPerformPress()); XCTAssertEqual(presses, 1)
        XCTAssertTrue(row.pauseButton.paused)
    }
    @MainActor func testSymbolsKeepFullResolutionBitmapsThroughBothSpringDirections() throws {
        _ = NSApplication.shared
        let button = PlayPauseButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.pointSize = 11; button.weight = .regular; button.layoutSubtreeIfNeeded()
        let glyph = try XCTUnwrap(button.layer?.sublayers?.first)
        XCTAssertTrue(glyph.shouldRasterize, "Keep a consistent high-resolution surface during both spring transforms")
        XCTAssertGreaterThanOrEqual(glyph.rasterizationScale, 8)
        let symbols = try XCTUnwrap(glyph.sublayers)
        XCTAssertEqual(symbols.count, 2)
        let bitmaps: [CGImage] = try symbols.map {
            let contents = try XCTUnwrap($0.contents)
            XCTAssertEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID)
            return contents as! CGImage
        }
        for (layer, bitmap) in zip(symbols, bitmaps) {
            XCTAssertGreaterThanOrEqual(CGFloat(bitmap.width), layer.bounds.width*4)
            XCTAssertGreaterThanOrEqual(CGFloat(bitmap.height), layer.bounds.height*4)
            let pixels = NSBitmapImageRep(cgImage: bitmap)
            XCTAssertTrue((0..<pixels.pixelsHigh).contains { y in
                (0..<pixels.pixelsWide).contains { x in (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
            }, "Both symbols must contain opaque ink, including the initially hidden play icon")
        }
        for paused in [true, false, true, false] {
            button.setPaused(paused, animated: true)
            for (layer, bitmap) in zip(symbols, bitmaps) { XCTAssertTrue((layer.contents as AnyObject?) === bitmap) }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let spring = try XCTUnwrap(symbols[paused ? 0 : 1].animation(forKey: "swap.scale") as? CASpringAnimation)
                XCTAssertEqual(spring.stiffness, 700)
                XCTAssertEqual(spring.damping, 2*0.55*sqrt(700), accuracy: 0.01)
            }
        }
    }
    @MainActor func testSmartRenameShimmersTheDownloadTitleWithoutRenaming() async throws {
        _ = NSApplication.shared
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("Reduce Motion is enabled") }
        let file = URL(fileURLWithPath: "/tmp/red_distortion_4.heic")
        let list = DownloadList(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        list.begin(file, progress: Progress(totalUnitCount: 100))
        let row = DownloadRow(item: list.items[0])
        row.frame = NSRect(x: 0, y: 0, width: 288, height: 44)
        let window = NSWindow(contentRect: row.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = row; window.orderFront(nil); row.layoutSubtreeIfNeeded()
        defer { row.titleShimmer.cancel(); window.orderOut(nil) }
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        let menu = try XCTUnwrap(row.menu(for: event))
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Smart Rename" })
        menu.performActionForItem(at: index)
        XCTAssertTrue(row.titleShimmer.isRunning)
        XCTAssertEqual(row.titleShimmer.field?.stringValue, file.lastPathComponent)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(row.titleShimmer.field?.textColor, NSColor.secondaryLabelColor)
        XCTAssertTrue(row.titleShimmer.field?.subviews.last === row.titleShimmer)
        // Repeated clicks extend the same effect, then restore the original title.
        menu.performActionForItem(at: index)
        try await Task.sleep(for: .milliseconds(3300))
        XCTAssertFalse(row.titleShimmer.isRunning); XCTAssertTrue(row.titleShimmer.isHidden)
        XCTAssertEqual(row.titleShimmer.field?.textColor, NSColor.labelColor)
        XCTAssertEqual(row.titleShimmer.field?.stringValue, file.lastPathComponent)
        XCTAssertEqual(list.items[0].record.url, file)
    }
}
