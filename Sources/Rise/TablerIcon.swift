import AppKit

/// Outline icons from Tabler Icons (MIT, Paweł Kuna), kept as their SVG path data and
/// drawn as template images, so buttons tint them like SF Symbols.
enum TablerIcon {
    static let paintbrush = "M5 5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v2a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2z M19 6h1a2 2 0 0 1 2 2a5 5 0 0 1-5 5h-5v2m-2 1a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1h-2a1 1 0 0 1-1-1z"
    static func themeImage(size: CGFloat, description: String? = "Change theme") -> NSImage {
        image(paintbrush, size: size, description: description)
    }
    static let tabCleanup = "M12 17H6a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h11a2 2 0 0 1 2 2v.5a.5.5 0 0 0 .5.5a.5.5 0 0 1 .5.5v1m-1 11a4.75 4.75 0 0 1 3.5-3.5a4.75 4.75 0 0 1-3.5-3.5a4.75 4.75 0 0 1-3.5 3.5a4.75 4.75 0 0 1 3.5 3.5"
    static let adjustments = "M4 10a2 2 0 1 0 4 0a2 2 0 0 0-4 0m2-6v4m0 4v8m4-4a2 2 0 1 0 4 0a2 2 0 0 0-4 0m2-12v10m0 4v2m4-13a2 2 0 1 0 4 0a2 2 0 0 0-4 0m2-3v1m0 4v11"
    /// A magnifying glass with a plus: mostly its ring, with a short handle.
    static let zoomIn = "M3.5 10.5a7.5 7.5 0 1 0 15 0a7.5 7.5 0 1 0 -15 0M8.5 10.5h5M11 8v5M16.3 15.8l3.7 3.7"
    static let link = "m9 15l6-6m-4-3l.463-.536a5 5 0 0 1 7.071 7.072L18 13m-5 5l-.397.534a5.07 5.07 0 0 1-7.127 0a4.97 4.97 0 0 1 0-7.071L6 11"
    /// An X centred in its box.
    static let cross = "M6 6L18 18M18 6L6 18"
    /// CodeX Icons' trash (MIT), for deleting a file.
    static let bin = "M18.133 7.723q.435.06.867.128m-.867-.128l-.906 9.68c-.037.434-.254.84-.607 1.136a2.02 2.02 0 0 1-1.297.461H8.677c-.48 0-.944-.164-1.297-.46a1.67 1.67 0 0 1-.607-1.138l-.906-9.679m12.266 0a45 45 0 0 0-2.951-.305m-9.315.305q-.435.06-.867.127m.867-.127a45 45 0 0 1 2.951-.305m6.364 0a45.5 45.5 0 0 0-6.364 0m6.364 0c0-2.114-1.455-3.07-3.182-3.07S8.818 5.44 8.818 7.418M10.5 15.5L10 11m4 0l-.5 4.5"
    static let eye = "M10 12a2 2 0 1 0 4 0a2 2 0 0 0-4 0M12 18q-.492 0-.97-.05Q6.271 17.452 3 12q3.6-6 9-6q5.197 0 8.727 5.558M15 18a3 3 0 1 0 6 0a3 3 0 1 0-6 0m5.2 2.2L22 22"
    static let pause = "M6 6a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1zm8 0a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-2a1 1 0 0 1-1-1z"
    static let play = "M5 5v14a2 2 0 0 0 2.75 1.84L20 13.74a2 2 0 0 0 0-3.5L7.75 3.14A2 2 0 0 0 5 4.89"
    static let searchWindow = "M20 11V9a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v5a2 2 0 0 0 2 2h5m4 2a3 3 0 1 0 6 0a3 3 0 1 0-6 0m5.2 2.2L22 22"
    static let infoCircle = "M3 12a9 9 0 1 0 18 0a9 9 0 0 0-18 0m9-3h.01M11 12h1v4h1"
    static let enterKey = "m9 11l-4 4l4 4m-4-4h11a4 4 0 0 0 0-8h-1"
    static let alertTriangle = "M12 9v4m-1.637-9.409L2.257 17.125a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636-2.87L13.637 3.59a1.914 1.914 0 0 0-3.274 0M12 16h.01"
    static let star = "m12 17.75l-6.172 3.245l1.179-6.873l-5-4.867l6.9-1l3.086-6.253l3.086 6.253l6.9 1l-5 4.867l1.179 6.873z"
    static let linkCopied = "M17 22v-2m-8-5l6-6m-4-3l.463-.536a5 5 0 0 1 7.071 7.072L18 13m-5 5l-.397.534a5.07 5.07 0 0 1-7.127 0a4.97 4.97 0 0 1 0-7.071L6 11m14 6h2M2 7h2m3-5v2"

