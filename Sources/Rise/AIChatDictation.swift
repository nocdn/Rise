import AppKit
import AVFoundation
import RiseCore

/// Dictating a question: the microphone heard through AVAudioEngine, its loudness for the
/// waveform as it comes, and its words from the Mac's own speech model (`SpeechTranscription`)
/// once it's stopped. The model starts listening as the microphone does, so stopping only waits
/// for it to settle on the last few words.
@MainActor final class AIChatDictation {
    enum Phase: Equatable { case idle, listening, transcribing }
    private(set) var phase = Phase.idle { didSet { if phase != oldValue { onPhase?(phase) } } }
    var onPhase: ((Phase) -> Void)?
    /// How loud it is, 0 to 1, as each buffer is heard.
    var onLevel: ((CGFloat) -> Void)?
    /// What was said, once it's worked out; empty when nothing was.
    var onWords: ((String) -> Void)?
    /// Why it couldn't listen or work the words out, in a few words.
    var onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var heard: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var work: Task<Void, Never>?
    /// Each dictation's own, so one cancelled late says nothing.
    private var session = 0

    static var isAvailable: Bool { if #available(macOS 26, *) { return true } else { return false } }

    func toggle() { phase == .idle ? start() : phase == .listening ? stop() : () }

    func start() {
        guard phase == .idle else { return }
        session += 1
        let session = session
        phase = .listening
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: listen(session)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session == session, self.phase == .listening else { return }
                    if granted { self.listen(session) } else { self.fail(Self.microphoneOff) }
                }
            }
        default: fail(Self.microphoneOff)
        }
    }
    static let microphoneOff = "Turn on the microphone for Rise in System Settings"

    private func listen(_ session: Int) {
        guard #available(macOS 26, *) else { fail("Dictation needs macOS 26"); return }
        let engine = AVAudioEngine(), input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail("No microphone to listen with"); return }
        let (buffers, heard) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = CGFloat(DictationLevel.of(buffer))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session == session, self.phase == .listening else { return }
                self.onLevel?(level)
            }
            // The tap's buffer is the engine's to reuse.
            if let copy = Self.copy(buffer) { heard.yield(copy) }
        }
        do { engine.prepare(); try engine.start() } catch {
            input.removeTap(onBus: 0); fail("The microphone couldn’t start"); return
        }
        self.engine = engine; self.heard = heard
        // The model gets ready while the microphone already hears; what it heard waits for it.
        work = Task.detached(priority: .userInitiated) { [weak self] in
            var transcription: SpeechTranscription?
            do {
                let started = try await SpeechTranscription.start(recording: format)
                transcription = started
                for await buffer in buffers { try started.append(buffer) }
                if Task.isCancelled { await started.cancel(); return }
                let words = try await started.finish()
                await self?.finish(session, words: words)
            } catch {
                await transcription?.cancel()
                guard !Task.isCancelled else { return }
                let reason = (error as? SpeechTranscription.Failure) == .unsupportedLanguage
                    ? "Dictation doesn’t know your language yet" : "Couldn’t work out what was said"
                await self?.finish(session, failure: reason)
            }
        }
    }

    /// Stops listening, and works out what was said.
    func stop() {
        guard phase == .listening else { return }
        stopMicrophone()
        // Not listening yet (asking for the microphone), there's nothing to work out.
        guard work != nil else { phase = .idle; return }
        phase = .transcribing
    }
    /// Stops listening or working out the words, with nothing to show for it.
    func cancel() {
        guard phase != .idle else { return }
        session += 1
        stopMicrophone()
        work?.cancel(); work = nil
        phase = .idle
    }
    private func stopMicrophone() {
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        heard?.finish(); heard = nil
    }
    private func finish(_ session: Int, words: String? = nil, failure: String? = nil) {
        guard session == self.session, phase != .idle else { return }
        stopMicrophone(); work = nil
        phase = .idle
        if let failure { onFailure?(failure) } else { onWords?(words ?? "") }
    }
    private func fail(_ reason: String) {
        stopMicrophone(); work?.cancel(); work = nil
        phase = .idle
        onFailure?(reason)
    }

    nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, destination) in zip(from, to) {
            guard let data = source.mData, let target = destination.mData else { continue }
            memcpy(target, data, Int(min(source.mDataByteSize, destination.mDataByteSize)))
        }
        return copy
    }
}

