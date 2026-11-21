import UIKit
import UniformTypeIdentifiers
import WebKit

/// A page that is a file WebKit shows by itself rather than a web page: audio or video in its
/// player, a PDF or an image. It can be saved to Files, from a toast or the share sheet.
struct FileDocument: Equatable {
    enum Kind: Equatable { case audio, video, pdf, image }
    let url: URL
    let mimeType: String
    let kind: Kind
    /// The server's name for it, if its response was seen.
    let suggestedFilename: String?

    init?(url: URL, mimeType: String?, suggestedFilename: String? = nil) {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        let type = (mimeType ?? "").split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        guard let kind = Self.kind(of: type) else { return nil }
        self.url = url; self.mimeType = type; self.kind = kind
        self.suggestedFilename = suggestedFilename
    }

    static func kind(of type: String) -> Kind? {
        // A streaming playlist is a list of segments, not the media itself.
        if type.contains("mpegurl") || type.contains("dash+xml") { return nil }
        if type.hasPrefix("audio/") { return .audio }
        if type.hasPrefix("video/") { return .video }
        if type == "application/pdf" { return .pdf }
        // An SVG is a document of its own, with links and scripts.
        if type.hasPrefix("image/"), type != "image/svg+xml" { return .image }
        return nil
    }

    /// The server's name, else the address's, with an extension for its type when it has none.
    var filename: String {
        let path = url.lastPathComponent
        let base = suggestedFilename ?? (path.isEmpty || path == "/" ? "Download" : path)
        let name = MobileDownloads.cleanName(base)
        guard (name as NSString).pathExtension.isEmpty,
              let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension else { return name }
        return "\(name).\(ext)"
    }
}

/// Which pages are files, and what's been done about saving each, by page. They live only in
/// memory, private tabs' included, and start again with each document the page commits, so a
/// reload offers the toast again after it was swiped away.
@MainActor final class FileDocuments {
    /// Its download, if any, goes with it.
    @MainActor final class PageState: NSObject {
        var document: FileDocument?
        var dismissed = false
        var save: FileSaveDownload?
        /// Saved to Files: the toast says so, then goes, until the next document.
        var saved = false
    }
    private let pages = NSMapTable<WKWebView, PageState>.weakToStrongObjects()
    /// The last main-frame response, until its document commits.
    private let responses = NSMapTable<WKWebView, ResponseBox>.weakToStrongObjects()
    private final class ResponseBox: NSObject {
        let url: URL; let document: FileDocument?
        init(url: URL, document: FileDocument?) { self.url = url; self.document = document }
    }

    init() { FileSaveDownload.clearLeftovers() }

    func noteResponse(_ response: URLResponse, in page: WKWebView) {
        guard let url = response.url else { return }
        responses.setObject(ResponseBox(url: url, document: FileDocument(url: url, mimeType: response.mimeType,
                                                                         suggestedFilename: response.suggestedFilename)),
                            forKey: page)
    }

    /// A new document: its response says what it is. One from the back-forward cache comes with no
    /// response, so the page is asked; `changed` follows that answer.
    func didCommit(_ page: WKWebView, changed: @escaping @MainActor () -> Void) {
        let state = PageState()
        pages.setObject(state, forKey: page)
        let response = responses.object(forKey: page)
        responses.removeObject(forKey: page)
        guard let url = page.url, ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        if let response, response.url == url { state.document = response.document; return }
        page.evaluateJavaScript("document.contentType", in: nil, in: .defaultClient) { [weak self, weak page, weak state] result in
            guard let self, let page, let state, pages.object(forKey: page) === state,
                  case .success(let type) = result, let type = type as? String,
                  let document = FileDocument(url: url, mimeType: type) else { return }
            state.document = document
            changed()
        }
    }

    func state(for page: WKWebView) -> PageState? { pages.object(forKey: page) }
    /// The file the page is, unless it's been swiped away or saved.
    func offer(for page: WKWebView) -> FileDocument? {
        guard let state = pages.object(forKey: page), !state.dismissed, !state.saved else { return nil }
        return state.document
    }
    func document(for page: WKWebView) -> FileDocument? { pages.object(forKey: page)?.document }
    func dismiss(for page: WKWebView) {
        guard let state = pages.object(forKey: page) else { return }
        state.dismissed = true
        // A swipe during the download is a change of mind.
        if case .downloading = state.save?.state { state.save?.cancel(); state.save = nil }
    }
}

/// The file, downloaded through its page's own session (its cookies, and private if the tab
/// is), into a folder of its own in the app's temporary directory, ready for the Files picker
/// to copy. The folder goes with it.
@MainActor final class FileSaveDownload: NSObject, WKDownloadDelegate {
    enum State: Equatable {
        /// With how much has arrived, when the size is known.
        case downloading(Double?)
        case finished(URL)
        case failed(String)
    }
    private(set) var state: State = .downloading(nil) { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    let document: FileDocument
    private let folder: URL
    private var download: WKDownload?
    private var destination: URL?
    private var progress: NSKeyValueObservation?
    private var cancelled = false

    static var root: URL { FileManager.default.temporaryDirectory.appending(path: "Save to Files", directoryHint: .isDirectory) }
    private static var clearedLeftovers = false
    /// Files a previous run downloaded and never saved.
    static func clearLeftovers() {
        guard !clearedLeftovers else { return }
        clearedLeftovers = true
        try? FileManager.default.removeItem(at: root)
    }

    init(document: FileDocument, page: WKWebView) {
        self.document = document
        folder = Self.root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        super.init()
        page.startDownload(using: URLRequest(url: document.url)) { [weak self] download in
            guard let self, !cancelled else { download.cancel(); return }
            self.download = download
            download.delegate = self
        }
    }

    func cancel() {
        cancelled = true
        progress = nil
        download?.cancel()
        download = nil
        try? FileManager.default.removeItem(at: folder)
    }
    isolated deinit {
        download?.cancel()
        try? FileManager.default.removeItem(at: folder)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard !cancelled else { completionHandler(nil); return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(nil)
            state = .failed("The server didn't send the file")
            return
        }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { completionHandler(nil); state = .failed(error.localizedDescription); return }
        // The name the page's own response gave, else the download's, else the address's.
        let named = document.suggestedFilename == nil && !suggestedFilename.isEmpty
            ? FileDocument(url: document.url, mimeType: document.mimeType, suggestedFilename: suggestedFilename) : nil
        let file = folder.appending(path: (named ?? document).filename)
        progress = download.progress.observe(\.fractionCompleted, options: [.initial]) { [weak self] transfer, _ in
            let fraction = transfer.totalUnitCount > 0 ? transfer.fractionCompleted : nil
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(fraction)
            }
        }
        destination = file
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        progress = nil; self.download = nil
        guard !cancelled, let destination else { return }
        state = .finished(destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        progress = nil; self.download = nil
        guard !cancelled else { return }
        try? FileManager.default.removeItem(at: folder)
        if case .failed = state { return }
        state = .failed(error.localizedDescription)
    }
}
