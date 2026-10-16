import UIKit
import WebKit

/// Observes the page's real touches without recognizing a gesture or delaying WebKit.
/// Keep the point in window coordinates so scrolling, Peek and the confirmation alert
/// cannot move the place from which an accepted download takes off.
@MainActor final class DownloadOriginTracker {
    private let observers = NSMapTable<WKWebView, Observer>.weakToStrongObjects()

    func install(on page: WKWebView) {
        guard observers.object(forKey: page) == nil else { return }
        let observer = Observer()
        page.addGestureRecognizer(observer)
        observers.setObject(observer, forKey: page)
    }

    func take(from page: WKWebView) -> CGPoint? {
        guard let observer = observers.object(forKey: page) else { return nil }
        defer { observer.point = nil }
        guard CACurrentMediaTime()-observer.time < 15 else { return nil }
        return observer.point
    }

    final class Observer: UIGestureRecognizer {
        fileprivate var point: CGPoint?
        fileprivate var time: CFTimeInterval = 0
        private var start: CGPoint?

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touches.count == 1, let touch = touches.first else { point = nil; state = .failed; return }
            start = touch.location(in: nil)
            point = start
            time = CACurrentMediaTime()
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let start, let touch = touches.first else { return }
            let now = touch.location(in: nil)
            if hypot(now.x-start.x, now.y-start.y) > 14 { point = nil; state = .failed }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { point = nil; state = .failed }
    }
}
