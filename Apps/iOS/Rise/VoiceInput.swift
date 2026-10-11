import AVFoundation
import CoreHaptics
import os
import Speech

/// Holding New Page records a search to say rather than type: the microphone's level drives the
/// button's waveform, a soft haptic hum runs while it listens, and letting go transcribes what was
/// said on device with iOS's speech-to-text model (`SpeechAnalyzer` with `SpeechTranscriber`, or
/// `DictationTranscriber` where the newer model isn't available).
@MainActor final class VoiceInput {
    /// The waveform's bars.
    static let barCount = 7
    private(set) var isRecording = false
    private let meter = LevelMeter()
    private var session: AnyObject?
    private var transcription: Task<String, Never>?
    private var haptics: CHHapticEngine?
    private var hum: CHHapticAdvancedPatternPlayer?

    /// How loud the microphone is now, from 0 to 1.
    var level: Float { meter.level }

    static var isSupported: Bool {
        if #available(iOS 26, *) { true } else { false }
    }

    /// Starts listening, when the microphone and speech recognition are allowed. The first time,
    /// it asks for them instead, and listens from the next hold.
    func begin() -> Bool {
        guard #available(iOS 26, *), !isRecording else { return false }
        let microphone = AVAudioApplication.shared.recordPermission
        let speech = SFSpeechRecognizer.authorizationStatus()
        guard microphone == .granted, speech == .authorized else {
            if microphone == .undetermined || speech == .notDetermined { Self.requestPermissions() }
            return false
        }
        let session = VoiceSession(meter: meter)
        do { try session.startRecording() } catch { return false }
        self.session = session
        transcription = Task { (try? await session.transcribe()) ?? "" }
        isRecording = true
        startHum()
        return true
    }

    /// Stops listening; the transcription finishes in the background.
    func finish() -> Task<String, Never> {
        stopListening()
        let transcription = transcription ?? Task { "" }
        self.transcription = nil
        return transcription
    }

    /// Stops listening and discards what was said.
    func cancel() {
        stopListening()
        transcription?.cancel()
        transcription = nil
    }

    /// Fetches the speech model ahead of the first hold, so that one transcribes at once.
    static func prepare() {
        guard #available(iOS 26, *) else { return }
        Task.detached(priority: .utility) { await VoiceSession.installAssets() }
    }

    private func stopListening() {
        guard isRecording else { return }
        isRecording = false
        if #available(iOS 26, *) { (session as? VoiceSession)?.stopRecording() }
        session = nil
        stopHum()
    }

    private static func requestPermissions() {
        AVAudioApplication.requestRecordPermission { _ in
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
    }

    /// A strong, sharp click as listening starts, then a constant, soft hum, so it can be felt
    /// that it's listening.
    private func startHum() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try haptics ?? CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            try engine.start()
            haptics = engine
            let click = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 1),
            ], relativeTime: 0)
            try engine.makePlayer(with: CHHapticPattern(events: [click], parameters: [])).start(atTime: CHHapticTimeImmediate)
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.22),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0),
            ], relativeTime: 0, duration: 30)
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            player.loopEnabled = true
            // Just after the click, so it stands apart.
            try player.start(atTime: engine.currentTime+0.12)
            hum = player
        } catch {
            hum = nil
        }
    }

    private func stopHum() {
        try? hum?.stop(atTime: CHHapticTimeImmediate)
        hum = nil
        haptics?.stop()
    }
}

/// The microphone's latest level, written on the audio thread and read for the waveform.
final class LevelMeter: Sendable {
    private let state = OSAllocatedUnfairLock<Float>(initialState: 0)
    var level: Float { state.withLock { $0 } }

    /// Normal speech at the microphone, unprocessed, sits around -45 to -25 dB; that range fills
    /// most of the bars, eased so quieter speech still lifts them.
    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index]*samples[index] }
        let decibels = 20*log10(max(1e-7, (sum/Float(buffer.frameLength)).squareRoot()))
        let level = pow(min(1, max(0, (decibels+58)/36)), 0.75)
        state.withLock { $0 = level }
    }
}

/// An audio buffer handed from the audio thread to the transcription, which alone uses it after.
private struct Recorded: @unchecked Sendable { let buffer: AVAudioPCMBuffer }

/// One hold's recording and its transcription.
@available(iOS 26, *)
private final class VoiceSession: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let meter: LevelMeter
    private let recorded: AsyncStream<Recorded>
    private let recording: AsyncStream<Recorded>.Continuation
    private var inputFormat: AVAudioFormat?

    init(meter: LevelMeter) {
        self.meter = meter
        (recorded, recording) = AsyncStream.makeStream(of: Recorded.self)
    }

    func startRecording() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
        // Otherwise iOS mutes haptics while the microphone records, and with them the hum.
        try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try audio.setActive(true)
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        inputFormat = format
        let meter = meter, recording = recording
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            meter.measure(buffer)
            recording.yield(Recorded(buffer: buffer))
        }
        engine.prepare()
        try engine.start()
    }

    func stopRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recording.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func locale() async -> Locale {
        if SpeechTranscriber.isAvailable {
            return await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
        }
        return await DictationTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
    }

    private static func module(for locale: Locale) -> any SpeechModule {
        SpeechTranscriber.isAvailable
            ? SpeechTranscriber(locale: locale, preset: .transcription)
            : DictationTranscriber(locale: locale, preset: .shortDictation)
    }

    static func installAssets() async {
        let module = module(for: await locale())
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try? await request.downloadAndInstall()
        }
    }

    /// Transcribes everything recorded, once the recording stops.
    func transcribe() async throws -> String {
        let module = Self.module(for: await Self.locale())
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let inputFormat, let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else { return "" }
        let results: Task<String, Error> = Task {
            var text = ""
            func append(_ part: AttributedString) {
                let piece = String(part.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !piece.isEmpty else { return }
                text += text.isEmpty ? piece : " "+piece
            }
            if let transcriber = module as? SpeechTranscriber {
                for try await result in transcriber.results { append(result.text) }
            } else if let transcriber = module as? DictationTranscriber {
                for try await result in transcriber.results { append(result.text) }
            }
            return text
        }
        let (input, feeding) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try await analyzer.start(inputSequence: input)
        for await chunk in recorded {
            if Task.isCancelled { break }
            if let converted = Self.convert(chunk.buffer, with: converter, to: analyzerFormat) {
                feeding.yield(AnalyzerInput(buffer: converted))
            }
        }
        feeding.finish()
        if Task.isCancelled {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            return ""
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate/buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength)*ratio).rounded(.up))+1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
