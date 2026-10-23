import XCTest
import AppKit
@testable import Rise

final class PageTopColorTests: XCTestCase {
    /// GitLab's top: a lavender strip with dark text and an icon on it, and a shade off in places.
    func testTheBarTakesTheMostCommonDrawnColourNotTheTextOnIt() throws {
        let width = 240, height = 2
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        for index in 0..<width*height {
            let x = index % width
            let (r, g, b): (UInt8, UInt8, UInt8) = x % 5 == 0 ? (20, 20, 20) : x % 7 == 0 ? (234, 233, 242) : (233, 232, 241)
            pixels[index*4] = r; pixels[index*4+1] = g; pixels[index*4+2] = b; pixels[index*4+3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let color = try XCTUnwrap(PageTopColor.dominant(in: image)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent*255, 233, accuracy: 1)
        XCTAssertEqual(color.greenComponent*255, 232, accuracy: 1)
        XCTAssertEqual(color.blueComponent*255, 241, accuracy: 1)
    }
}
