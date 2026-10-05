import AppKit

/// Outline icons from Tabler Icons (MIT, Paweł Kuna), kept as their SVG path data and
/// drawn as template images, so buttons tint them like SF Symbols.
enum TablerIcon {
    static let paintbrush = "M5 5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v2a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2z M19 6h1a2 2 0 0 1 2 2a5 5 0 0 1-5 5h-5v2m-2 1a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1h-2a1 1 0 0 1-1-1z"
    static func themeImage(size: CGFloat, description: String? = "Change theme") -> NSImage {
        image(paintbrush, size: size, description: description)
    }
    static let adjustments = "M4 10a2 2 0 1 0 4 0a2 2 0 0 0-4 0m2-6v4m0 4v8m4-4a2 2 0 1 0 4 0a2 2 0 0 0-4 0m2-12v10m0 4v2m4-13a2 2 0 1 0 4 0a2 2 0 0 0-4 0m2-3v1m0 4v11"
    static let link = "m9 15l6-6m-4-3l.463-.536a5 5 0 0 1 7.071 7.072L18 13m-5 5l-.397.534a5.07 5.07 0 0 1-7.127 0a4.97 4.97 0 0 1 0-7.071L6 11"
    static let eye = "M10 12a2 2 0 1 0 4 0a2 2 0 0 0-4 0M12 18q-.492 0-.97-.05Q6.271 17.452 3 12q3.6-6 9-6q5.197 0 8.727 5.558M15 18a3 3 0 1 0 6 0a3 3 0 1 0-6 0m5.2 2.2L22 22"
    static let pause = "M6 6a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1zm8 0a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-2a1 1 0 0 1-1-1z"
    static let play = "M5 5v14a2 2 0 0 0 2.75 1.84L20 13.74a2 2 0 0 0 0-3.5L7.75 3.14A2 2 0 0 0 5 4.89"
    static let linkCopied = "M17 22v-2m-8-5l6-6m-4-3l.463-.536a5 5 0 0 1 7.071 7.072L18 13m-5 5l-.397.534a5.07 5.07 0 0 1-7.127 0a4.97 4.97 0 0 1 0-7.071L6 11m14 6h2M2 7h2m3-5v2"

