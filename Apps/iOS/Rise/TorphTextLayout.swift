import UIKit
import CoreText

/// Shape whole lines once, then assign shaped glyphs to stable Torph fragments.
/// Unlike separately drawing individual letters, this preserves kerning, ligatures,
/// composed emoji, font fallback and joining scripts when a word is split mid-morph.
@MainActor struct TorphTextLayout {
    struct Run { var font: CTFont; var glyphs: [CGGlyph]; var positions: [CGPoint] }
    struct Fragment { var segment: TorphText.Segment; var frame: CGRect; var runs: [Run]; var baseline: CGFloat }
    var fragments: [Fragment]
    var size: CGSize

    init(_ segments: [TorphText.Segment], font: UIFont) {
        var groups: [[TorphText.Segment]] = [[]]
        for segment in segments {
            if segment.text == "\n" { groups.append([]) } else { groups[groups.count-1].append(segment) }
        }
        var fragments: [Fragment] = [], width: CGFloat = 0
        for (lineIndex, group) in groups.enumerated() {
            let text = group.map(\.text).joined()
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            width = max(width,CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil)))
            let top = CGFloat(lineIndex)*font.lineHeight, baseline = top+font.ascender
            var ranges: [NSRange] = [], offset = 0
            var frames: [CGRect] = []
            var paints = [[Run]](repeating: [],count: group.count)
            for segment in group {
                let count = segment.text.utf16.count
                ranges.append(NSRange(location: offset,length: count))
                let a = CTLineGetOffsetForStringIndex(line,offset,nil), b = CTLineGetOffsetForStringIndex(line,offset+count,nil)
                frames.append(CGRect(x: min(a,b),y: top,width: abs(b-a),height: font.lineHeight))
                offset += count
            }
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let actualFont = attributes[kCTFontAttributeName] as! CTFont
                var glyphs = [CGGlyph](repeating: 0,count: count), points = [CGPoint](repeating: .zero,count: count)
                var indices = [CFIndex](repeating: 0,count: count)
                CTRunGetGlyphs(run,CFRange(location: 0,length: 0),&glyphs)
                CTRunGetPositions(run,CFRange(location: 0,length: 0),&points)
                CTRunGetStringIndices(run,CFRange(location: 0,length: 0),&indices)
                for gi in 0..<count {
                    guard let si = ranges.firstIndex(where: { NSLocationInRange(indices[gi],$0) }) else { continue }
                    paints[si].append(Run(font: actualFont,glyphs: [glyphs[gi]],positions: [points[gi]]))
                    var glyph = glyphs[gi]
                    let ink = CTFontGetBoundingRectsForGlyphs(actualFont,.default,&glyph,nil,1)
                    if !ink.isEmpty {
                        let rect = CGRect(x: points[gi].x+ink.minX,y: baseline-points[gi].y-ink.maxY,width: ink.width,height: ink.height)
                        frames[si] = frames[si].union(rect)
                    }
                }
            }
            for i in group.indices {
                fragments.append(Fragment(segment: group[i],frame: frames[i].insetBy(dx: -1,dy: -1),runs: paints[i],baseline: baseline))
            }
        }
        self.fragments = fragments
        size = CGSize(width: width,height: CGFloat(max(1,groups.count))*font.lineHeight)
    }
}

@MainActor final class TorphFragmentView: UIView {
    var fragment: TorphTextLayout.Fragment
    var ink: UIColor
    private var cleanup: Task<Void,Never>?
    init(_ fragment: TorphTextLayout.Fragment, color: UIColor) {
        self.fragment = fragment; ink = color
        super.init(frame: fragment.frame)
        isOpaque = false; isUserInteractionEnabled = false; accessibilityElementsHidden = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ fragment: TorphTextLayout.Fragment, color: UIColor) {
        self.fragment = fragment; ink = color; setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(ink.resolvedColor(with: traitCollection).cgColor)
        context.textMatrix = .identity
        context.translateBy(x: 0,y: bounds.height); context.scaleBy(x: 1,y: -1)
        for run in fragment.runs {
            var points = run.positions.map { CGPoint(x: $0.x-fragment.frame.minX,
                y: bounds.height-(fragment.baseline-fragment.frame.minY)+$0.y) }
            var glyphs = run.glyphs
            CTFontDrawGlyphs(run.font,&glyphs,&points,glyphs.count,context)
        }
    }
    func remove(after duration: Double) {
        cleanup?.cancel()
        cleanup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)); self?.removeFromSuperview() } catch { }
        }
    }
    isolated deinit { cleanup?.cancel() }
}
