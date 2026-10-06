import XCTest
import AppKit
@testable import Rise

@MainActor final class TokenTextViewTests: XCTestCase {
    private func textView() -> TokenTextView {
        let view = TokenTextView()
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 180)
        view.textContainer?.containerSize = NSSize(width: 240, height: 180)
        view.textContainer?.widthTracksTextView = false
        view.textContainerInset = .zero
        view.drawsBackground = false
        let text = NSMutableAttributedString(string: "A bold answer with italic words, a link, and enough text to wrap onto several lines.",
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 2, length: 4))
        view.textStorage?.setAttributedString(text)
        view.tokenLayout.ensureLayout(for: view.textContainer!)
        return view
    }

    private func render(_ view: TokenTextView) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 520, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.translateBy(x: 0, y: 400); context.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.tokenLayout.drawGlyphs(forGlyphRange: NSRange(location: 0, length: view.tokenLayout.numberOfGlyphs), at: NSPoint(x: 10, y: 10))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func ink(_ bitmap: NSBitmapImageRep) -> (mass: Double, x: Double, y: Double) {
        var mass = 0.0, x = 0.0, y = 0.0
        for row in 0..<bitmap.pixelsHigh {
            for col in 0..<bitmap.pixelsWide {
                let alpha = Double(bitmap.colorAt(x: col, y: row)!.alphaComponent)
                mass += alpha; x += Double(col)*alpha; y += Double(row)*alpha
            }
        }
        return (mass, x/mass, y/mass)
    }

    func testWordEntranceKeepsNativeLineLayoutAndSettlesWithoutAVisualJump() {
        let view = textView(), layout = view.tokenLayout, container = view.textContainer!
        let range = NSRange(location: 0, length: view.textStorage!.length)
        let glyphs = layout.glyphRange(for: container), nativeBounds = layout.usedRect(for: container)
        var lines: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in lines.append(rect) }
        let native = ink(render(view))
        view.setSelectedRange(NSRange(location: 7, length: 6))
        for progress in [0.0, 0.25, 0.7, 1.0] {
            layout.setEntrances([.init(range: range, progress: progress)])
            let frame = ink(render(view))
            XCTAssertEqual(frame.y, native.y, accuracy: 0.5, "Entrance must preserve glyph baselines")
            XCTAssertEqual(frame.x, native.x+2*TokenMotion.travel*(1-progress), accuracy: 0.5)
            XCTAssertEqual(frame.mass, native.mass, accuracy: native.mass*0.02, "No missing or double-painted text")
            XCTAssertEqual(layout.usedRect(for: container), nativeBounds)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 7, length: 6))
            var current: [NSRect] = []
            layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in current.append(rect) }
            XCTAssertEqual(current, lines)
        }
        // The last effect frame and the native renderer must put ink at the same position.
        let last = render(view)
        layout.setEntrances([])
        let settled = render(view)
        var delta = 0.0
        for y in 0..<last.pixelsHigh {
            for x in 0..<last.pixelsWide {
                delta += abs(Double(last.colorAt(x: x, y: y)!.alphaComponent-settled.colorAt(x: x, y: y)!.alphaComponent))
            }
        }
        XCTAssertLessThan(delta/native.mass, 0.02, "Settling must not switch to a different glyph raster")
    }

    func testWordsOnlyMoveDuringTheirExistingFadeAndImmediateRevealHasNoEffect() {
        var stream = TokenStream()
        stream.receive("One two three"); stream.finish()
        stream.place(in: stream.text as NSString, at: 0)
        stream.step(at: TokenMotion.initialLead+0.02)
        XCTAssertEqual(stream.entrances.count, 1)
        XCTAssertGreaterThan(stream.entrances[0].progress, 0)
        XCTAssertLessThan(stream.entrances[0].progress, 1)
        stream.step(at: 1)
        XCTAssertTrue(stream.entrances.isEmpty)
        stream.revealAll(at: 1)
        XCTAssertTrue(stream.entrances.isEmpty)
    }
}
