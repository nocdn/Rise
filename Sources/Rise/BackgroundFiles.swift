import Foundation

/// Rise's smaller files (suggestion icons, pull request summaries, tab search words, bookmarks
/// and downloads) are encoded and written here, in the order they're saved, rather than on the main
/// thread, where a few hundred kilobytes of JSON can take a frame. Each passes a copy of what to
/// save; quitting waits for what's still on its way (`flush`).
enum BackgroundFiles {
    static let queue = DispatchQueue(label: "dev.bartosz.Rise.files", qos: .utility)
    /// Writes what `encode` makes to `url`, replacing it whole. `failed` hears, on the main
    /// thread, of a write that didn't happen, so it can be saved again.
    static func write(to url: URL, failed: (@MainActor @Sendable (Error) -> Void)? = nil, encode: @escaping @Sendable () throws -> Data) {
        queue.async {
            do {
                let data = try encode()
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                if let failed { DispatchQueue.main.async { MainActor.assumeIsolated { failed(error) } } }
            }
        }
    }
    static func flush() { queue.sync {} }
}
