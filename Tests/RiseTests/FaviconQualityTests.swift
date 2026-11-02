import AppKit
import RiseCore
import XCTest
@testable import Rise

final class FaviconQualityTests: XCTestCase {
    func testYouTubeStyleDeclarationsChooseLargeArtworkAndKeepAppearancePriority() {
        let page = URL(string: "https://www.youtube.com/watch?v=video")!
        let html = Data("""
            <link rel="shortcut icon" href="/favicon.ico">
            <link rel="icon" href="/32.png" sizes="32x32">
            <link rel="icon" href="/144.png" sizes="144x144">
            <link rel="icon" href="/48.png" sizes="48x48">
            """.utf8)
        for dark in [false, true] {
            XCTAssertEqual(FaviconDiscovery.icon(in: html, baseURL: page, dark: dark)?.lastPathComponent, "144.png")
        }
        let themed = html + Data("<link rel='icon' href='/dark.png' sizes='48x48' media='(prefers-color-scheme: dark)'>".utf8)
        XCTAssertEqual(FaviconDiscovery.icon(in: themed, baseURL: page, dark: true)?.lastPathComponent, "dark.png")
        XCTAssertEqual(FaviconDiscovery.icon(in: themed, baseURL: page)?.lastPathComponent, "144.png")
    }

    @MainActor func testICOUsesItsLargestFrameAndSmallFallbacksAreNotUpscaledInTheCache() throws {
        func png(_ size: Int, _ color: NSColor) throws -> Data {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
            let pixels = try XCTUnwrap(rep.bitmapData)
            for y in 0..<size { for x in 0..<size {
                let at = y*rep.bytesPerRow+x*4
                pixels[at] = UInt8(rgb.redComponent*255); pixels[at+1] = UInt8(rgb.greenComponent*255)
                pixels[at+2] = UInt8(rgb.blueComponent*255); pixels[at+3] = 255
            } }
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }
        let small = try png(16, .red), large = try png(64, .green)
        var ico = Data([0, 0, 1, 0, 2, 0])
        func integer(_ value: Int, bytes: Int) { for shift in 0..<bytes { ico.append(UInt8(truncatingIfNeeded: value >> (shift*8))) } }
        for (size, data, offset) in [(16, small, 38), (64, large, 38+small.count)] {
            ico.append(contentsOf: [UInt8(size), UInt8(size), 0, 0])
            integer(1, bytes: 2); integer(32, bytes: 2); integer(data.count, bytes: 4); integer(offset, bytes: 4)
        }
        ico.append(small); ico.append(large)
        let decoded = try XCTUnwrap(FaviconImage.decode(ico, dark: false))
        XCTAssertEqual(FaviconImage.pixels(decoded), 64)
        let snapshot = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(FaviconSnapshot.encode(decoded))))
        XCTAssertEqual(snapshot.pixelsWide, 32)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB)).greenComponent, 0.9)
        let fallback = try XCTUnwrap(FaviconImage.decode(small, dark: false))
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(FaviconSnapshot.encode(fallback)))).pixelsWide, 16)
    }
}
