import Foundation
import CoreFoundation

// Port of Torph's text-only segment/diff engine (numbers:false), MIT © 2025 Lochie Axon.
// Reference d79a5aa63226acf97d49c3e34fafb2e85c07b026. See Torph-LICENSE.txt.
// Swift Characters deliberately keep composed graphemes intact during word splits.
public enum TorphText {
    public struct Segment: Equatable, Sendable {
        public var id: String
        public var text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }
    public struct Diff: Sendable {
        public var segments: [Segment]
        public var splits: [String: [Segment]]
    }
    private struct IDs {
        var used: Set<String> = []
        mutating func take(_ base: String) -> String {
            var id = base, i = 1
            while used.contains(id) { id = "\(base)~\(i)"; i += 1 }
            used.insert(id); return id
        }
    }
    public static func segment(_ value: String, locale: String = "en") -> [Segment] {
        var ids = IDs(), output: [Segment] = [], offset = 0
        let byWord = value.contains(" ") || value.contains("\n")
        let lines = value.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 { output.append(.init(id: ids.take("newline-\(offset)"), text: "\n")); offset += 1 }
            let parts: [(String, Int)]
            if byWord, !line.isEmpty {
                let ns = line as NSString
                let tokenizer = CFStringTokenizerCreate(nil, line as CFString, CFRange(location: 0, length: ns.length),
                    CFOptionFlags(kCFStringTokenizerUnitWordBoundary), CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: locale as CFString)))!
                var words: [(String, Int)] = []
                while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
                    let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                    words.append((ns.substring(with: NSRange(location: range.location, length: range.length)), range.location))
                }
                parts = words
            } else {
                var position = 0
                parts = line.map { c in defer { position += String(c).utf16.count }; return (String(c), position) }
            }
            for (part, position) in parts {
                let index = offset+position
                let base = part == " " ? "space-\(index)" : ids.used.contains(part) ? "\(part)-\(index)" : part
                output.append(.init(id: ids.take(base), text: part == " " ? "\u{a0}" : part))
            }
            offset += line.utf16.count
        }
        return output
    }
    private struct Word { var text: String; var segments: [Segment] }
    private static func words(_ segments: [Segment]) -> [Word] {
        var result: [Word] = [], run: [Segment] = []
        func flush() { if !run.isEmpty { result.append(.init(text: run.map(\.text).joined(), segments: run)); run = [] } }
        for segment in segments {
            if segment.text == "\u{a0}" || segment.text == "\n" { flush() } else { run.append(segment) }
        }
        flush(); return result
    }
    /// Forward LCS, including Torph's earliest-match tie breaking for repeated words.
    public static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty, a.count <= 1_000_000/max(1, b.count) else { return [] }
        let stride = b.count+1
        var dp = [Int](repeating: 0, count: (a.count+1)*stride)
        for i in (0..<a.count).reversed() {
            for j in (0..<b.count).reversed() {
                dp[i*stride+j] = a[i] == b[j] ? dp[(i+1)*stride+j+1]+1 : max(dp[(i+1)*stride+j], dp[i*stride+j+1])
            }
        }
        var i = 0, j = 0, matches: [(Int, Int)] = []
        while i < a.count && j < b.count {
            if a[i] == b[j] { matches.append((i,j)); i += 1; j += 1 }
            else if dp[(i+1)*stride+j] >= dp[i*stride+j+1] { i += 1 } else { j += 1 }
        }
        return matches
    }
    public static func diff(_ old: [Segment], to value: String, locale: String = "en") -> Diff {
        let oldWords = words(old)
        if oldWords.count <= 1 && !value.contains(" ") && !value.contains("\n") {
            return Diff(segments: segment(value, locale: locale), splits: [:])
        }
        var newWords: [String] = [], separators: [[String]] = [], pending: [String] = [], run = ""
        func flush() {
            if !run.isEmpty { newWords.append(run); separators.append(pending); pending = []; run = "" }
        }
        for c in value {
            if c == " " || c == "\n" { flush(); pending.append(String(c)) } else { run.append(c) }
        }
        flush()
        guard oldWords.count <= 1_000_000/max(1, newWords.count) else {
            return Diff(segments: segment(value, locale: locale), splits: [:])
        }
        let matches = lcs(oldWords.map(\.text), newWords)
        let oldMatched = Set(matches.map(\.0)), newMatched = Set(matches.map(\.1))
        var reuse = Dictionary(uniqueKeysWithValues: matches.map { ($0.1, $0.0) })
        let oldUnmatched = oldWords.indices.filter { !oldMatched.contains($0) }
        let newUnmatched = newWords.indices.filter { !newMatched.contains($0) }
        var exactUsed: Set<Int> = []
        for ni in newUnmatched {
            if let oi = oldUnmatched.first(where: { !exactUsed.contains($0) && oldWords[$0].text == newWords[ni] }) {
                reuse[ni] = oi; exactUsed.insert(oi)
            }
        }
        func gaps(_ count: Int, _ matched: Set<Int>) -> [Int] {
            var anchors = 0
            return (0..<count).map { i in defer { if matched.contains(i) { anchors += 1 } }; return anchors }
        }
        let oldGaps = gaps(oldWords.count, oldMatched), newGaps = gaps(newWords.count, newMatched)
        let oldCandidates = oldUnmatched.filter { !exactUsed.contains($0) }
        let newCandidates = newUnmatched.filter { reuse[$0] == nil }
        var morph: [Int: Int] = [:], usedOld: Set<Int> = []
        if oldCandidates.count*newCandidates.count <= 2500 {
            for ni in newCandidates {
                var best = 0.4, bestOld: Int?
                let newChars = newWords[ni].map(String.init)
                for oi in oldCandidates where !usedOld.contains(oi) && oldGaps[oi] == newGaps[ni] {
                    let oldChars = oldWords[oi].text.map(String.init)
                    let score = Double(lcs(oldChars, newChars).count)/Double(max(1, max(oldChars.count,newChars.count)))
                    if score > best { best = score; bestOld = oi }
                }
                if let oi = bestOld { morph[ni] = oi; usedOld.insert(oi) }
            }
        }
        var splits: [String: [Segment]] = [:], characterWords: [Int: [Segment]] = [:], ids = IDs()
        for ni in newWords.indices {
            if let oi = reuse[ni] { oldWords[oi].segments.forEach { ids.used.insert($0.id) } }
            else if let oi = morph[ni] {
                // Flatten every word fragment, not just a one-span word. Otherwise a
                // punctuation run ("repository...") indexes whole words as characters.
                let chars = oldWords[oi].segments.flatMap { segment -> [Segment] in
                    guard segment.text.count > 1 else { return [segment] }
                    let parts = segment.text.enumerated().map { Segment(id: "\(segment.id):\($0.offset)", text: String($0.element)) }
                    splits[segment.id] = parts; return parts
                }
                characterWords[oi] = chars; chars.forEach { ids.used.insert($0.id) }
            }
        }
        var output: [Segment] = [], offset = 0
        func push(_ values: [String]) {
            for sep in values {
                output.append(.init(id: ids.take("\(sep == "\n" ? "newline" : "space")-\(offset)"), text: sep == "\n" ? sep : "\u{a0}")); offset += 1
            }
        }
        for ni in newWords.indices {
            push(separators[ni])
            let word = newWords[ni]
            if let oi = reuse[ni] { output.append(contentsOf: oldWords[oi].segments) }
            else if let oi = morph[ni], let chars = characterWords[oi] {
                let newChars = word.map(String.init)
                let paired = Dictionary(uniqueKeysWithValues: lcs(chars.map(\.text),newChars).map { ($0.1,chars[$0.0]) })
                for ci in newChars.indices {
                    output.append(paired[ci] ?? .init(id: ids.take("\(word)~\(ci)"), text: newChars[ci]))
                }
            } else { output.append(.init(id: ids.take(word), text: word)) }
            offset += word.utf16.count
        }
        push(pending)
        // A literal ID-looking word can collide with an inherited split ID. Degrade
        // to fresh unique fragments rather than letting two pieces claim one view.
        guard Set(output.map(\.id)).count == output.count else {
            return Diff(segments: segment(value,locale: locale),splits: [:])
        }
        return Diff(segments: output, splits: splits)
    }
    public static func nearestAnchor(at index: Int, ids: [String], persistent: Set<String>, forwardFirst: Bool = false) -> String? {
        let backward = Array(ids[..<index].reversed()), forward = Array(ids.dropFirst(index+1))
        return (forwardFirst ? forward+backward : backward+forward).first { persistent.contains($0) }
    }
    public static func replacementRuns(ids: [String], members: Set<String>) -> [[String]] {
        var runs: [[String]] = [], run: [String] = []
        func flush() { if run.count >= 6 { runs.append(run) }; run = [] }
        for id in ids { if members.contains(id) { run.append(id) } else { flush() } }
        flush(); return runs
    }
}
