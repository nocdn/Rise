import UIKit

/// Keeps completed files in the current batch until its last transfer ends. Old downloads
/// never contribute, and cancelling/removing a transfer releases its share of the work.
@MainActor struct MobileDownloadBatchProgress {
    enum Update: Equatable {
        case idle
        case running(fraction: Double, count: Int)
        case ended(successfully: Bool)
    }
    private var members = Set<UUID>()
    private var active = Set<UUID>()

    mutating func update(_ items: [MobileDownloads.Item]) -> Update {
        let next = Set(items.filter { $0.state == .downloading }.map(\.id))
        guard !next.isEmpty else {
            guard !active.isEmpty else { return .idle }
            let finished = active.allSatisfy { id in items.contains { $0.id == id && $0.state == .finished } }
            members = []; active = []
            return .ended(successfully: finished)
        }
        active = next
        members.formUnion(next)
        members.formIntersection(items.filter { $0.state != .failed }.map(\.id))
        let batch = items.filter { members.contains($0.id) }
        let fraction: Double
        if batch.allSatisfy({ $0.totalBytes > 0 }) {
            let total = batch.reduce(0.0) { $0+Double($1.totalBytes) }
            fraction = batch.reduce(0.0) { $0+Double(min(max(0, $1.receivedBytes), $1.totalBytes)) }/total
        } else {
            // Unknown lengths reserve a file's share, rather than making known files look
            // like the entire batch. They contribute when their size arrives or they finish.
            fraction = batch.reduce(0.0) { $0+($1.state == .finished ? 1 : max(0, $1.fraction ?? 0)) }/Double(batch.count)
        }
        return .running(fraction: min(1, max(0, fraction)), count: next.count)
    }
}

/// A translucent left-to-right fill behind the Downloads button's normal content/press fill.
final class DownloadButtonProgress: UIView {
    static let duration: TimeInterval = 0.25
    static let fadeDuration: TimeInterval = 0.18
    let fill = UIView()
    private var batch = MobileDownloadBatchProgress()
    private(set) var fraction: CGFloat = 0
    private var finish: Task<Void, Never>?
    private var generation = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        fill.backgroundColor = UIColor { UIColor(red: 0, green: 0.38, blue: 1, alpha:
            $0.userInterfaceStyle == .dark ? 0.20 : 0.12) }
        fill.isUserInteractionEnabled = false
        addSubview(fill)
        alpha = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    @discardableResult func update(_ items: [MobileDownloads.Item]) -> MobileDownloadBatchProgress.Update {
        let update = batch.update(items)
        guard update != .idle else { return update }
        generation += 1
        finish?.cancel(); finish = nil
        switch update {
        case .running(let progress, _):
            fraction = CGFloat(progress)
            animate { self.alpha = 1; self.setNeedsLayout(); self.layoutIfNeeded() }
        case .ended(let success):
            let current = generation
            if success {
                fraction = 1
                animate { self.setNeedsLayout(); self.layoutIfNeeded() }
            }
            finish = Task { [weak self] in
                do {
                    if success { try await Task.sleep(for: .seconds(Self.duration)) }
                    guard let self, !Task.isCancelled, generation == current else { return }
                    animate(duration: Self.fadeDuration) { self.alpha = 0 }
                    try await Task.sleep(for: .seconds(Self.fadeDuration))
                    guard !Task.isCancelled, generation == current else { return }
                    fraction = 0
                    UIView.performWithoutAnimation { self.setNeedsLayout(); self.layoutIfNeeded() }
                    finish = nil
                } catch { }
            }
        case .idle: break
        }
        return update
    }

    private func animate(duration: TimeInterval = DownloadButtonProgress.duration, _ changes: @escaping () -> Void) {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { changes(); return }
        UIView.animate(withDuration: duration, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: changes)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width*fraction, height: bounds.height)
    }
}
