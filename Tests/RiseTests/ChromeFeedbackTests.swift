import XCTest
import AppKit
@testable import Rise

final class ChromeFeedbackTests: XCTestCase {
    @MainActor func testPeekHintSwapsImmediatelyAndKeepsSuffixVisibleForLongLinks() throws {
        _ = NSApplication.shared
        let pill = LinkStatusPill()
        let url = URL(string: "https://example.com/" + String(repeating: "long-path/", count: 80))!
        let page = NSRect(x: 0, y: 0, width: 800, height: 600)
        pill.show(url, theme: .dark); pill.place(in: page)
        let font = pill.text.font
        pill.markReady(url)
        pill.show(url, theme: .dark, peek: true); pill.place(in: page); pill.layoutSubtreeIfNeeded()
        XCTAssertTrue(pill.showsPeekHint); XCTAssertTrue(pill.ready)
        XCTAssertFalse(pill.isShimmering, "Changing modifiers swaps text without a shimmer or transition")
        XCTAssertFalse(pill.peekPrefix.isHidden); XCTAssertFalse(pill.peekSuffix.isHidden)
        XCTAssertEqual(pill.text.stringValue, url.absoluteString)
        XCTAssertEqual(pill.text.font, font)
        XCTAssertEqual(pill.frame.width, 650)
        XCTAssertEqual(pill.peekPrefix.frame.maxX-6, pill.text.frame.minX, accuracy: 0.001)
        XCTAssertEqual(pill.text.frame.maxX-6, pill.peekSuffix.frame.minX, accuracy: 0.001)
        XCTAssertEqual(pill.peekSuffix.frame.maxX, pill.bounds.width-12)
        XCTAssertEqual(pill.text.lineBreakMode, .byTruncatingTail, "Only the URL truncates; the Peek hint remains visible")
        XCTAssertNil(pill.text.layer?.mask, "Long URLs use an ellipsis instead of fading")
        XCTAssertTrue(pill.layer?.animationKeys()?.isEmpty ?? true)
        func ink(_ field: NSTextField) throws -> Int {
            let bitmap = try XCTUnwrap(field.bitmapImageRepForCachingDisplay(in: field.bounds))
            field.cacheDisplay(in: field.bounds, to: bitmap)
            return (0..<bitmap.pixelsHigh).reduce(0) { sum, y in
                sum + (0..<bitmap.pixelsWide).filter { bitmap.colorAt(x: $0, y: y)!.alphaComponent > 0 }.count
            }
        }
        let reference = label(" in Peek", size: 12, weight: .medium)
        reference.textColor = pill.peekSuffix.textColor; reference.lineBreakMode = .byClipping
        reference.frame = NSRect(x: 0, y: 0, width: 200, height: pill.peekSuffix.frame.height)
        XCTAssertEqual(try ink(pill.peekSuffix), try ink(reference), "Every suffix glyph must be drawn without clipping or an ellipsis")
        pill.show(URL(string: "https://a.co")!, theme: .dark, peek: true); pill.place(in: page)
        XCTAssertEqual(try ink(pill.peekSuffix), try ink(reference), "Short pills must show the full Peek hint too")
        pill.show(url, theme: .dark); pill.place(in: page); pill.layoutSubtreeIfNeeded()
        XCTAssertFalse(pill.showsPeekHint); XCTAssertFalse(pill.isShimmering)
        XCTAssertTrue(pill.peekPrefix.isHidden); XCTAssertTrue(pill.peekSuffix.isHidden)
        XCTAssertEqual(pill.text.frame.minX, 12)
        XCTAssertEqual(pill.text.lineBreakMode, .byTruncatingTail)
        XCTAssertNil(pill.text.layer?.mask)
        XCTAssertEqual(pill.text.stringValue, url.absoluteString.replacingOccurrences(of: "https://", with: ""))
        XCTAssertEqual(pill.frame.minX, page.minX+10); XCTAssertEqual(pill.frame.maxY, page.maxY-10)
    }
    @MainActor func testLateReadyEventDoesNotShimmerADifferentDestination() {
        _ = NSApplication.shared
        let pill = LinkStatusPill()
        let first = URL(string: "https://example.com/first")!, second = URL(string: "https://example.com/second")!
        pill.show(first, theme: .neutral)
        pill.show(second, theme: .neutral)
        pill.markReady(first)
        XCTAssertFalse(pill.ready)
        XCTAssertFalse(pill.isShimmering)
        pill.show(nil, theme: .neutral)
        XCTAssertTrue(pill.isHidden)
    }
    @MainActor func testShimmerPreservesNativeGlyphCoverageAndFontWeight() async throws {
        _ = NSApplication.shared
        let text = ShimmeringTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 18))
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = NSColor(hex: 0x343434).withAlphaComponent(0.8)
        text.shimmerColor = .white
        text.stringValue = "example.com/ready"
        let originalFont = text.font
        text.layoutSubtreeIfNeeded()
        func pixels() throws -> [UInt8] {
            let bitmap = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: text.bounds))
            text.cacheDisplay(in: text.bounds, to: bitmap)
            return (0..<bitmap.pixelsHigh).flatMap { y in
                (0..<bitmap.pixelsWide).map { x in UInt8((bitmap.colorAt(x: x, y: y)!.alphaComponent * 255).rounded()) }
            }
        }
        let before = try pixels()
        XCTAssertGreaterThan(before.filter { $0 > 0 }.count, 20, "The captured native glyphs must be visible")
        text.startShimmer()
        try await Task.sleep(for: .milliseconds(240))
        let during = try pixels()
        XCTAssertEqual(text.font, originalFont)
        XCTAssertEqual(before, during, "Highlighting may change color, but must not thicken glyph coverage")
        text.stopShimmer()
        XCTAssertEqual(before, try pixels())
        XCTAssertEqual(text.font, originalFont)
    }
    @MainActor func testPreloadShimmerIsVisibleInEveryThemeWithoutChangingGlyphCoverage() async throws {
        _ = NSApplication.shared
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let url = URL(string: "https://example.com/ready")!
        var pills: [LinkStatusPill] = []
        func pixels(_ text: NSTextField) throws -> [(color: SIMD3<Int>, alpha: Int)] {
            let bitmap = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: text.bounds))
            text.cacheDisplay(in: text.bounds, to: bitmap)
            return (0..<bitmap.pixelsHigh).flatMap { y in
                (0..<bitmap.pixelsWide).map { x in
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    return (SIMD3(Int((color.redComponent*255).rounded()), Int((color.greenComponent*255).rounded()),
                                  Int((color.blueComponent*255).rounded())), Int((color.alphaComponent*255).rounded()))
                }
            }
        }
        var resting: [[(color: SIMD3<Int>, alpha: Int)]] = []
        for theme in RiseTheme.allCases {
            let pill = LinkStatusPill(); pill.appearance = theme.appearance
            pill.show(url, theme: theme); pill.place(in: NSRect(x: 0, y: 0, width: 800, height: 600))
            pill.layoutSubtreeIfNeeded(); resting.append(try pixels(pill.text)); pills.append(pill)
        }
        pills.forEach { $0.markReady(url) }
        try await Task.sleep(for: .milliseconds(320))
        for (index, pill) in pills.enumerated() {
            XCTAssertTrue(pill.isShimmering)
            let animated = try pixels(pill.text), original = resting[index]
            XCTAssertEqual(original.map(\.alpha), animated.map(\.alpha), "The shimmer must preserve font coverage")
            let changed = zip(original, animated).filter { before, during in
                before.alpha > 128 && max(abs(before.color.x-during.color.x), abs(before.color.y-during.color.y),
                                           abs(before.color.z-during.color.z)) > 30
            }
            XCTAssertGreaterThan(changed.count, 20, "The highlight must visibly sweep over glyphs in \(RiseTheme.allCases[index])")
        }
        pills.forEach { $0.text.stopShimmer() }
        for (index, pill) in pills.enumerated() {
            let finished = try pixels(pill.text)
            XCTAssertEqual(resting[index].map(\.color), finished.map(\.color))
            XCTAssertEqual(resting[index].map(\.alpha), finished.map(\.alpha))
        }
    }
    @MainActor func testPreloadShimmerKeepsPillStationaryThroughLayoutAndOnlyRunsOnce() async throws {
        _ = NSApplication.shared
        let pill = LinkStatusPill()
        let url = URL(string: "https://example.com/target")!
        let page = NSRect(x: 0, y: 0, width: 800, height: 600)
        pill.show(url, theme: .neutral); pill.place(in: page)
        let restingFrame = pill.frame
        pill.markReady(url)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertFalse(pill.isShimmering); return
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(pill.isShimmering)
        XCTAssertEqual(pill.frame, restingFrame)
        pill.place(in: page)
        XCTAssertEqual(pill.frame, restingFrame, "Layout must keep the pill stationary")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(pill.isShimmering)
        XCTAssertEqual(pill.frame, restingFrame)
        pill.markReady(url)
        XCTAssertFalse(pill.isShimmering, "The same completion must not start a second sweep")
        pill.show(nil, theme: .neutral)
        XCTAssertFalse(pill.isShimmering)
    }
}