    static let cookie = "M8 13v.01M12 17v.01M12 12v.01M16 14v.01M11 8v.01m2.148-4.534l2.667 1.104a4 4 0 0 0 4.656 6.14l.053.132a3 3 0 0 1 0 2.296Q19.779 14.328 19.5 15q-.283.684-.66 2.216a3 3 0 0 1-1.624 1.623q-1.572.394-2.216.661q-.712.295-1.852 1.024a3 3 0 0 1-2.296 0Q9.649 19.77 9 19.5q-.707-.292-2.216-.66a3 3 0 0 1-1.623-1.624Q4.764 15.639 4.5 15q-.298-.718-1.024-1.852a3 3 0 0 1 0-2.296Q4.195 9.736 4.5 9q.257-.62.66-2.216a3 3 0 0 1 1.624-1.623Q8.331 4.777 9 4.5q.687-.285 1.852-1.024a3 3 0 0 1 2.296 0"
    static let plus = "M12 5v14M5 12h14"
    /// The tab search row's icon, the supplied Tabler flower.
    static let tabSearch = "M14.792 17.063c0 .337.057.618.057.9c0 1.8-1.238 3.037-2.982 3.037c-1.8 0-2.98-1.238-2.98-3.206v-.731c-.957.675-1.576.9-2.42.9c-1.518 0-2.925-1.463-2.925-3.094c0-1.181.844-2.194 2.082-2.756l.28-.113c-1.574-.787-2.362-1.688-2.362-2.925c0-1.687 1.294-3.094 2.925-3.094c.675 0 1.52.338 2.138.788l.281.112c0-.337-.056-.619-.056-.844C8.83 4.237 10.067 3 11.81 3c1.8 0 2.981 1.237 2.981 3.206V6.6l-.056.281c.956-.675 1.575-.9 2.419-.9c1.519 0 2.925 1.463 2.925 3.094c0 1.181-.844 2.194-2.081 2.756l-.282.169c1.575.787 2.363 1.688 2.363 2.925c0 1.688-1.294 3.094-2.925 3.094c-.675 0-1.575-.281-2.138-.788z"
    static let bell = "M10 5a2 2 0 1 1 4 0a7 7 0 0 1 4 6v3a4 4 0 0 0 2 3H4a4 4 0 0 0 2-3v-3a7 7 0 0 1 4-6"
    /// What a site asks to use, in its permission's icon in the address bar.
    static let camera = "M5 7h1a2 2 0 0 0 2-2a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1a2 2 0 0 0 2 2h1a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2M9 13a3 3 0 1 0 6 0a3 3 0 0 0-6 0"
    static let microphone = "M9 5a3 3 0 0 1 3-3a3 3 0 0 1 3 3v5a3 3 0 0 1-3 3a3 3 0 0 1-3-3zM5 10a7 7 0 0 0 14 0M8 21h8M12 17v4"
    static let mapPin = "M9 11a3 3 0 1 0 6 0a3 3 0 0 0-6 0M17.657 16.657l-4.243 4.243a2 2 0 0 1-2.827 0l-4.244-4.243a8 8 0 1 1 11.314 0z"
    /// Tabler's clapper, lowered a unit so the filled bell keeps a gap above it.
    static let bellClapper = "M10 20h4a2 2 0 0 1-4 0"

    /// A `size`-point template image of the 24-unit icon, stroked 2 units wide like the original.
    /// `strokeWidth` overrides the stroke in points.
    /// `filled` also fills each outline's enclosed area. `centered` centers the
    /// drawn shape itself, rather than the 24-unit box it sits in.
    static func image(_ data: String, size: CGFloat, filled: Bool = false, centered: Bool = false, strokeWidth: CGFloat? = nil, description: String? = nil) -> NSImage {
        let path = self.path(data)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: size/24, y: size/24)
            if centered {
                let ink = path.boundingBoxOfPath
                context.translateBy(x: 12-ink.midX, y: 12-ink.midY)
            }
            if filled { context.addPath(path); context.setFillColor(NSColor.black.cgColor); context.fillPath() }
            context.addPath(path); context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(strokeWidth.map { $0*24/size } ?? 2)
            context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = description
        return image
    }

    /// Parses SVG path data (M, L, H, V, C, S, Q, A, Z and their relative forms).
    static func path(_ data: String) -> CGPath {
        var scanner = PathScanner(Array(data.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero, command: UInt8 = 0
        // A cubic's second control point, which a following S mirrors.
        var lastControl: CGPoint?
        while let next = scanner.command() ?? (command == 0 ? nil : scanner.hasNumber ? implicit(after: command) : nil) {
            command = next
            let relative = command >= 97, origin = relative ? current : .zero
            let mirrored = lastControl.map { CGPoint(x: 2*current.x-$0.x, y: 2*current.y-$0.y) } ?? current
            lastControl = nil
            switch command | 0x20 {
            case 99: // c
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let control = CGPoint(x: origin.x+x2, y: origin.y+y2)
                current = CGPoint(x: origin.x+x, y: origin.y+y)
                path.addCurve(to: current, control1: CGPoint(x: origin.x+x1, y: origin.y+y1), control2: control); lastControl = control
            case 115: // s
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let control = CGPoint(x: origin.x+x2, y: origin.y+y2)
                current = CGPoint(x: origin.x+x, y: origin.y+y)
                path.addCurve(to: current, control1: mirrored, control2: control); lastControl = control
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
