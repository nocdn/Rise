import Foundation

/// Aspect ratios: "1920x1080 aspect ratio" is 16:9, "16:9 at 1280 wide" is 1280 × 720, "1920x1080 at 50%"
/// is 960 × 540, "2560x1080 ratio" is 64:27, near enough 21:9. Screens' odd sizes are named by the
/// common ratio they're close to.
enum RatioCalculation {
    private static let size = #"(\d{1,6}(?:\.\d+)?) ?(?:x|by|:|\*) ?(\d{1,6}(?:\.\d+)?)(?: ?px| pixels)?"#
    private static let side = #"(\d{1,6}(?:\.\d+)?)(?: ?px| pixels)? ?(wide|width|w|high|height|h|tall)"#

    static func evaluate(_ query: String) -> AddressCalculation? {
        var text = query, asksRatio = false
        if let match = AddressCalculation.groups(#"^(?:(?:simplify|reduce) )?(?:the )?(?:aspect )?ratio(?: of| for)? (.+)$"#, in: text) {
            text = match[1]; asksRatio = true
        }
        // "1920x1080 ratio", "1920x1080 aspect ratio at 1280 wide"
        if let match = AddressCalculation.groups(#"^(.+?) (?:aspect )?ratio(?=$| )(.*)$"#, in: text) { text = match[1]+match[2]; asksRatio = true }
        // "1280 wide at 16:9": the side first.
        if let match = AddressCalculation.groups("^" + side + #" (?:at |for |with |in )?(.+?)(?: aspect)?(?: ratio)?$"#, in: text) {
            text = match[3] + " at " + match[1] + " " + match[2]
        }
        guard let match = AddressCalculation.groups("^" + size + "((?: (?:at|with|then|to|for|scaled to|scaled by|resized to|cropped to|crop to|fit to|in|as) [^ ]+(?: [a-z]+)?)*)$", in: text),
              let width = Double(match[1]), let height = Double(match[2]), width > 0, height > 0 else { return nil }
        var steps = Cursor(match[3])
        var size = (width, height), changed = false
        var output = "ratio"
        while !steps.isAtEnd {
            if let step = steps.take(" (?:at|with|then|to|for|resized to) " + side) {
                guard let length = Double(step[1]), length > 0 else { return nil }
                let wide = ["wide", "width", "w"].contains(step[2])
                size = wide ? (length, length*size.1/size.0) : (length*size.0/size.1, length)
                changed = true; output = "size"
            } else if let step = steps.take(#" (?:at|to|scaled to|scaled by|by) (\d{1,4}(?:\.\d+)?)%"#), let percent = Double(step[1]), percent > 0 {
                size = (size.0*percent/100, size.1*percent/100); changed = true; output = "size"
            } else if let step = steps.take(#" (?:to|at|as|cropped to|crop to|fit to|in) (\d{1,3}(?:\.\d+)?) ?(?::|x|by) ?(\d{1,3}(?:\.\d+)?)(?![\d.])"#),
                      let a = Double(step[1]), let b = Double(step[2]), a > 0, b > 0 {
                // The largest size of that ratio inside this one: what a crop to it keeps.
                size = size.0/size.1 > a/b ? (size.1*a/b, size.1) : (size.0, size.0*b/a)
                changed = true; output = "size"
            } else if let step = steps.take(#" (?:in|to|as) (megapixels|mp|pixels|px|ratio|decimal)"#) {
                output = step[1]
            } else { return nil }
        }
        guard asksRatio || changed || output != "ratio" else { return nil }
        switch output {
        case "size":
            return AddressCalculation("\(Int(size.0.rounded())) × \(Int(size.1.rounded())) px")
        case "megapixels", "mp":
            return AddressCalculation(AddressCalculation.number(size.0*size.1/1e6, digits: 2) + " MP")
        case "pixels", "px":
            return AddressCalculation(AddressCalculation.number((size.0*size.1).rounded(), digits: 0, grouping: true) + " px")
        case "decimal":
            return AddressCalculation(AddressCalculation.number(size.0/size.1, digits: 3) + ":1")
        default:
            return AddressCalculation(ratioText(size.0, size.1))
        }
    }

    /// The ratio in whole numbers, as people name it: 16:10 rather than 8:5, and the common ratio an
    /// odd one is close to beside it.
    static func ratioText(_ width: Double, _ height: Double) -> String {
        let whole = { (value: Double) -> Bool in value.rounded() == value }
        let scales: [Double] = [1, 10, 100]
        let scale = scales.first { whole(width*$0) && whole(height*$0) } ?? 100
        var a = Int((width*scale).rounded()), b = Int((height*scale).rounded())
        let (w, h) = (a, b)
        while b != 0 { (a, b) = (b, a%b) }
        var reduced = (w/a, h/a)
        if reduced == (8, 5) { reduced = (16, 10) }
        if reduced == (5, 8) { reduced = (10, 16) }
        let text = "\(reduced.0):\(reduced.1)"
        let common: [(Double, Double)] = [(1, 1), (5, 4), (4, 3), (3, 2), (16, 10), (16, 9), (2, 1), (21, 9), (32, 9),
                                          (4, 5), (3, 4), (2, 3), (10, 16), (9, 16), (9, 19.5), (9, 21)]
        guard !common.contains(where: { $0.0 == Double(reduced.0) && $0.1 == Double(reduced.1) }) else { return text }
        let value = width/height
        if let near = common.min(by: { abs($0.0/$0.1-value) < abs($1.0/$1.1-value) }), abs(near.0/near.1-value)/value < 0.03 {
            let name = "\(AddressCalculation.number(near.0, digits: 1)):\(AddressCalculation.number(near.1, digits: 1))"
            return text + " · ≈ " + name
        }
        return text
    }
}
