import Foundation

enum WordNetSynonyms {
    private static let index = Bundle.module.url(forResource: "WordNetSynonyms", withExtension: "tsv")
        .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }

    static func lookup(_ word: String) -> String? {
        guard let index else { return nil }
        // Search sorted rows directly so the first lookup doesn't have to decode the full index.
        return index.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
            var lower = 0, upper = buffer.count
            while lower < upper {
                var start = (lower+upper)/2
                while start > lower, buffer[start-1] != 10 { start -= 1 }
                guard let end = buffer[start..<upper].firstIndex(of: 10),
                      let separator = buffer[start..<end].firstIndex(of: 9) else { return nil }
                let key = buffer[start..<separator]
                if key.elementsEqual(word.utf8) {
                    return String(decoding: buffer[(separator+1)..<end], as: UTF8.self)
                }
                if key.lexicographicallyPrecedes(word.utf8) { lower = end+1 }
                else { upper = start }
            }
            return nil
        }
    }
}
