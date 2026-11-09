import CoreHaptics

/// One haptic engine for every Summarise, started once and kept while Rise is in front.
///
/// Starting an engine takes on the system's audio session, and when that's slow (about 120 ms
/// at times) it holds up the main thread, even started from another: with each Summarise
/// starting its own, about one in three froze for its first 15 frames, by pinch or from More
/// (measured on 8 November, the stall ending as the engine came up each time). Kept running,
/// only the first Summarise after Rise comes to the front waits for one.
@MainActor enum SummariseHaptics {
    /// Core Haptics takes calls from any queue; only starting and stopping go to a worker, and
    /// the engine is handed back here.
    private struct Transfer: @unchecked Sendable { let engine: CHHapticEngine }

    private static var engine: CHHapticEngine?
    private static var running = false, starting = false
    private static var waiting: [@MainActor (CHHapticEngine) -> Void] = []
    private static let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// The engine while it's running, for playing on.
    static var current: CHHapticEngine? { running ? engine : nil }

    /// Hands over the running engine: at once if it's running, otherwise once it has started.
    static func engine(_ ready: @escaping @MainActor (CHHapticEngine) -> Void) {
        if let current { ready(current); return }
        guard supported else { return }
        waiting.append(ready)
        start()
    }

    private static func start() {
        guard !starting else { return }
        starting = true
        let kept = engine.map(Transfer.init)
        Task.detached(priority: .userInitiated) {
            var made: Transfer? = kept
            if made == nil, let engine = try? CHHapticEngine() {
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = false
                // Stopped by the system (Rise going to the back, an interruption) or reset after
                // the haptic server fails, it starts again when next wanted.
                engine.stoppedHandler = { _ in Task { @MainActor in SummariseHaptics.running = false } }
                engine.resetHandler = { Task { @MainActor in SummariseHaptics.running = false } }
                made = Transfer(engine: engine)
            }
            let started = if let made { (try? await made.engine.start()) != nil } else { false }
            await MainActor.run { finishStarting(made, started: started) }
        }
    }

    private static func finishStarting(_ made: Transfer?, started: Bool) {
        starting = false
        engine = made?.engine
        running = started
        let ready = waiting
        waiting = []
        guard started, let engine else { return }
        for hand in ready { hand(engine) }
    }
}
