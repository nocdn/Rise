import UIKit

/// Local, disposable previews. URLs are checked before reuse; pictures never enter CloudKit.
final class TabPreviewCache: Sendable {
    private static let formatVersion = 3
    struct Entry: Codable, Sendable {
        let version: Int
        let url: URL
        let picture: Data?
        let favicon: Data?
        let darkFavicon: Data?

        var faviconImage: UIImage? {
            guard let light = favicon.flatMap(MobileFavicon.decode) else { return nil }
            return MobileFavicon.adaptive(light: light, dark: darkFavicon.flatMap(MobileFavicon.decode))
        }
    }
    private let folder: URL
    private let writer = DispatchQueue(label: "Rise.iOS.TabPreviews", qos: .utility)
    init(folder: URL) { self.folder = folder }

    func load(id: UUID, url: URL) async -> Entry? {
        let file = folder.appendingPathComponent(id.uuidString+".json")
        return await withCheckedContinuation { continuation in
            writer.async {
                let entry = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
                continuation.resume(returning: entry?.version == Self.formatVersion && entry?.url == url ? entry : nil)
            }
        }
    }

    func save(id: UUID, url: URL, picture: UIImage?, favicon: UIImage?) {
        let folder = folder
        writer.async {
            let data = picture?.jpegData(compressionQuality: 0.82)
            let icon = favicon.flatMap(MobileFavicon.Saved.init)
            guard data != nil || favicon != nil,
                  let entry = try? JSONEncoder().encode(Entry(version: Self.formatVersion, url: url, picture: data,
                                                            favicon: icon?.light, darkFavicon: icon?.dark)) else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try entry.write(to: folder.appendingPathComponent(id.uuidString+".json"),
                                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { NSLog("Rise couldn't save a tab preview: %@", error.localizedDescription) }
        }
    }

    func prune(keeping ids: Set<UUID>) {
        let folder = folder
        writer.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func flush() { writer.sync {} }
}
