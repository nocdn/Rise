import EventKit
import EventKitUI
import UIKit
import WebKit

/// Rise's pages: WebKit's own, with a time selected in another zone leading the selection menu,
/// and Explain in Context beside Look Up.
final class RiseWebView: WKWebView {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        SelectionTimeMenu.build(builder, in: self)
        SelectionExplanation.build(builder, in: self)
    }
}

/// A time selected in another zone, first in the selection menu, in the person's own zone as
/// `SelectionTimes` reads it ("Tomorrow at 07:00 · in 15 hours"), opening to date actions.
/// UIKit asks for the menu as it appears, before the page could be asked what's selected, so a
/// script in each frame keeps the app told of the selection as it changes.
@MainActor final class SelectionTimeMenu: NSObject, WKScriptMessageHandler, @preconcurrency EKEventEditViewDelegate {
    static let world = WKContentWorld.world(name: "RiseSelectionTimes")
    static let messageName = "riseSelection"
    static let menuIdentifier = UIMenu.Identifier("dev.bartosz.Rise.selectionTimes")
    private static let installed = NSMapTable<WKWebView, SelectionTimeMenu>.weakToStrongObjects()
    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    private weak var page: WKWebView?
    private var nativeMenu: SelectionTimeNativeMenu?
    /// What each frame has selected, and the frame selected in last.
    private var selections: [String: String] = [:]
    private var latest: String?

    static func install(on page: WKWebView) {
        guard installed.object(forKey: page) == nil else { return }
        let menu = SelectionTimeMenu(); menu.page = page
        installed.setObject(menu, forKey: page)
        page.configuration.userContentController.addUserScript(userScript)
        page.configuration.userContentController.add(menu, contentWorld: world, name: messageName)
    }

    /// The page's selected text, as its frames last told it.
    static func selection(in page: WKWebView) -> String {
        guard let menu = installed.object(forKey: page), let frame = menu.latest else { return "" }
        return menu.selections[frame] ?? ""
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === page, let body = message.body as? [String: Any],
              let frame = body["frame"] as? String, let text = body["text"] as? String else { return }
        if text.isEmpty {
            selections[frame] = nil
            if latest == frame { latest = nil }
        } else {
            selections[frame] = text; latest = frame
        }
    }

    /// The menu's items for the times in `text`: one per time, each opening to its actions.
    static func elements(for text: String, in page: WKWebView?, now: Date = Date()) -> [UIMenuElement] {
        let times = SelectionTimes.find(in: text, now: now)
        return times.enumerated().map { index, time in
            let copied = SelectionTimes.copied(time, now: now)
            let copy = UIAction(title: "Copy “\(copied)”", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = copied
            }
            let calendar = UIAction(title: "Add to Calendar", image: UIImage(systemName: "calendar")) { [weak page] _ in
                guard let page else { return }
                installed.object(forKey: page)?.addToCalendar(time, selection: text)
            }
            // The compact menu can open this submenu alone, without exposing the
            // system's completed root hierarchy. Supply working actions there too;
            // the expanded root replaces these with iOS's original actions.
            let reminder = UIAction(title: "Add to Reminders", image: UIImage(systemName: "list.bullet")) { [weak page] _ in
                guard let page else { return }
                installed.object(forKey: page)?.addToReminders(time, selection: text)
            }
            let show = UIAction(title: "Show in Calendar", image: UIImage(systemName: "calendar.day.timeline.left")) { [weak page] _ in
                guard let page else { return }
                installed.object(forKey: page)?.showInCalendar(time)
            }
            return UIMenu(title: SelectionTimes.label(time, of: times.count, now: now), image: UIImage(systemName: "clock"),
                          identifier: .init("\(menuIdentifier.rawValue).\(index)"), children: [copy, calendar, reminder, show])
        }
    }

    static func build(_ builder: UIMenuBuilder, in page: WKWebView) {
        guard builder.system == .context else { return }
        let elements = elements(for: selection(in: page), in: page)
        guard !elements.isEmpty else { return }
        builder.insertChild(UIMenu(identifier: menuIdentifier, options: .displayInline, children: elements), atStartOfMenu: .root)
    }

    static func willPresent(in page: WKWebView) {
        guard let owner = installed.object(forKey: page), !SelectionTimes.find(in: selection(in: page)).isEmpty else { return }
        if owner.nativeMenu == nil { owner.nativeMenu = SelectionTimeNativeMenu(page: page) }
        owner.nativeMenu?.begin()
    }

