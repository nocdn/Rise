import AppKit
import UniformTypeIdentifiers

/// The files the chat's model may give a page, as `upload_file` does, and finding them by name
/// (`find_files`). Only the person's own files: in their home folder or on a disk of theirs, not
/// hidden ones (which hold keys, tokens and settings) nor anything in Library (mail, keychains,
/// apps' data), and the person says yes to each upload first.
enum AIChatFiles {
    /// Folders files may also come from, beside the home folder and disks; tests add theirs.
    nonisolated(unsafe) static var extraRoots: [URL] = []
    /// The most files one upload gives a page.
    static let mostFiles = 20

    enum Kind { case file, folder }

    /// The file at `path`, if the model may give it to a page; otherwise why not, in words for it.
    static func check(_ path: String, as kind: Kind = .file, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result<URL, AIChatToolFailure> {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://"), let url = URL(string: text) { text = url.path }
        if text == "~" || text.hasPrefix("~/") { text = home.path+text.dropFirst() }
        guard text.hasPrefix("/") else {
            return .failure(AIChatToolFailure(message: "“\(path)” isn't a full path. Give it from the top, such as ~/Documents/cv.pdf; find_files finds a file by name."))
        }
        let url = URL(fileURLWithPath: text).standardizedFileURL.resolvingSymlinksInPath()
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            return .failure(AIChatToolFailure(message: "There's no file at \(path). find_files finds one by name."))
        }
        let roots = [homePath, "/Volumes"]+extraRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard let root = roots.first(where: { url.path == $0 || url.path.hasPrefix($0+"/") }) else {
            return .failure(AIChatToolFailure(message: "\(path) isn't among the user's own files (their home folder or a disk of theirs), so it can't be uploaded."))
        }
        let inside = url.path.dropFirst(root.count).split(separator: "/")
        if inside.contains(where: { $0.hasPrefix(".") }) {
            return .failure(AIChatToolFailure(message: "\(path) is hidden, as keys, passwords and settings are kept, so it can't be uploaded."))
        }
        if root == homePath, inside.first == "Library" {
            return .failure(AIChatToolFailure(message: "\(path) is in the Library folder, where apps keep mail, keychains and their data, so it can't be uploaded."))
        }
        if ["keychain", "keychain-db"].contains(url.pathExtension.lowercased()) {
            return .failure(AIChatToolFailure(message: "\(path) is a keychain, so it can't be uploaded."))
        }
        switch kind {
        case .file where isFolder.boolValue:
            // A package, such as a Keynote document, is a folder the Finder shows as a file.
            if !NSWorkspace.shared.isFilePackage(atPath: url.path) {
                return .failure(AIChatToolFailure(message: "\(path) is a folder; this takes files."))
            }
        case .folder where !isFolder.boolValue:
            return .failure(AIChatToolFailure(message: "\(path) is a file; this takes a folder."))
        default: break
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .failure(AIChatToolFailure(message: "\(path) can't be read."))
        }
        return .success(url)
    }

