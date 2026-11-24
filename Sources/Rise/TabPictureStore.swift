import AppKit

/// Control-Tab's card pictures, kept beside the session so tabs restored at launch show theirs
/// without loading their pages. Each picture is kept with the address it shows, and a tab only
/// gets its picture back while it's still at that address.
@MainActor final class TabPictureStore {
    private let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("index.json") }
    /// The address each tab's picture was taken at, by tab id.
    private var addresses: [String: String]
    private var saveWork: DispatchWorkItem?
    private var unsaved = false
    private let queue = DispatchQueue(label: "Rise.TabPictures", qos: .utility)
    init(folder: URL) {
        self.folder = folder
        addresses = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))) ?? [:]
    }
    private func fileURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".jpg") }
    /// The picture kept for `tab`, if it was taken where the tab is now.
    func picture(for tab: BrowserTab) -> NSImage? {
        guard let url = tab.url, addresses[tab.id.uuidString] == url.absoluteString else { return nil }
        // Read from disk only once drawn, as by the tab switcher, rather than every tab's at launch.
        let file = fileURL(tab.id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return NSImage(byReferencing: file)
    }
    /// How wide a picture is kept, in pixels: enough for a split's half, where it stands in for its
    /// page as that loads. The engine's are the screen's full width, about 3000 pixels, which made
    /// each 24 MB once drawn and slow to compress.
    nonisolated static let pixelWidth = 1024
    /// Pictures kept full size by earlier versions are made as small as new ones, one at a time in
    /// the background, a while after launch; quitting waits for at most the one under way.
    func shrinkOldPictures(after delay: TimeInterval = 15) {
        let folder = folder, queue = queue
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now()+delay) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "jpg" } ?? []
            for file in files { queue.sync { Self.shrink(file) } }
        }
    }
    nonisolated static func shrink(_ file: URL) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > pixelWidth else { return }
        let longest = Int((Double(max(width, height))*Double(pixelWidth)/Double(width)).rounded())
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: longest,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let data = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? data.write(to: file, options: .atomic)
    }
    /// Keeps the tab's current picture, replacing the one before.
    func keep(_ tab: BrowserTab) {
        guard let image = tab.thumbnail, let url = tab.url,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        addresses[tab.id.uuidString] = url.absoluteString
        let file = fileURL(tab.id), folder = folder
        // Compressed off the main thread, where it took a frame.
        nonisolated(unsafe) let picture = cgImage
        queue.async {
            guard let data = NSBitmapImageRep(cgImage: picture).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        scheduleSave()
    }
    /// Lets go of the pictures of tabs that are gone.
    func keepOnly(_ ids: Set<UUID>) {
        let gone = addresses.keys.filter { UUID(uuidString: $0).map { !ids.contains($0) } ?? true }
        guard !gone.isEmpty else { return }
        gone.forEach { addresses[$0] = nil }
        let files = gone.compactMap(UUID.init(uuidString:)).map(fileURL)
        queue.async { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        scheduleSave()
    }
    private func scheduleSave() {
        unsaved = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+1, execute: work)
    }
    /// Writes which picture shows which address, if that changed; the session saving calls it too.
    func save() {
        saveWork?.cancel(); saveWork = nil
        guard unsaved, let data = try? JSONEncoder().encode(addresses) else { return }
        unsaved = false
        let folder = folder, index = indexURL
        // After the pictures still being written; quitting waits for it (`flush`).
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: index, options: .atomic)
        }
    }
    /// Waits for the pictures and index still being written, as before quitting.
    func flush() { queue.sync {} }
}
