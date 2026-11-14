import AVFoundation
import Speech
import XCTest
@testable import RiseCore

final class SpeechTranscriptionTests: XCTestCase {
    /// `words` spoken by macOS's own voice, recorded as a Mac's microphone gives it: 48 kHz floats.
    private func spoken(_ words: String) throws -> AVAudioFile {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RiseSpeech-\(UUID().uuidString).caf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", url.path, "--data-format=LEF32@48000", words]
        try say.run(); say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("say couldn't speak") }
        return try AVAudioFile(forReading: url)
    }
    /// The file in 1024-frame buffers, as an audio tap hands them over.
    private func buffers(_ file: AVAudioFile) -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024),
                  (try? file.read(into: buffer, frameCount: 1024)) != nil, buffer.frameLength > 0 else { break }
            buffers.append(buffer)
        }
        return buffers
    }
    @available(macOS 26, *)
    private func transcription(for file: AVAudioFile) async throws -> SpeechTranscription {
        let english = Locale(identifier: "en_US")
        guard SpeechTranscriber.isAvailable, await SpeechTranscriber.installedLocales.contains(where: { $0.language.languageCode == "en" }) else {
            throw XCTSkip("No English speech model installed")
        }
        return try await SpeechTranscription.start(languages: [english], recording: file.processingFormat)
    }

    func testSpokenWordsComeOutAsTextFromAMicrophonesFormat() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let file = try spoken("Hello there. This is a quick test of dictation in the chat.")
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        let transcription = try await transcription(for: file)
        XCTAssertEqual(transcription.locale.language.languageCode, "en")
        for buffer in buffers(file) { try transcription.append(buffer) }
        let text = try await transcription.finish()
        // Each phrase joined with its own space, punctuated and capitalised by the model.
        XCTAssertTrue(text.lowercased().contains("quick test of dictation"), text)
        XCTAssertTrue(text.hasPrefix("Hello"), text)
        XCTAssertFalse(text.contains("  "), text)
        XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testNothingSaidIsNoWords() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let file = try spoken("Hi")
        let transcription = try await transcription(for: file)
        // A second of silence, at the microphone's format.
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
        silence.frameLength = 48_000
        try transcription.append(silence)
        let text = try await transcription.finish()
        XCTAssertTrue(text.isEmpty, text)
    }

    func testCancellingEndsWithoutWaitingForWords() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let file = try spoken("This will not be kept.")
        let transcription = try await transcription(for: file)
        for buffer in buffers(file).prefix(10) { try transcription.append(buffer) }
        let started = Date()
        await transcription.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testLevelRunsFromAQuietRoomToARaisedVoice() throws {
        XCTAssertEqual(DictationLevel.of(rms: 0), 0)
        XCTAssertEqual(DictationLevel.of(rms: 0.001), 0)                       // -60 dB
        XCTAssertEqual(DictationLevel.of(rms: 0.01), 0.25, accuracy: 0.001)    // -40 dB
        XCTAssertEqual(DictationLevel.of(rms: 0.0316), 0.5, accuracy: 0.01)    // -30 dB
        XCTAssertEqual(DictationLevel.of(rms: 0.5), 1)                         // -6 dB
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        XCTAssertEqual(DictationLevel.of(buffer), 0, "Silence")
        for frame in 0..<480 { buffer.floatChannelData![0][frame] = 0.01 * sin(Float(frame) / 480 * 2 * Float.pi * 10) }
        // A sine's RMS is its peak over √2: -43 dB.
        XCTAssertEqual(DictationLevel.of(buffer), 0.175, accuracy: 0.01)
    }

    func testDictatedWordsAreSpacedFromTheWordsAroundThem() {
        XCTAssertEqual(DictationInsertion.text("  Hello there. ", in: "", replacing: NSRange(location: 0, length: 0)), "Hello there.")
        // After a word, then before one.
        XCTAssertEqual(DictationInsertion.text("and more", in: "Some words", replacing: NSRange(location: 10, length: 0)), " and more")
        XCTAssertEqual(DictationInsertion.text("Quickly", in: "Read this", replacing: NSRange(location: 0, length: 0)), "Quickly ")
        // Over a selection, between the words either side of it.
        XCTAssertEqual(DictationInsertion.text("good", in: "A bad idea", replacing: NSRange(location: 2, length: 3)), "good")
        XCTAssertEqual(DictationInsertion.text("good", in: "Abadidea", replacing: NSRange(location: 1, length: 3)), " good ")
        // None before punctuation, nor after a space or a new line.
        XCTAssertEqual(DictationInsertion.text("the end", in: "Is this?", replacing: NSRange(location: 7, length: 0)), " the end")
        XCTAssertEqual(DictationInsertion.text("next", in: "One\n", replacing: NSRange(location: 4, length: 0)), "next")
        XCTAssertEqual(DictationInsertion.text("😀 yes", in: "Ok👍", replacing: NSRange(location: 4, length: 0)), " 😀 yes")
        XCTAssertEqual(DictationInsertion.text("   ", in: "Words", replacing: NSRange(location: 5, length: 0)), "")
    }
}
