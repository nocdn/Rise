import AVFoundation
import Speech

/// Speech to text on the Mac itself, with the newest model it has: SpeechAnalyzer's
/// SpeechTranscriber (macOS 26), or, for a language that one doesn't know, its dictation model.
/// Audio goes in as it's heard, in whatever format it's recorded in, and the words come out once
/// it's finished. Needs no permission of its own beyond the microphone's, and downloads the
/// language's model the first time, if the Mac doesn't have it yet.
@available(macOS 26, *)
public final class SpeechTranscription: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// No model on this Mac knows any of the languages.
        case unsupportedLanguage
    }
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let words: Task<String, Error>
    /// From the recording's format to the model's; `append` alone touches it, one buffer at a time.
    private var converter: AVAudioConverter?
    /// The language it's listening for.
    public let locale: Locale

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation,
                 words: Task<String, Error>, locale: Locale) {
        self.analyzer = analyzer; self.format = format; self.input = input; self.words = words; self.locale = locale
    }

    /// Ready to listen in the first of `languages` a model knows, the person's own by default,
    /// for audio recorded in `recording` (the model's own format otherwise).
    public static func start(languages: [Locale] = preferredLanguages, recording: AVAudioFormat? = nil) async throws -> SpeechTranscription {
        guard let (module, locale, words) = await module(for: languages) else { throw Failure.unsupportedLanguage }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await request.downloadAndInstall() }
        // Kept a little while after, so the next dictation starts at once.
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: recording) else {
            throw Failure.unsupportedLanguage
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        return SpeechTranscription(analyzer: analyzer, format: format, input: input, words: words, locale: locale)
    }

    /// The person's language as the Mac's set to, then the others they read.
    public static var preferredLanguages: [Locale] { [Locale.current] + Locale.preferredLanguages.map(Locale.init(identifier:)) }

    /// SpeechTranscriber where it knows one of the languages, the dictation model where only it
    /// does, and the task that gathers its words as it settles on them.
    private static func module(for languages: [Locale]) async -> (any SpeechModule, Locale, Task<String, Error>)? {
        if SpeechTranscriber.isAvailable {
            for language in languages {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language) else { continue }
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                return (transcriber, locale, Task { try await joined(transcriber.results.map { ($0.isFinal, String($0.text.characters)) }) })
            }
        }
        for language in languages {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: language) else { continue }
            let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
            return (transcriber, locale, Task { try await joined(transcriber.results.map { ($0.isFinal, String($0.text.characters)) }) })
        }
        return nil
    }
    /// Each phrase it settled on, in order: a phrase after the first starts with its own space.
    private static func joined<Phrases: AsyncSequence>(_ phrases: Phrases) async throws -> String where Phrases.Element == (Bool, String) {
        var text = ""
        for try await (final, phrase) in phrases where final { text += phrase }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Audio heard, in any format: it's converted to the model's. Call from one place at a time.
    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        if buffer.format == format { input.yield(AnalyzerInput(buffer: buffer)); return }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let ratio = format.sampleRate/buffer.format.sampleRate
        // Room for what the converter held back from the last buffer, too.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength)*ratio).rounded(.up))+1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var given = false, failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData
            return buffer
        }
        if status == .error, let failure { throw failure }
        if converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
    }

    /// Everything heard, in words, once the model has settled on the last of them.
    public func finish() async throws -> String {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await words.value
    }
    /// Stops listening, with nothing to show for it.
    public func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        words.cancel()
    }
}

/// How loud what the microphone hears is, for a waveform.
public enum DictationLevel {
    /// How loud `buffer` is, 0 for silence to 1 for shouting: its loudness in decibels, from a
    /// quiet room's -50 dB to a raised voice's -10, as a waveform shows it.
    public static func of(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        // The first channel: a microphone's others say the same.
        for frame in 0..<frames { let sample = channels[0][frame]; sum += sample*sample }
        return of(rms: sqrt(sum/Float(frames)))
    }
    public static func of(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20*log10(rms)
        return min(1, max(0, (decibels+50)/40))
    }
}

/// Dictated words going in where the cursor is, or over the selection: a space between them and
/// a word either side, none before punctuation.
public enum DictationInsertion {
    public static func text(_ words: String, after before: Character?, before after: Character?) -> String {
        var text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let before, !before.isWhitespace { text = " "+text }
        if let after, !after.isWhitespace, !after.isPunctuation { text += " " }
        return text
    }
    /// What goes in for `range` of `string`.
    public static func text(_ words: String, in string: String, replacing range: NSRange) -> String {
        let characters = string as NSString
        let before = range.location > 0 ? Character(characters.substring(with: characters.rangeOfComposedCharacterSequence(at: range.location-1))) : nil
        let end = NSMaxRange(range)
        let after = end < characters.length ? Character(characters.substring(with: characters.rangeOfComposedCharacterSequence(at: end))) : nil
        return text(words, after: before, before: after)
    }
}
