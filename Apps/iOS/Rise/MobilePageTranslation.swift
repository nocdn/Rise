import UIKit
import WebKit

/// Per-document, in-memory translations. Neither page text nor its translations are persisted.
@MainActor final class MobilePageTranslation {
    struct State {
        var documentID: String?
        var language: String?
        var enabled = false
        var busy = false
        var available: Bool { language.map { !PageTranslationLanguage.isEnglish($0) } == true }
    }
    typealias Translate = @MainActor ([String], String) async throws -> [String]
    static let world = WKContentWorld.world(name: "RisePageTranslation")
    private static let source = Bundle.main.url(forResource: "PageTranslation", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    private let contexts = NSMapTable<WKWebView, Context>.weakToStrongObjects()
    private let presenter: () -> UIViewController?
    private let changed: () -> Void
    /// Native audits replace only the model, while exercising real WebKit DOM and UI code.
    var translator: Translate?

    init(presenter: @escaping () -> UIViewController?, changed: @escaping () -> Void) {
        self.presenter = presenter; self.changed = changed
    }
    func install(on page: WKWebView) {
        guard #available(iOS 18.0, *), contexts.object(forKey: page) == nil else { return }
        let context = Context(page: page, owner: self)
        contexts.setObject(context, forKey: page)
        let controller = page.configuration.userContentController
        controller.add(context, contentWorld: Self.world, name: "risePageTranslation")
        controller.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world))
        didFinish(page)
    }
    func state(for page: WKWebView) -> State { contexts.object(forKey: page)?.state ?? State() }
    func didCommit(_ page: WKWebView) { contexts.object(forKey: page)?.reset() }
    func cancel(_ page: WKWebView) { contexts.object(forKey: page)?.reset(notify: false) }
    func didFinish(_ page: WKWebView) {
        guard contexts.object(forKey: page) != nil else { return }
        Task { _ = try? await page.evaluateJavaScript(Self.source, in: nil, in: Self.world) }
    }
    func toggle(_ page: WKWebView) { contexts.object(forKey: page)?.setEnabled(!state(for: page).enabled) }
    /// Consume only when the foreground toolbar can actually display the discovery hint.
    func takeAvailableHint(for page: WKWebView) -> Bool {
        guard let context = contexts.object(forKey: page), context.state.available,
              !context.state.enabled, context.state.documentID != nil, !context.didAnnounce else { return false }
        context.didAnnounce = true
        return true
    }

    private func translate(_ texts: [String], language: String) async throws -> [String] {
        if let translator { return try await translator(texts, language) }
        guard #available(iOS 18.0, *), let presenter = presenter() else { throw CancellationError() }
        return try await ApplePageTranslator.translate(texts, from: language, in: presenter)
    }
    private func failed(_ error: Error) {
        guard !(error is CancellationError), let presenter = presenter(), presenter.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Couldn't translate this page", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    private final class Context: NSObject, WKScriptMessageHandler {
        struct Frame { let id: String; let info: WKFrameInfo; let language: String? }
        weak var page: WKWebView?
        weak var owner: MobilePageTranslation?
        var state = State()
        var didAnnounce = false
        private var frames: [String: Frame] = [:]
        private var mainDocument: String?
        private var revision = 0
        private var needsWork = false
        private var task: Task<Void, Never>?

        init(page: WKWebView, owner: MobilePageTranslation) { self.page = page; self.owner = owner }
        func reset(notify: Bool = true) {
            revision += 1; task?.cancel(); task = nil; needsWork = false
            frames.removeAll(); mainDocument = nil; state = State(); didAnnounce = false
            if notify { owner?.changed() }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let page, let body = message.body as? [String: Any],
                  let id = body["document"] as? String, id.count <= 100,
                  ["http", "https"].contains(page.url?.scheme ?? message.frameInfo.request.url?.scheme ?? "") else { return }
            if body["kind"] as? String == "ready" {
                let language = PageTranslationLanguage.identify(sample: body["sample"] as? String ?? "", declared: body["language"] as? String ?? "")
                if message.frameInfo.isMainFrame {
                    if let mainDocument, mainDocument != id { reset() }
                    mainDocument = id
                    state.documentID = id
                    if !state.enabled { state.language = language; owner?.changed() }
                }
                frames[id] = Frame(id: id, info: message.frameInfo, language: language)
                if state.enabled { enqueue() }
            } else if body["kind"] as? String == "work", frames[id] != nil, state.enabled { enqueue() }
        }
        func setEnabled(_ enabled: Bool) {
            guard state.available, state.enabled != enabled else { return }
            revision += 1; task?.cancel(); task = nil
            state.enabled = enabled; state.busy = enabled; owner?.changed()
            if enabled { enqueue() }
            else {
                let current = revision, frames = Array(frames.values)
                Task { for frame in frames { _ = try? await self.call("api.enable(false, revision); return true", frame: frame, arguments: ["revision": current]) } }
            }
        }
        private func enqueue() {
            needsWork = true
            guard task == nil else { return }
            let current = revision
            task = Task { [weak self] in
                guard let self else { return }
                do { try await drain(revision: current) }
                catch {
                    guard current == revision else { return }
                    setEnabled(false)
                    owner?.failed(error)
                }
                guard current == revision else { return }
                task = nil; state.busy = false; owner?.changed()
            }
        }
        private func drain(revision current: Int) async throws {
            while state.enabled, current == revision {
                try Task.checkCancellation()
                needsWork = false
                var translated = false
                for frame in Array(frames.values) {
                    guard let language = frame.language ?? state.language, !PageTranslationLanguage.isEnglish(language) else { continue }
                    let value = try await call("api.enable(true, revision); return api.take()", frame: frame, arguments: ["revision": current])
                    guard let batch = value as? [[String: String]], !batch.isEmpty else { continue }
                    guard current == revision, state.enabled, let owner else { return }
                    state.busy = true; owner.changed()
                    let texts = batch.map { $0["text"] ?? "" }
                    let results = try await owner.translate(texts, language: language)
                    try Task.checkCancellation()
                    guard current == revision, state.enabled else { return }
                    guard results.count == batch.count else { throw Failure.incomplete }
                    let output = zip(batch, results).map { record, text in ["id": record["id"]!, "original": record["original"]!, "text": text] }
                    _ = try await call("api.apply(batch, revision); return true", frame: frame, arguments: ["batch": output, "revision": current])
                    translated = true
                }
                if !translated && !needsWork { return }
            }
        }
        private func call(_ source: String, frame: Frame, arguments: [String: Any]) async throws -> Any? {
            guard let page else { throw CancellationError() }
            let body = "const api = globalThis.__riseTranslation; if (!api || api.id !== documentID) return null; "+source
            do {
                return try await page.callAsyncJavaScript(body, arguments: arguments.merging(["documentID": frame.id], uniquingKeysWith: { a, _ in a }),
                                                         in: frame.info, contentWorld: MobilePageTranslation.world)
            } catch let error as WKError where error.code == .javaScriptInvalidFrameTarget {
                // Ads, consent frames and embedded widgets can disappear during a batch.
                frames.removeValue(forKey: frame.id)
                return nil
            }
        }
        enum Failure: LocalizedError {
            case incomplete
            var errorDescription: String? { "The translation was incomplete. Please try again." }
        }
    }
}
