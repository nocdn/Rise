import UIKit
import WebKit

/// Save to Files, on a page that is a file such as an MP3 or MP4. A press downloads it through
/// the page, the surface filling from the left as it arrives, then opens the Files picker to
/// choose where it goes. It says when it's saved and then goes, until the page is reloaded.
/// Its one icon is at its end: the download arrow, a spinner while it downloads, then a tick.
@MainActor final class FileSaveToast: PageActionToast {
    enum Phase: Equatable { case ready, downloading, saved, failed }
    let document: FileDocument
    private(set) var phase = Phase.ready
    /// How much of the file has arrived, over the surface's gradient.
    let progressFill = UIView()
    private(set) var progress: Double?
    private var recovery: Task<Void, Never>?
    #if DEBUG
    private(set) var successFeedbackCount = 0
    #endif

    static let readyMessage = "Save to Files"
    static let downloadingMessage = "Downloading…"
    static let savedMessage = "Saved to Files"
    static let failedMessage = "Couldn’t download"
    static let offerGlyph = "file-save-offer"

    init(document: FileDocument, page: WKWebView) {
        self.document = document
        // With no icon at the start, the text sits as far in as a plain toast's ends.
        super.init(message: Self.readyMessage, motionName: "file-save-toast", page: page,
                   leadingInset: 22, trailingInset: 48, trailingIcon: nil)
        trailingIcon.isHidden = true
        symbol.setGlyph(UIImage(named: "ToastSaveFile"), name: Self.offerGlyph)
        progressFill.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        progressFill.isUserInteractionEnabled = false
        progressFill.alpha = 0
        addToSurface(progressFill)
        accessibilityLabel = Self.readyMessage
        accessibilityValue = document.filename
    }
    required init?(coder: NSCoder) { fatalError() }

    override var widthFollowers: [UIView] { [pressButton, symbol] }

    override func layoutSubviews() {
        super.layoutSubviews()
        // As far from the end as the text is from the start.
        symbol.frame = CGRect(x: bounds.width-46, y: 11, width: 32, height: 32)
        layoutProgress()
    }
    private func layoutProgress() {
        progressFill.frame = CGRect(x: 0, y: 0, width: bounds.width*CGFloat(progress ?? 0), height: bounds.height)
    }

    /// Shows how the page's save is going.
    func show(_ next: Phase, progress fraction: Double? = nil) {
        guard !dismissed else { return }
        let previous = phase
        phase = next
        isActionable = next == .ready || next == .failed
        if next == .downloading { setProgress(fraction) }
        guard next != previous else { return }
        recovery?.cancel(); recovery = nil
        if next != .downloading { setProgress(nil) }
        switch next {
        case .ready: symbol.setGlyph(UIImage(named: "ToastSaveFile"), name: Self.offerGlyph)
        case .downloading: symbol.setLoading(name: "file-save-downloading")
        case .saved:
            symbol.setGlyph(UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
                            name: "file-save-saved")
        case .failed: symbol.setGlyph(UIImage(named: "GitHubToastError"), name: "file-save-failed")
        }
        let message = switch next {
        case .ready: Self.readyMessage
        case .downloading: Self.downloadingMessage
        case .saved: Self.savedMessage
        case .failed: Self.failedMessage
        }
        setMessage(message)
        accessibilityLabel = message
        accessibilityTraits = isActionable ? .button : .staticText
        switch next {
        case .saved:
            if window?.windowScene?.activationState == .foregroundActive {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #if DEBUG
                successFeedbackCount += 1
                #endif
            }
            UIAccessibility.post(notification: .announcement, argument: message)
            leave(after: 2.5, afterDrag: 2.5)
        case .failed:
            UIAccessibility.post(notification: .announcement, argument: message)
            // Offer it again after a moment; a press meanwhile tries again straight away.
            recovery = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, phase == .failed else { return }
                show(.ready)
            }
        default: break
        }
    }

    private func setProgress(_ fraction: Double?) {
        let clamped = fraction.map { min(1, max(0, $0)) }
        guard clamped != progress else { return }
        let appearing = progress == nil && clamped != nil
        progress = clamped
        let apply = {
            self.progressFill.alpha = clamped == nil ? 0 : 1
            self.layoutProgress()
        }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { apply(); return }
        // A fill that's appearing grows from the start rather than from where the last one was.
        if appearing { UIView.performWithoutAnimation { progressFill.frame.size.width = 0 } }
        UIView.animate(withDuration: DownloadButtonProgress.duration, delay: 0,
                       options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction], animations: apply)
    }

    override func dismiss(animated: Bool = true, velocity: CGPoint? = nil) {
        recovery?.cancel(); recovery = nil
        super.dismiss(animated: animated, velocity: velocity)
    }
    isolated deinit { recovery?.cancel() }
}
