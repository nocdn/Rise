#if os(macOS)
import AppKit
typealias TokenColor = NSColor
#else
import UIKit
typealias TokenColor = UIColor
#endif

/// The streamed answer's effect, from the token generation exploration (fade-in duration
/// 200 ms, color spread 2 tokens, color transition 280 ms): each word fades in rose-500,
/// steps back to rose-300 as the next one arrives, then eases into the text color.
enum TokenMotion {
    static let fade = 0.2
    static let spread = 2
    static let colorTransition = 0.28
    static let blur = 1.0, travel = 1.5
    /// Words play out `lead` behind the model, at the pace they arrived, so bursts and short
    /// stalls in the network come out as a steady stream. The first burst goes at the
    /// initial word cadence; any burst stays between `slowest` and `fastest`.
    /// These are whole words, not model tokens: fast network chunks must not flash
    /// a short response into view in a single frame or two.
    static let lead = 0.2, wordsPerSecond = 30.0, slowest = 20.0, fastest = 40.0
    /// Start promptly, then build the normal buffer as later words arrive.
    static let initialLead = 0.03
    /// Buffer drift is corrected by playing up to this much slower or faster.
    static let drift = 0.25
    /// Target maximum buffer delay, without exceeding the fastest reveal cadence.
    static let maxLag = 0.8
    /// A Markdown span held for its closing marker is given up on after this many characters.
    static let spanLimit = 300
    /// Tailwind's `ease-out`, for the fade and the color transition alike.
    static let easing = CubicEasing(0, 0, 0.2, 1)
    /// `color-mix(in oklch, rose-300 p%, rose-500)`, p growing with the word's distance from the newest.
    static func highlight(_ distance: Int) -> OKLab {
        // Tailwind rose-500 and rose-300.
        let newest = (l: 0.645, c: 0.246, h: 16.439), oldest = (l: 0.81, c: 0.117, h: 11.638)
        let t = spread > 1 ? Double(distance)/Double(spread-1) : 0
        return OKLab(l: newest.l+(oldest.l-newest.l)*t, c: newest.c+(oldest.c-newest.c)*t, h: newest.h+(oldest.h-newest.h)*t)
    }
}

/// A color in Oklab, where CSS interpolates color transitions.
struct OKLab: Equatable {
    var l, a, b, alpha: Double
    init(l: Double, a: Double, b: Double, alpha: Double = 1) { self.l = l; self.a = a; self.b = b; self.alpha = alpha }
    init(l: Double, c: Double, h: Double) { self.init(l: l, a: c*cos(h * .pi/180), b: c*sin(h * .pi/180)) }
    init(_ color: TokenColor) {
        #if os(macOS)
        let color = color.usingColorSpace(.extendedSRGB) ?? color
        let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent, alpha = color.alphaComponent
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        func linear(_ value: CGFloat) -> Double {
            let x = abs(Double(value))
            return (x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055, 2.4)) * (value < 0 ? -1 : 1)
        }
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.4122214708*r + 0.5363325363*g + 0.0514459929*b)
        let m = cbrt(0.2119034982*r + 0.6806995451*g + 0.1073969566*b)
        let s = cbrt(0.0883024619*r + 0.2817188376*g + 0.6299787005*b)
        self.init(l: 0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
                  a: 1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
                  b: 0.0259040371*l + 0.7827717662*m - 0.8086757660*s, alpha: Double(alpha))
    }
    /// Extended sRGB, so rose-500's wide-gamut red survives on P3 displays.
    var color: TokenColor {
        let l = pow(self.l + 0.3963377774*a + 0.2158037573*b, 3)
        let m = pow(self.l - 0.1055613458*a - 0.0638541728*b, 3)
        let s = pow(self.l - 0.0894841775*a - 1.2914855480*b, 3)
        func encoded(_ value: Double) -> CGFloat {
            let x = abs(value)
            return CGFloat((x <= 0.0031308 ? 12.92*x : 1.055*pow(x, 1/2.4)-0.055) * (value < 0 ? -1 : 1))
        }
        var components = [encoded(4.0767416621*l - 3.3077115913*m + 0.2309699292*s),
                          encoded(-1.2684380046*l + 2.6097574011*m - 0.3413193965*s),
                          encoded(-0.0041960863*l - 0.7034186147*m + 1.7076147010*s), CGFloat(alpha)]
        #if os(macOS)
        return NSColor(colorSpace: .extendedSRGB, components: &components, count: 4)
        #else
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        return UIColor(cgColor: CGColor(colorSpace: space, components: components)!)
        #endif
    }
    func mixed(with other: OKLab, _ t: Double) -> OKLab {
        OKLab(l: l+(other.l-l)*t, a: a+(other.a-a)*t, b: b+(other.b-b)*t, alpha: alpha+(other.alpha-alpha)*t)
    }
}

