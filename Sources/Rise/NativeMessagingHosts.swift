import Foundation

/// Extensions talk to their desktop apps, as 1Password's and Bitwarden's unlock with them, through
/// native messaging hosts, which those apps register with the browsers they know, never Rise. Rise
/// takes the ones registered for Chrome and Chromium as its own: a link to each in the engine's
/// folder, kept in step at launch. A host's own file in Rise's folder is left as it is.
enum NativeMessagingHosts {
    /// Where apps register hosts for Chrome and Chromium, the person's own first.
    static let registered: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Chromium/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
        ]
    }()

    /// Links each host in `sources` into `folder`, the first of a name winning, and drops links to
    /// hosts that have since gone.
    static func link(into folder: URL, from sources: [URL] = registered, files: FileManager = .default) {
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        var wanted: [String: URL] = [:]
        for source in sources {
            let names = (try? files.contentsOfDirectory(atPath: source.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".json") && wanted[name] == nil {
                wanted[name] = source.appendingPathComponent(name)
            }
        }
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let path = folder.appendingPathComponent(name).path
            // Only Rise's links: a link to a host that's gone, or that another now stands in for.
            guard let target = try? files.destinationOfSymbolicLink(atPath: path) else { continue }
            if !files.fileExists(atPath: target) || (wanted[name].map { $0.path != target } ?? false) { try? files.removeItem(atPath: path) }
        }
        for (name, host) in wanted {
            let path = folder.appendingPathComponent(name).path
            if (try? files.attributesOfItem(atPath: path)) == nil { try? files.createSymbolicLink(atPath: path, withDestinationPath: host.path) }
        }
    }
}