    /// `paths` checked: the files, or the first reason one can't be given.
    static func check(_ paths: [String], as kind: Kind = .file) throws -> [URL] {
        guard !paths.isEmpty else { throw AIChatToolFailure(message: "Give the paths of the files to upload.") }
        guard paths.count <= mostFiles else { throw AIChatToolFailure(message: "That's more than \(mostFiles) files at once.") }
        var urls: [URL] = []
        for path in paths {
            let url = try check(path, as: kind).get()
            if !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    /// Whether `files` all suit an `accept` such as ".pdf,image/*": the names of those that don't.
    static func unsuited(_ files: [URL], accept: String) -> [String] {
        let wanted = accept.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return [] }
        return files.filter { file in
            let ext = file.pathExtension.lowercased()
            let type = UTType(filenameExtension: ext)
            let mime = type?.preferredMIMEType?.lowercased() ?? ""
            return !wanted.contains { want in
                if want.hasPrefix(".") { return want.dropFirst() == ext || UTType(filenameExtension: String(want.dropFirst())).map { type?.conforms(to: $0) ?? false } ?? false }
                if want.hasSuffix("/*") { return mime.hasPrefix(want.dropLast()) || want == "image/*" && type?.conforms(to: .image) == true
                    || want == "video/*" && type?.conforms(to: .movie) == true || want == "audio/*" && type?.conforms(to: .audio) == true }
                return mime == want || UTType(mimeType: want).map { type?.conforms(to: $0) ?? false } ?? false
            }
        }.map(\.lastPathComponent)
    }

    /// "cv.pdf (240 KB)".
    static func describe(_ url: URL) -> String { size(url).map { "\(url.lastPathComponent) (\($0))" } ?? url.lastPathComponent }
    /// "240 KB", or "a folder".
    static func size(_ url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true, !NSWorkspace.shared.isFilePackage(atPath: url.path) { return "a folder" }
        return values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
    /// ~/Documents/cv.pdf for a file in the home folder.
    static func short(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        return url.path.hasPrefix(homePath+"/") ? "~"+url.path.dropFirst(homePath.count) : url.path
    }

    // MARK: Finding files

    struct Found { let url: URL; let modified: Date; let size: Int?; let isFolder: Bool }

    /// Files and folders of the person's whose names hold `name`, most recently changed first:
    /// from Spotlight, or the usual folders looked through when Spotlight has nothing.
    static func find(_ name: String, folders: Bool = false, limit: Int = 25,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [Found] {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        var paths = await spotlight(wanted, in: home)
        if paths.isEmpty { paths = await look(for: wanted, in: home) }
        var found: [Found] = []
        for path in paths {
            guard case .success(let url) = check(path, as: folders ? .folder : .file, home: home) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
            found.append(Found(url: url, modified: values?.contentModificationDate ?? .distantPast, size: values?.fileSize, isFolder: values?.isDirectory ?? false))
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }
    private static func spotlight(_ name: String, in home: URL) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                process.arguments = ["-onlyin", home.path, "-name", name]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continuation.resume(returning: []); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now()+5, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                continuation.resume(returning: Array(lines.prefix(400)))
            }
        }
    }
    private static func look(for name: String, in home: URL) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let lower = name.lowercased()
                var paths: [String] = [], seen = 0
                let started = Date()
                for folder in ["Downloads", "Desktop", "Documents"] {
                    guard let walk = FileManager.default.enumerator(at: home.appendingPathComponent(folder), includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                    for case let url as URL in walk {
                        seen += 1
                        if walk.level > 5 { walk.skipDescendants() }
                        if url.lastPathComponent.lowercased().contains(lower) { paths.append(url.path) }
                        if seen > 40_000 || paths.count > 400 || Date().timeIntervalSince(started) > 4 { break }
                    }
                }
                continuation.resume(returning: paths)
            }
        }
    }

    // MARK: Asking

    /// Asks the person, in a sheet over the window, whether the model may give `files` to the
    /// page at `host`.
    @MainActor static func ask(_ files: [URL], host: String, in window: NSWindow?) async -> Bool {
        guard let window else { return false }
        // One sheet at a time: after any the window has.
        while window.attachedSheet != nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
        guard !Task.isCancelled else { return false }
        let alert = NSAlert()
        let one = files.count == 1
        alert.messageText = one ? "Upload “\(files[0].lastPathComponent)” to \(host)?" : "Upload \(files.count) files to \(host)?"
        alert.informativeText = "The assistant wants to give the page \(one ? "this file" : "these files") from your Mac:\n\n"
            + files.prefix(8).map { short($0)+(size($0).map { " · \($0)" } ?? "") }.joined(separator: "\n")
            + (files.count > 8 ? "\n…and \(files.count-8) more" : "")
        alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Don’t Upload")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        } onCancel: {
            Task { @MainActor in if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .alertSecondButtonReturn) } }
        }
    }
}