/// A streamed answer played out a word at a time with ``TokenMotion``. Words split as in the
/// exploration, `\s*\S+`. Everything that has arrived is laid out up front to keep wrapping
/// stable; words not shown yet are painted clear. The mobile sheet sizes to `newest` instead
/// of reserving space for every queued word.
struct TokenStream {
    struct Entrance: Equatable {
        let range: NSRange
        /// Eased progress of the existing fade-in, from blurred/rightward to sharp/resting.
        let progress: Double
    }
    /// A laid-out word, shown from `due`. While highlighted, `tint` is its distance from the
    /// newest shown word, nil once it takes the text color; color changes transition from
    /// `from`, starting at `changed`.
    private struct Word { var range: NSRange, due: Double, from: OKLab, tint: Int?, changed: Double }
    private var received: NSString = ""
    private var isFinished = false, wasDone = false
    private var words: [Word] = []
    private var shown = 0, clock = 0.0
    private var lastArrival: Double?, scheduleEnd = -Double.infinity
    /// The text color words settle into.
    var base = OKLab(l: 0, a: 0, b: 0)

    var isEmpty: Bool { received.length == 0 }
    /// Laid-out words are still waiting to be shown.
    var isRevealing: Bool { shown < words.count }
    private var isDone: Bool { isFinished && !isRevealing }
    /// The text to lay out: every whole word that has arrived, short of a Markdown span still
    /// waiting for its closing marker, so `**March` never flashes its asterisks.
    var text: String { received.substring(to: Self.readyEnd(received, finished: isFinished)) }
    /// Where the words not shown yet start in the laid-out text.
    var hiddenFrom: Int? { isRevealing ? words[shown].range.location : nil }
    /// The newest shown word.
    var newest: NSRange? { shown > 0 ? words[shown-1].range : nil }

    /// The model's text so far.
    mutating func receive(_ text: String) { received = text as NSString }
    /// The model is done: its last word is whole, and once it's shown the highlight fades.
    mutating func finish() { isFinished = true }

    /// Matches the words to ``text`` as displayed, after Markdown, and schedules new words to
    /// play out at the pace they arrived.
    mutating func place(in display: NSString, at now: Double) {
        let ranges = Self.wordRanges(display)
        if ranges.count < words.count { words.removeLast(words.count-ranges.count); shown = min(shown, words.count) }
        for index in words.indices { words[index].range = ranges[index] }
        let count = ranges.count-words.count
        guard count > 0 else { return }
        let k = Double(count)
        let gap = lastArrival.map { now-$0 } ?? k/TokenMotion.wordsPerSecond
        var interval = min(max(gap, k/TokenMotion.fastest), k/TokenMotion.slowest)
        let start: Double, buffered = scheduleEnd-now
        if buffered > 0 {
            // Keep about `lead` queued: a little slower while short of it, faster while over.
            start = scheduleEnd
            interval *= min(1+TokenMotion.drift, max(1-TokenMotion.drift, 1+(TokenMotion.lead-buffered)/(2*TokenMotion.lead)))
        } else { start = now+(words.isEmpty ? TokenMotion.initialLead : TokenMotion.lead) }
        interval = max(k/TokenMotion.fastest, min(interval, now+TokenMotion.maxLag-start))
        for index in 0..<count {
            words.append(Word(range: ranges[words.count], due: start+interval*Double(index)/k, from: base, tint: nil, changed: -.infinity))
        }
        scheduleEnd = start+interval; lastArrival = now
    }
    /// Shows the words that are due. True when a word appeared.
    mutating func step(at now: Double) -> Bool {
        clock = now
        let before = shown
        while shown < words.count && words[shown].due <= now { shown += 1 }
        if shown != before || isDone != wasDone { retint(firstNew: before); wasDone = isDone }
        return shown != before
    }
    /// Shows every laid-out word at once, with no fade or highlight.
    mutating func revealAll(at now: Double) {
        clock = now; shown = words.count; scheduleEnd = now; wasDone = isDone
        for index in words.indices { words[index].due = -.infinity; words[index].tint = nil; words[index].changed = -.infinity }
    }
    /// Frames are needed while words are waiting, fading in or changing color.
    var needsFrames: Bool {
        if isRevealing || isDone != wasDone { return true }
        for word in words[..<shown].reversed() {
            if isSettled(word) { break }
            if clock-word.due < TokenMotion.fade || clock-word.changed < TokenMotion.colorTransition { return true }
        }
        return false
    }
    /// The shown words still fading in or tinted, newest first, in their colors now.
    var tints: [(range: NSRange, color: OKLab)] {
        var result: [(range: NSRange, color: OKLab)] = []
        for word in words[..<shown].reversed() {
            if isSettled(word) { break }
            var color = current(word)
            color.alpha *= TokenMotion.easing((clock-word.due)/TokenMotion.fade)
            result.append((word.range, color))
        }
        return result
    }
    var entrances: [Entrance] {
        words[..<shown].reversed().prefix { clock-$0.due < TokenMotion.fade }.map {
            Entrance(range: $0.range, progress: TokenMotion.easing((clock-$0.due)/TokenMotion.fade))
        }
    }

