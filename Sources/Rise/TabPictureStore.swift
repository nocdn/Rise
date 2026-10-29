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
        return NSImage(contentsOf: fileURL(tab.id))
    }
    /// Keeps the tab's current picture, replacing the one before.
    func keep(_ tab: BrowserTab) {
        guard let image = tab.thumbnail, let url = tab.url,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        addresses[tab.id.uuidString] = url.absoluteString
        let file = fileURL(tab.id), folder = folder
        queue.async {
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
        // After the pictures still being written, and before Rise can quit.
        queue.sync {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: index, options: .atomic)
        }
    }
}