    /// A `size`-point template image of the 24-unit icon, stroked 2 units wide like the original.
    static func image(_ data: String, size: CGFloat, description: String? = nil) -> NSImage {
        let path = self.path(data)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: size/24, y: size/24)
            context.addPath(path); context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(2)
            context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = description
        return image
    }

    /// Parses SVG path data (M, L, H, V, Q, A, Z and their relative forms).
    static func path(_ data: String) -> CGPath {
        var scanner = PathScanner(Array(data.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero, command: UInt8 = 0
        while let next = scanner.command() ?? (command == 0 ? nil : scanner.hasNumber ? implicit(after: command) : nil) {
            command = next
            let relative = command >= 97, origin = relative ? current : .zero
            switch command | 0x20 {
            case 109: // m
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: origin.x+x, y: origin.y+y); start = current; path.move(to: current)
            case 108: // l
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: origin.x+x, y: origin.y+y); path.addLine(to: current)
            case 104: // h
                guard let x = scanner.number() else { return path }
                current.x = origin.x+x; path.addLine(to: current)
            case 118: // v
                guard let y = scanner.number() else { return path }
                current.y = origin.y+y; path.addLine(to: current)
            case 113: // q
                guard let cx = scanner.number(), let cy = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: origin.x+x, y: origin.y+y)
                path.addQuadCurve(to: current, control: CGPoint(x: origin.x+cx, y: origin.y+cy))
            case 97: // a
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let x = scanner.number(), let y = scanner.number() else { return path }
                let end = CGPoint(x: origin.x+x, y: origin.y+y)
                addArc(to: path, from: current, to: end, radii: CGSize(width: rx, height: ry), rotation: rotation, large: large, sweep: sweep)
                current = end
            case 122: // z
                path.closeSubpath(); current = start
            default: return path
            }
        }
        return path
    }
    /// Coordinates following a command repeat it; after a move they continue as lines.
    private static func implicit(after command: UInt8) -> UInt8 {
        command == 77 ? 76 : command == 109 ? 108 : command
    }
    /// SVG's endpoint arc as cubic Béziers (SVG 1.1, appendix F.6).
    private static func addArc(to path: CGMutablePath, from p1: CGPoint, to p2: CGPoint, radii: CGSize, rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(radii.width), ry = abs(radii.height)
        guard rx > 0, ry > 0, p1 != p2 else { path.addLine(to: p2); return }
        let phi = rotation * .pi/180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p1.x-p2.x)/2, dy = (p1.y-p2.y)/2
        let x1 = cosPhi*dx+sinPhi*dy, y1 = -sinPhi*dx+cosPhi*dy
        let lambda = x1*x1/(rx*rx)+y1*y1/(ry*ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx*rx*ry*ry-rx*rx*y1*y1-ry*ry*x1*x1, denominator = rx*rx*y1*y1+ry*ry*x1*x1
        let coefficient = (large != sweep ? 1 : -1)*sqrt(max(0, numerator/denominator))
        let cx1 = coefficient*rx*y1/ry, cy1 = -coefficient*ry*x1/rx
        let center = CGPoint(x: cosPhi*cx1-sinPhi*cy1+(p1.x+p2.x)/2, y: sinPhi*cx1+cosPhi*cy1+(p1.y+p2.y)/2)
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double { atan2(ux*vy-uy*vx, ux*vx+uy*vy) }
        let theta = angle(1, 0, (x1-cx1)/rx, (y1-cy1)/ry)
        var delta = angle((x1-cx1)/rx, (y1-cy1)/ry, (-x1-cx1)/rx, (-y1-cy1)/ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        func point(_ t: Double) -> CGPoint {
            CGPoint(x: center.x+rx*cos(t)*cosPhi-ry*sin(t)*sinPhi, y: center.y+rx*cos(t)*sinPhi+ry*sin(t)*cosPhi)
        }
        func slope(_ t: Double) -> CGPoint {
            CGPoint(x: -rx*sin(t)*cosPhi-ry*cos(t)*sinPhi, y: -rx*sin(t)*sinPhi+ry*cos(t)*cosPhi)
        }
        let segments = max(1, Int(ceil(abs(delta)/(.pi/2)))), step = delta/Double(segments)
        let k = 4.0/3*tan(step/4)
        for index in 0..<segments {
            let a = theta+Double(index)*step, b = a+step
            let pa = point(a), pb = index == segments-1 ? p2 : point(b), da = slope(a), db = slope(b)
            path.addCurve(to: pb, control1: CGPoint(x: pa.x+k*da.x, y: pa.y+k*da.y), control2: CGPoint(x: pb.x-k*db.x, y: pb.y-k*db.y))
        }
    }
}

/// Reads SVG path tokens, including run-together numbers like "1-1" and ".463-.536".
private struct PathScanner {
    let bytes: [UInt8]
    var index = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    mutating func skipSeparators() {
        while index < bytes.count, [32, 44, 9, 10, 13].contains(bytes[index]) { index += 1 }
    }
    var hasNumber: Bool {
        var probe = self; probe.skipSeparators()
        guard probe.index < bytes.count else { return false }
        let byte = bytes[probe.index]
        return (48...57).contains(byte) || byte == 45 || byte == 43 || byte == 46
    }
    mutating func command() -> UInt8? {
        skipSeparators()
        guard index < bytes.count, let character = Optional(bytes[index]), (65...90).contains(character) || (97...122).contains(character),
              character != 101, character != 69 else { return nil }
        index += 1; return character
    }
    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else { return nil }
        defer { index += 1 }
        return bytes[index] == 49
    }
    mutating func number() -> Double? {
        skipSeparators()
        let begin = index
        if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
        var sawDot = false, sawDigit = false
        while index < bytes.count {
            let byte = bytes[index]
            if (48...57).contains(byte) { sawDigit = true; index += 1 }
            else if byte == 46 && !sawDot { sawDot = true; index += 1 }
            else if (byte == 101 || byte == 69) && sawDigit {
                index += 1
                if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
            } else { break }
        }
        guard sawDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii) else { index = begin; return nil }
        return Double(text)
    }
}