    // Older words were shown and took the text color first, so the first settled word from
    // the newest means every word before it has settled too.
    private func isSettled(_ word: Word) -> Bool {
        word.tint == nil && clock-word.due >= TokenMotion.fade && clock-word.changed >= TokenMotion.colorTransition
    }
    private func color(_ tint: Int?) -> OKLab { tint.map(TokenMotion.highlight) ?? base }
    private func current(_ word: Word) -> OKLab {
        word.from.mixed(with: color(word.tint), TokenMotion.easing((clock-word.changed)/TokenMotion.colorTransition))
    }
    /// Words appear in their color; after that each change is a transition. The newest words are
    /// highlighted while streaming, and the last word of the answer never is, as in the exploration.
    private mutating func retint(firstNew: Int) {
        for index in (0..<shown).reversed() {
            let distance = shown-1-index
            let target = !isDone && distance < TokenMotion.spread ? distance : nil
            if index >= firstNew { words[index].tint = target; words[index].from = color(target) }
            else if target != words[index].tint {
                words[index].from = current(words[index]); words[index].tint = target; words[index].changed = clock
            } else if target == nil && isSettled(words[index]) { break }
        }
    }

    private static func isSpace(_ character: unichar) -> Bool {
        UnicodeScalar(character).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
    }
    /// The end of the last whole word outside an open code span, bold, italic or link.
    private static func readyEnd(_ text: NSString, finished: Bool) -> Int {
        let length = text.length
        guard !finished else { return length }
        func at(_ index: Int) -> unichar? { index >= 0 && index < length ? text.character(at: index) : nil }
        let backslash = unichar(92), backtick = unichar(96), star = unichar(42)
        let openBracket = unichar(91), closeBracket = unichar(93), openParen = unichar(40), closeParen = unichar(41)
        var ready = 0, index = 0, inWord = false, openedAt = 0
        var code = false, bold = false, italic = false, link = 0
        while index < length {
            let character = text.character(at: index), space = isSpace(character)
            let wasOpen = code || bold || italic || link > 0
            if inWord && space && !wasOpen { ready = index }
            switch character {
            case backslash: index += 1
            case backtick: code.toggle()
            case star where !code:
                if at(index+1) == star { bold.toggle(); index += 1 }
                else if italic { if let previous = at(index-1), !isSpace(previous) { italic = false } }
                else if let next = at(index+1), !isSpace(next) { italic = true }
            case openBracket where !code && link == 0: link = 1
            // A link's text stays open until what follows the bracket shows whether a URL comes next.
            case closeBracket where link == 1 && index+1 < length:
                if at(index+1) == openParen { link = 2; index += 1 } else { link = 0 }
            case closeParen where link == 2: link = 0
            default: break
            }
            let isOpen = code || bold || italic || link > 0
            if isOpen && !wasOpen { openedAt = index }
            // A marker that never closes stops holding the text back after a while.
            if isOpen && index-openedAt > TokenMotion.spanLimit { code = false; bold = false; italic = false; link = 0 }
            inWord = !space
            index += 1
        }
        return ready
    }
    /// Each word with the whitespace before it, in UTF-16 offsets.
    private static func wordRanges(_ text: NSString) -> [NSRange] {
        var ranges: [NSRange] = [], start = 0, inWord = false
        for index in 0..<text.length {
            let space = isSpace(text.character(at: index))
            if inWord && space { ranges.append(NSRange(location: start, length: index-start)); start = index }
            inWord = !space
        }
        if inWord { ranges.append(NSRange(location: start, length: text.length-start)) }
        return ranges
    }
}
