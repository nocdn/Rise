import AppKit
import EventKit
import RiseCore

@MainActor extension BrowserController {
    func didAddSelectionItem(_ item: EKCalendarItem, store: EKEventStore) {
        selectionItemReceipts.removeAll { $0.undo.remaining == 0 }
        let receipt = SelectionItemReceipt(item: item, store: store)
        selectionItemReceipts.append(receipt)
        showSelectionItemConfirmation(receipt)
        scheduleSelectionItemExpiry()
    }

    func handleSelectionItemUndoKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, palette.isHidden,
              !(window?.firstResponder is NSTextView) else { return false }
        let redo = keyboardShortcuts.matches("redo:", event)
        guard redo || keyboardShortcuts.matches("undo:", event),
              let receipt = selectionItemReceipts.last(where: { $0.allowsUndo && (redo ? $0.undo.canRedo : $0.undo.canUndo) }) else { return false }
        changeSelectionItem(receipt, redo: redo)
        return true
    }

    func changeSelectionItem(_ receipt: SelectionItemReceipt, redo: Bool) {
        do {
            guard try redo ? receipt.undo.redo() : receipt.undo.undo() else { return }
            showSelectionItemConfirmation(receipt)
            scheduleSelectionItemExpiry()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t \(redo ? "restore" : "remove") the \(receipt.isEvent ? "event" : "reminder")"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    private func showSelectionItemConfirmation(_ receipt: SelectionItemReceipt) {
        let undone = receipt.undo.isUndone
        let link = undone ? nil : BarNotice.Link(text: receipt.appName) { [weak self, receipt] in
            guard !receipt.undo.isUndone, let url = receipt.destinationURL else { return }
            if !NSWorkspace.shared.open(url) {
                self?.selectedBar.showNotice("Couldn’t open \(receipt.appName)", image: BarNotice.warningImage, hold: 3)
            }
        }
        let action = receipt.allowsUndo ? BarNotice.Link(text: undone ? "Redo ⇧⌘Z" : "Undo ⌘Z") { [weak self, receipt] in
            self?.changeSelectionItem(receipt, redo: undone)
        } : nil
        selectedBar.showNotice(undone ? "Removed from \(receipt.appName)" : "Added to",
            image: receipt.isEvent ? BarNotice.calendarImage : BarNotice.reminderImage,
            link: link, action: action, hold: receipt.undo.remaining)
    }

    private func scheduleSelectionItemExpiry() {
        selectionItemExpiry?.invalidate()
        guard let next = selectionItemReceipts.map({ $0.undo.remaining }).filter({ $0 > 0 }).min() else { return }
        let timer = Timer(timeInterval: next+0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.selectionItemReceipts.removeAll { $0.undo.remaining == 0 }
                self?.scheduleSelectionItemExpiry()
            }
        }
        selectionItemExpiry = timer; RunLoop.main.add(timer, forMode: .common)
    }
}
