import UIKit

/// The page as it was when Rise last went to the background, shown over the same tab when Rise
/// next opens from cold, until that page has loaded again behind it. Launch then shows the page
/// someone left rather than an empty one while it loads.
///
/// Only regular tabs are kept, in Caches, on this device. The picture is read and decoded on
/// another core from the start of launch, so it costs the main thread nothing to show.
enum LaunchCover {
    struct Info: Codable, Sendable {
        let tab: UUID
        let url: URL
        let width: Double, height: Double
        let dark: Bool
    }

    private static let folder = URL.cachesDirectory.appendingPathComponent("LaunchCover", isDirectory: true)
    private static let imageURL = folder.appendingPathComponent("page.jpg")
    private static let infoURL = folder.appendingPathComponent("page.json")
    private static let queue = DispatchQueue(label: "Rise.LaunchCover", qos: .userInitiated)

    /// Saves the page off the main thread. The details go last, and are removed first, so a
    /// picture whose write was cut short never matches a tab.
    static func save(_ image: UIImage, info: Info) {
        queue.async {
            guard let json = try? JSONEncoder().encode(info), let data = image.jpegData(compressionQuality: 0.8) else { return }
            let protection: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: infoURL)
            do {
                try data.write(to: imageURL, options: protection)
                try json.write(to: infoURL, options: protection)
            } catch { NSLog("Rise couldn't save the launch cover: %@", error.localizedDescription) }
        }
    }

    static func remove() { queue.async { try? FileManager.default.removeItem(at: folder) } }

    private struct Loaded: @unchecked Sendable { let info: Info; let image: UIImage }
    /// What the reader has found, shared with it under `lock`.
    private final class Slot: @unchecked Sendable {
        let lock = NSLock()
        var started = false, done = false
        var loaded: Loaded?
    }
    private static let slot = Slot()
    @MainActor private static var waiting: ((Info, UIImage) -> Void)?

    /// Starts reading the saved page, as early in launch as possible.
    static func prefetch() {
        slot.lock.lock(); let start = !slot.started; slot.started = true; slot.lock.unlock()
        guard start else { return }
        queue.async {
            var loaded: Loaded?
            if let json = try? Data(contentsOf: infoURL), let info = try? JSONDecoder().decode(Info.self, from: json),
               let image = UIImage(contentsOfFile: imageURL.path)?.preparingForDisplay() {
                loaded = Loaded(info: info, image: image)
            }
            slot.lock.lock(); slot.loaded = loaded; slot.done = true; slot.lock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { deliverToWaiting() } }
        }
    }

    /// Hands over the saved page once, on the main thread: at once if it's already decoded,
    /// otherwise as soon as it is.
    @MainActor static func take(_ apply: @escaping @MainActor (Info, UIImage) -> Void) {
        prefetch()
        slot.lock.lock(); let done = slot.done; slot.lock.unlock()
        if done { takeLoaded().map { apply($0.info, $0.image) } } else { waiting = apply }
    }

    @MainActor private static func deliverToWaiting() {
        guard let apply = waiting else { return }
        waiting = nil
        takeLoaded().map { apply($0.info, $0.image) }
    }

    private static func takeLoaded() -> Loaded? {
        slot.lock.lock(); defer { slot.lock.unlock() }
        let loaded = slot.loaded; slot.loaded = nil
        return loaded
    }
}