    static func willDismiss(in page: WKWebView) {
        installed.object(forKey: page)?.nativeMenu?.stop()
    }

    /// Calendar's own editor, filled in with the time and the page; it needs no access to the
    /// person's calendars, as they choose where it's saved themselves.
    private func addToCalendar(_ time: SelectionTime, selection: String) {
        guard let page, let presenter else { return }
        let store = EKEventStore(), event = EKEvent(eventStore: store)
        let title = (page.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        event.title = title.isEmpty ? time.written : title
        event.startDate = time.start
        event.endDate = time.end ?? time.start.addingTimeInterval(3600)
        event.url = page.url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        event.notes = selection
        let editor = EKEventEditViewController()
        editor.eventStore = store; editor.event = event; editor.editViewDelegate = self
        presenter.present(editor, animated: true)
    }

    private var presenter: UIViewController? {
        guard var controller = page?.window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed { controller = presented }
        return controller
    }

    private func addToReminders(_ time: SelectionTime, selection: String) {
        guard let presenter else { return }
        let date = time.start.formatted(date: .abbreviated, time: .shortened)
        let editor = UIAlertController(title: "Add to Reminders", message: date, preferredStyle: .alert)
        editor.addTextField { [weak page] field in
            field.placeholder = "Title"
            field.text = page?.title?.isEmpty == false ? page?.title : selection
        }
        editor.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let add = UIAlertAction(title: "Add", style: .default) { [weak self, weak editor] _ in
            guard let self, let title = editor?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
            let sourceURL = self.page?.url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
            Task { [self] in
                let store = EKEventStore()
                do {
                    guard try await store.requestFullAccessToReminders() else {
                        showError("Reminders access is disabled", message: "Allow Rise access to Reminders in Settings to add a reminder.")
                        return
                    }
                    guard let calendar = store.defaultCalendarForNewReminders() else {
                        showError("No reminder list available", message: "Create a list in Reminders first, then try again.")
                        return
                    }
                    let reminder = EKReminder(eventStore: store)
                    reminder.title = title; reminder.calendar = calendar
                    var due = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: time.start)
                    due.calendar = .current; due.timeZone = .current
                    reminder.dueDateComponents = due
                    reminder.addAlarm(EKAlarm(absoluteDate: time.start))
                    reminder.url = sourceURL; reminder.notes = selection
                    try store.save(reminder, commit: true)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch { showError("Couldn’t add reminder", message: error.localizedDescription) }
            }
        }
        editor.addAction(add)
        editor.textFields?.first?.addAction(UIAction { [weak add] action in
            add?.isEnabled = (action.sender as? UITextField)?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }, for: .editingChanged)
        presenter.present(editor, animated: true)
    }

    static func calendarURL(for date: Date) -> URL {
        URL(string: "calshow:\(date.timeIntervalSinceReferenceDate)")!
    }

    private func showInCalendar(_ time: SelectionTime) {
        UIApplication.shared.open(Self.calendarURL(for: time.start)) { [weak self] opened in
            if !opened { self?.showError("Calendar isn’t available", message: "Install the Calendar app to view this date.") }
        }
    }

    private func showError(_ title: String, message: String) {
        if let dismissing = page?.window?.rootViewController?.presentedViewController,
           dismissing.isBeingDismissed, let transition = dismissing.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in self?.showError(title, message: message) }
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter?.present(alert, animated: true)
    }

    func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
        controller.dismiss(animated: true)
    }

    static let source = #"""
    (() => {
      const frame = crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`;
      const post = text => window.webkit.messageHandlers.riseSelection.postMessage({frame, text});
      let sent = '';
      // The document's selection, or a text field's, which keeps its own to itself.
      function selected() {
        const text = String(getSelection() || ''), field = document.activeElement;
        if (text || !(field instanceof HTMLTextAreaElement || field instanceof HTMLInputElement)) return text;
        try { return field.value.slice(field.selectionStart ?? 0, field.selectionEnd ?? 0); } catch { return ''; }
      }
      document.addEventListener('selectionchange', () => {
        const text = selected().trim(), shown = text.length > 1000 ? '' : text;
        if (shown !== sent) post(sent = shown);
      });
      addEventListener('pagehide', () => { if (sent) post(sent = ''); });
    })();
    """#
}
