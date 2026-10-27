import EventKit
import UIKit

@MainActor extension BrowserViewController {
    func didAddSelectionItem(_ item: EKCalendarItem, store: EKEventStore) {
        selectionItemReceipt = SelectionItemReceipt(item: item, store: store)
        showSelectionItemConfirmation()
    }
    func changeSelectionItem(redo: Bool) {
        guard let receipt = selectionItemReceipt, receipt.allowsUndo else { return }
        do {
            guard try redo ? receipt.undo.redo() : receipt.undo.undo() else { return }
            showSelectionItemConfirmation()
        } catch {
            let alert = UIAlertController(title: "Couldn’t \(redo ? "restore" : "remove") the \(receipt.isEvent ? "event" : "reminder")",
                                          message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
    private func showSelectionItemConfirmation() {
        guard let receipt = selectionItemReceipt else { return }
        let undone = receipt.undo.isUndone
        let toast = SelectionItemToast(receipt: receipt, reverse: { [weak self] in self?.changeSelectionItem(redo: undone) })
        showToast(toast)
        toast.leave(after: receipt.undo.remaining)
        selectionItemExpiry?.cancel()
        selectionItemExpiry = Task { [weak self, weak receipt, weak toast] in
            do { try await Task.sleep(for: .seconds(SelectionItemUndo.duration)) } catch { return }
            if self?.selectionItemReceipt === receipt {
                self?.selectionItemReceipt = nil
                toast?.dismiss()
            }
        }
        UIAccessibility.post(notification: .announcement, argument: toast.label.text)
    }
}

@MainActor final class SelectionItemToast: Toast {
    private let reverseButton = UIButton(type: .system)
    private let receipt: SelectionItemReceipt
    init(receipt: SelectionItemReceipt, reverse: @escaping () -> Void) {
        self.receipt = receipt
        let undone = receipt.undo.isUndone
        super.init(message: "\(undone ? "Removed from" : "Added to") \(receipt.appName)", motionName: "toast", trailingInset: receipt.allowsUndo ? 92 : 22)
        symbol.setGlyph(UIImage(systemName: receipt.isEvent ? "calendar" : "checklist"), name: "saved-selection")
        reverseButton.setTitle(undone ? "Redo" : "Undo", for: .normal)
        reverseButton.tintColor = .white; reverseButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        reverseButton.addAction(UIAction { _ in reverse() }, for: .primaryActionTriggered)
        reverseButton.isHidden = !receipt.allowsUndo
        addSubview(reverseButton)
        isAccessibilityElement = false
        label.isAccessibilityElement = true; label.accessibilityLabel = label.text
        label.accessibilityTraits = undone ? .staticText : .button
        label.isUserInteractionEnabled = !undone
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openItem)))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        reverseButton.frame = CGRect(x: bounds.width-80, y: 0, width: 72, height: bounds.height)
        if !reverseButton.isHidden { label.frame.size.width = max(0, reverseButton.frame.minX-label.frame.minX-4) }
    }
    @objc private func openItem() {
        guard !receipt.undo.isUndone, let url = receipt.destinationURL else { return }
        UIApplication.shared.open(url)
    }
}