/// Dictation's waveform, between ⋯ and the microphone: a line of grey dots. What's heard comes in
/// at its right, by the microphone, each dot growing smoothly to how loud it was, and the line
/// drifts left, dissolving at both ends as the tab list does at its scrolled edges. Stopped, the
/// dots settle back and one wave sweeps to and fro over them while the words are worked out.
@MainActor final class AIChatWaveform: FlippedView {
    enum Mode { case listening, transcribing }
    /// A dot, the room it and its gap take, and the tallest the loudest voice makes one.
    static let dot: CGFloat = 3, pitch: CGFloat = 6, tallest: CGFloat = 20
    /// How fast the line drifts left: a dot's room every tenth of a second.
    static let speed: CGFloat = 60
    /// How quickly a dot grows to its height, per second.
    static let growth: CGFloat = 22
    /// The transcribing wave: its height above a dot's, its width, and a sweep there and back.
    static let waveHeight: CGFloat = 13, waveWidth: CGFloat = 12, sweep: CFTimeInterval = 1.5
    private let shape = CAShapeLayer(), fade = CAGradientLayer()
    /// Each dot's height, as shown and as it's growing to, oldest (leftmost) first.
    private(set) var heights: [CGFloat] = [], targets: [CGFloat] = []
    /// How far the line has drifted since the newest dot came in, up to a dot's room.
    private var drift: CGFloat = 0, speed: CGFloat = 0
    /// The loudest heard since the newest dot came in.
    private var loudest: CGFloat = 0
    private(set) var mode = Mode.listening
    private var wave: CGFloat = 0, waveTime: CFTimeInterval = 0
    private var link: CADisplayLink?, lastTick: CFTimeInterval?
    var isRunning: Bool { link != nil }
    var color = NSColor.gray { didSet { shape.fillColor = color.cgColor } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(shape)
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.actions = ["position": NSNull(), "bounds": NSNull(), "locations": NSNull()]
        layer?.mask = fade
        isHidden = true; alphaValue = 0
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A fresh line of resting dots, listening.
    func start() {
        mode = .listening; speed = Self.speed; wave = 0; drift = 0; loudest = 0
        heights = []; targets = []; fill()
        setAccessibilityLabel("Listening")
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        run()
    }
    /// How loud it is now, 0 to 1: the newest dot grows to the loudest since it came in.
    func hear(_ level: CGFloat) {
        guard mode == .listening else { return }
        loudest = max(loudest, min(1, max(0, level)))
        if !targets.isEmpty { targets[targets.count-1] = height(for: loudest) }
    }
    /// The line stops, its dots settle, and the wave sweeps over them.
    func transcribe() {
        guard mode == .listening else { return }
        mode = .transcribing; waveTime = 0
        setAccessibilityLabel("Transcribing")
        run()
    }
    /// Fades away.
    func stop() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue < 0.01 else { return }
                self.isHidden = true; self.link?.invalidate(); self.link = nil
            }
        }
    }

    private func height(for level: CGFloat) -> CGFloat { Self.dot+(Self.tallest-Self.dot)*level }
    /// Enough dots for the width, and one coming in past each end.
    private var count: Int { Int(ceil(bounds.width/Self.pitch))+2 }
    private func fill() {
        while heights.count < count { heights.insert(Self.dot, at: 0); targets.insert(Self.dot, at: 0) }
        if heights.count > count { heights.removeFirst(heights.count-count); targets.removeFirst(targets.count-count) }
    }
    /// Dot `index`'s middle, from the left.
    func x(of index: Int) -> CGFloat {
        bounds.width+Self.pitch/2-CGFloat(heights.count-1-index)*Self.pitch-drift
    }
    private func run() {
        guard link == nil, window != nil else { render(); return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { link?.invalidate(); link = nil } else if !isHidden { run() }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = CGFloat(min(0.05, now-(lastTick ?? now))); lastTick = now
        advance(dt)
    }
    /// Moves the line on by `dt` seconds.
    func advance(_ dt: CGFloat) {
        fill()
        if mode == .listening {
            drift += speed*dt
            while drift >= Self.pitch {
                // A new dot comes in at the right, the oldest goes out at the left.
                drift -= Self.pitch; loudest = 0
                heights.append(Self.dot); targets.append(Self.dot)
                heights.removeFirst(); targets.removeFirst()
            }
        } else {
            // The line comes to rest as the wave grows over it.
            drift = max(0, drift-drift*min(1, 8*dt))
            wave += (1-wave)*min(1, 5*dt)
            waveTime += CFTimeInterval(dt)
            let middle = bounds.width/2, reach = bounds.width*0.3
            let center = middle+reach*CGFloat(sin(2*Double.pi*waveTime/Self.sweep))
            for index in targets.indices {
                let distance = (x(of: index)-center)/Self.waveWidth
                targets[index] = Self.dot+Self.waveHeight*wave*exp(-distance*distance)
            }
        }
        let step = min(1, Self.growth*dt)
        for index in heights.indices { heights[index] += (targets[index]-heights[index])*step }
        render()
    }
    override func layout() { super.layout(); fill(); render() }
    private func render() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds; fade.frame = bounds
        let width = max(1, bounds.width), depth = SidebarScrollCues.fadeDepth(height: width)/width
        fade.locations = [0, NSNumber(value: Double(depth)), NSNumber(value: Double(1-depth)), 1]
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let path = CGMutablePath(), mid = bounds.midY
        for (index, height) in heights.enumerated() {
            let x = x(of: index)
            guard x > -Self.dot, x < bounds.width+Self.dot else { continue }
            let rect = CGRect(x: x-Self.dot/2, y: mid-height/2, width: Self.dot, height: height)
            path.addRoundedRect(in: rect, cornerWidth: Self.dot/2, cornerHeight: min(Self.dot/2, height/2))
        }
        shape.path = path
        CATransaction.commit()
    }
}
