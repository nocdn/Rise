import SwiftUI
@preconcurrency import Translation
import UIKit

/// Apple handles model downloads and their consent UI. Page text stays on the device.
@available(iOS 18.0, *)
@MainActor enum ApplePageTranslator {
    static func translate(_ texts: [String], from language: String, in presenter: UIViewController) async throws -> [String] {
        let source = Locale.Language(identifier: language), target = Locale.Language(identifier: "en")
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .highFidelity) }
        else { availability = LanguageAvailability() }
        if #available(iOS 26.0, *), await availability.status(from: source, to: target) == .installed {
            let session: TranslationSession
            if #available(iOS 26.4, *) { session = TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity) }
            else { session = TranslationSession(installedSource: source, target: target) }
            return try await results(texts, using: session)
        }
        let operation = Operation(texts: texts, source: source, target: target)
        let host = UIHostingController(rootView: Anchor(operation: operation))
        presenter.addChild(host)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        host.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        presenter.view.addSubview(host.view)
        host.didMove(toParent: presenter)
        defer { host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.wait($0) }
        } onCancel: { Task { @MainActor in operation.finish(.failure(CancellationError())) } }
    }

    nonisolated private static func results(_ texts: [String], using session: TranslationSession) async throws -> [String] {
        let responses = try await session.translations(from: texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        })
        try Task.checkCancellation()
        guard responses.count == texts.count else { throw TranslationError.internalError }
        return responses.map(\.targetText)
    }

    @MainActor private final class Operation {
        let texts: [String]
        let configuration: TranslationSession.Configuration
        private var continuation: CheckedContinuation<[String], Error>?
        private var result: Result<[String], Error>?
        init(texts: [String], source: Locale.Language, target: Locale.Language) {
            self.texts = texts
            if #available(iOS 26.4, *) { configuration = .init(source: source, target: target, preferredStrategy: .highFidelity) }
            else { configuration = .init(source: source, target: target) }
        }
        func wait(_ continuation: CheckedContinuation<[String], Error>) {
            if let result { continuation.resume(with: result) }
            else { self.continuation = continuation }
        }
        func run(_ session: TranslationSession) async {
            guard result == nil else { return }
            do { finish(.success(try await ApplePageTranslator.results(texts, using: session))) }
            catch { finish(.failure(error)) }
        }
        func finish(_ result: Result<[String], Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result); continuation = nil
        }
    }
    private struct Anchor: View {
        let operation: Operation
        var body: some View {
            Color.clear.translationTask(operation.configuration) { session in await operation.run(session) }
        }
    }
}
