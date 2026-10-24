import Foundation

/// Only real background time counts. Control Centre, alerts and other inactive transitions
/// leave the browser alone. ContinuousClock includes sleep without following wall-clock changes.
@MainActor final class BackgroundSearch {
    static let timeout: Duration = .seconds(5 * 60)
    private var backgroundedAt: ContinuousClock.Instant?
    private var revision = 0

    func enteredBackground(at now: ContinuousClock.Instant = ContinuousClock().now) {
        cancel()
        backgroundedAt = now
    }

    func becameActive(at now: ContinuousClock.Instant = ContinuousClock().now,
                      reopen: @escaping @MainActor () -> Void) {
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        guard backgroundedAt.duration(to: now) >= Self.timeout else { return }
        let activation = revision
        // Let links and Home Screen actions delivered with activation take priority. They
        // cancel this request whether they arrive before or after becameActive.
        DispatchQueue.main.async { [weak self] in
            guard let self, revision == activation else { return }
            reopen()
        }
    }

    func cancel() {
        backgroundedAt = nil
        revision += 1
    }
}
