import Foundation
import NaturalLanguage

/// Prefer the actual article over an absent or incorrect HTML language tag.
enum PageTranslationLanguage {
    static func identify(sample: String, declared: String) -> String? {
        let text = String(sample.prefix(6000))
        if text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 30 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
               language != .undetermined, confidence >= 0.65 {
                return language.rawValue
            }
        }
        let tag = declared.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        guard tag.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else { return nil }
        return Locale.Language(identifier: tag).minimalIdentifier
    }
    static func isEnglish(_ language: String) -> Bool {
        Locale.Language(identifier: language).languageCode?.identifier == "en"
    }
}
