import Foundation

/// Chromium's data sits directly in Rise's folder, as Chrome's sits in `Google/Chrome`: `Default`,
/// `Local State` and the rest beside Rise's own files, whose names it doesn't share. Rise kept it
/// in a `Chromium` folder inside until now; the first launch moves it up, before the engine starts.
enum ChromiumProfileLayout {
    static let legacyName = "Chromium"
    /// Chromium's locks on a running profile, remade at start, so never moved.
    static let locks: Set<String> = ["SingletonLock", "SingletonCookie", "SingletonSocket"]

    /// The folder Chromium's data is in for `base`, moving it there from `base/Chromium` first.
    /// That folder becomes a link back to `base`, so an older Rise still finds the same data. If
    /// the move can't be made safely (a Rise still running on it, or the same name in both
    /// places), the data stays where it was and that's the folder used.
    static func prepare(_ base: URL, files: FileManager = .default, isRunning: (Int32) -> Bool = processIsRunning) -> URL {
        let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
        try? files.createDirectory(at: base, withIntermediateDirectories: true)
        // Already moved, or never there.
        if (try? files.destinationOfSymbolicLink(atPath: legacy.path)) != nil { return base }
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: legacy.path, isDirectory: &isFolder) else { return base }
        guard isFolder.boolValue, let names = try? files.contentsOfDirectory(atPath: legacy.path) else { return legacy }
        if let owner = lockOwner(legacy, files: files), owner != getpid(), isRunning(owner) { return legacy }
        let moving = names.filter { !locks.contains($0) }
        // An earlier move cut short left the rest here, under names not yet above.
        guard !moving.contains(where: { files.fileExists(atPath: base.appendingPathComponent($0).path) || isLink(base.appendingPathComponent($0), files) })
        else { return legacy }
        var moved: [String] = []
        for name in moving {
            do { try files.moveItem(at: legacy.appendingPathComponent(name), to: base.appendingPathComponent(name)); moved.append(name) }
            catch {
                // All or nothing: what went up comes back, and the profile stays whole where it was.
                for name in moved { try? files.moveItem(at: base.appendingPathComponent(name), to: legacy.appendingPathComponent(name)) }
                return legacy
            }
        }
        for name in names where locks.contains(name) { try? files.removeItem(at: legacy.appendingPathComponent(name)) }
        do {
            try files.removeItem(at: legacy)
            try files.createSymbolicLink(atPath: legacy.path, withDestinationPath: ".")
        } catch {}
        return base
    }
    /// The process holding Chromium's lock: `SingletonLock` links to "host-pid".
    private static func lockOwner(_ folder: URL, files: FileManager) -> Int32? {
        guard let target = try? files.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("SingletonLock").path),
              let dash = target.lastIndex(of: "-") else { return nil }
        return Int32(target[target.index(after: dash)...])
    }
    private static func isLink(_ url: URL, _ files: FileManager) -> Bool { (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil }
    static func processIsRunning(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
}
