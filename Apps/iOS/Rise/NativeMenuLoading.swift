import UIKit

/// UIKit owns the loading row, including its indicator, sizing and glass styling.
/// Used by API-key verification. UIKit supplies
/// the localized “Loading…” caption; it has no public custom-caption API.
@MainActor final class NativeMenuLoading {
    private var completions: [([UIMenuElement]) -> Void] = []

    func element(whenReady: @escaping () -> [UIMenuElement]?) -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            if let elements = whenReady() { completion(elements) }
            else { completions.append(completion) }
        }
    }

    /// Resolving the deferred row already updates the visible menu. The caller
    /// should not replace that menu a second time and introduce another transition.
    @discardableResult func resolve(_ elements: [UIMenuElement]) -> Bool {
        let callbacks = completions
        completions.removeAll()
        Self.withoutAnimation { callbacks.forEach { $0(elements) } }
        return !callbacks.isEmpty
    }

    static func withoutAnimation(_ update: () -> Void) {
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            update()
            CATransaction.commit()
        }
    }

    isolated deinit { completions.forEach { $0([]) } }
}
