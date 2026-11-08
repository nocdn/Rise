import EventKit
import EventKitUI
import UIKit
import WebKit

/// Rise's pages: WebKit's own, with a time selected in another zone and an amount in another
/// currency leading the selection menu, Explain in Context beside Look Up, and no Copy Link with Highlight.
final class RiseWebView: WKWebView {
    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if let receipt = selectionItemBrowser?.selectionItemReceipt, receipt.allowsUndo {
            let undo = receipt.undo
            if undo.canUndo {
                let command = UIKeyCommand(title: "Undo Add to Calendar or Reminders", action: #selector(undoSelectionItem), input: "z", modifierFlags: .command)
                command.wantsPriorityOverSystemBehavior = true; commands.append(command)
            }
            if undo.canRedo {
                let command = UIKeyCommand(title: "Redo Add to Calendar or Reminders", action: #selector(redoSelectionItem), input: "z", modifierFlags: [.command, .shift])
                command.wantsPriorityOverSystemBehavior = true; commands.append(command)
            }
        }
        return commands
    }
    private var selectionItemBrowser: BrowserViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let browser = next as? BrowserViewController { return browser }
            responder = next
        }
        return nil
    }
    @objc private func undoSelectionItem() { selectionItemBrowser?.changeSelectionItem(redo: false) }
    @objc private func redoSelectionItem() { selectionItemBrowser?.changeSelectionItem(redo: true) }
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        SelectionTimeMenu.build(builder, in: self)
        SelectionCurrencyMenu.build(builder, in: self)
        SelectionExplanation.build(builder, in: self)
        SelectionTimeNativeMenu.removeCopyLinkWithHighlight(from: builder)
        SelectionBase64Menu.build(builder, in: self)
        SelectionMenuIcons.build(builder)
    }
}

/// An event selected on the page, first in the selection menu as its time (`SelectionEvents`: "Tue 3 Nov,
/// 13:30 – 20:30"), opening to Calendar's editor filled in with its title, place and times, Reminders,
/// and the day in Calendar. A time selected in another zone follows, in the person's own zone as
/// `SelectionTimes` reads it ("Tomorrow at 07:00 (in 15 hours)"), opening to the same date actions.
/// UIKit asks for the menu as it appears, before the page could be asked what's selected, so a
/// script in each frame keeps the app told of the selection as it changes.
@MainActor final class SelectionTimeMenu: NSObject, WKScriptMessageHandler, @preconcurrency EKEventEditViewDelegate {
    static let world = WKContentWorld.world(name: "RiseSelectionTimes")
    static let messageName = "riseSelection"
    static let menuIdentifier = UIMenu.Identifier("dev.bartosz.Rise.selectionTimes")
    static let eventIdentifier = UIMenu.Identifier("dev.bartosz.Rise.selectionTimes.event")
    private static let installed = NSMapTable<WKWebView, SelectionTimeMenu>.weakToStrongObjects()
    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    private weak var page: WKWebView?
    private var nativeMenu: SelectionTimeNativeMenu?
    /// What each frame has selected, and the frame selected in last.
    private var selections: [String: String] = [:]
    /// Encoding must preserve whitespace and selections beyond date parsing's limit.
    private var rawSelections: [String: String] = [:]
    private var latest: String?
    /// Whether the page's amounts are rewritten into the person's currency (`SelectionCurrencyMenu`).
    private var currencyReplaced = false
    private lazy var timeConversion = TimePageConversion { [weak self] body, arguments in
        guard let page = self?.page else { throw CancellationError() }
        return try await page.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: Self.world)
    }

    static func isTimeReplaced(in page: WKWebView) -> Bool { installed.object(forKey: page)?.timeConversion.isActive ?? false }
    static func replaceTimes(_ on: Bool, in page: WKWebView, announces: Bool = true) {
        guard let owner = installed.object(forKey: page) else { return }
        Task { [weak owner, weak page] in
            guard let owner, let page else { return }
            do {
                let count = try await owner.timeConversion.set(on)
                UISelectionFeedbackGenerator().selectionChanged()
                guard announces else { return }
                let revert: (() -> Void)? = on && count > 0 ? { [weak page] in
                    if let page { replaceTimes(false, in: page, announces: false) }
                } : nil
                owner.browser?.showTimeToast(on ? TimePageConversion.message(count) : TimePageConversion.restoredMessage, revert: revert)
            } catch {
                owner.browser?.showTimeToast("Couldn’t replace times on this page")
            }
        }
    }

    static func replaceAction(in page: WKWebView?) -> UIAction {
        let replaced = page.map(isTimeReplaced) ?? false
        return UIAction(title: "Replace on Page", image: UIImage(systemName: "arrow.left.arrow.right"),
                        identifier: UIAction.Identifier("dev.bartosz.Rise.replaceTimes"), state: replaced ? .on : .off) { [weak page] _ in
            if let page { replaceTimes(!replaced, in: page) }
        }
    }

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
    static func rawSelection(in page: WKWebView) -> String {
        guard let menu = installed.object(forKey: page), let frame = menu.latest else { return "" }
        return menu.rawSelections[frame] ?? ""
    }

    static func isCurrencyReplaced(in page: WKWebView) -> Bool { installed.object(forKey: page)?.currencyReplaced ?? false }
    static func setCurrencyReplaced(_ replaced: Bool, in page: WKWebView) { installed.object(forKey: page)?.currencyReplaced = replaced }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === page, let body = message.body as? [String: Any] else { return }
        // A new page in the main frame, or one back from the back-forward cache as it was left.
        if let replaced = body["replaced"] as? Bool, message.frameInfo.isMainFrame { currencyReplaced = replaced; return }
        guard let frame = body["frame"] as? String, let text = body["text"] as? String else { return }
        // Rates for an amount selected, ready by the time its menu is asked for.
        if text.contains(where: \.isNumber) { ExchangeRateStore.shared.refreshIfStale() }
        let raw = body["raw"] as? String ?? text
        if raw.isEmpty || raw.utf8.count > SelectionBase64.maximumBytes {
            selections[frame] = nil; rawSelections[frame] = nil
            if latest == frame { latest = nil }
        } else {
            selections[frame] = text.isEmpty ? nil : text; rawSelections[frame] = raw; latest = frame
        }
    }

    /// The menu's items for `text`: its event, opening to its actions, then each time in another zone.
    /// An event that is one of those times keeps the time's own item, converted, with the event's actions.
    static func elements(for text: String, in page: WKWebView?, now: Date = Date()) -> [UIMenuElement] {
        let pageTitle = page?.title, source = page?.url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        let found = SelectionEvents.find(in: text, pageTitle: pageTitle, now: now)
        let replaced = page.map(isTimeReplaced) ?? false
        let times = SelectionTimes.find(in: text, now: now, includingLocal: replaced)
        let matched = found.flatMap { found in times.firstIndex { !$0.isZoneOnly && $0.start == found.start } }
        var elements: [UIMenuElement] = []
        if let found, matched == nil {
            elements.append(UIMenu(title: SelectionEvents.label(found, now: now), image: UIImage(systemName: "calendar"),
                                   identifier: eventIdentifier, children: actions(for: found, source: source, in: page)))
        }
        for (index, time) in times.enumerated() {
            let copied = SelectionTimes.copied(time, now: now)
            let copy = UIAction(title: "Copy “\(copied)”", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = copied
            }
            let title = SelectionTimes.label(time, of: times.count, now: now)
            let identifier = index == matched ? eventIdentifier : UIMenu.Identifier("\(menuIdentifier.rawValue).\(index)")
            if time.isZoneOnly {
                elements.append(UIMenu(title: title, image: UIImage(systemName: "clock"), identifier: identifier, children: [copy]))
                continue
            }
            // The compact menu can open this submenu alone, without exposing the
            // system's completed root hierarchy. Supply working actions there too.
            let event = index == matched ? found! : SelectionEvent(title: (pageTitle?.isEmpty == false ? pageTitle : nil) ?? time.written, start: time.start,
                                       end: time.end ?? time.start.addingTimeInterval(3600), hasEnd: time.end != nil,
                                       timeZone: time.zone, notes: text)
            elements.append(UIMenu(title: title, image: UIImage(systemName: "clock"), identifier: identifier,
                                   children: [copy, replaceAction(in: page)] + actions(for: event, source: source, in: page)))
        }
        if replaced && times.isEmpty {
            elements.append(UIMenu(title: "Local times on this page", image: UIImage(systemName: "clock"),
                                   identifier: UIMenu.Identifier("\(menuIdentifier.rawValue).restoring"), children: [replaceAction(in: page)]))
        }
        return elements
    }

    /// Add to Calendar, Add to Reminders and Show in Calendar, for `event`.
    static func actions(for event: SelectionEvent, source: URL?, in page: WKWebView?) -> [UIAction] {
        let calendar = UIAction(title: "Add to Calendar", image: UIImage(systemName: "calendar.badge.plus")) { [weak page] _ in
            guard let page else { return }
            installed.object(forKey: page)?.addToCalendar(event, source: source)
        }
        let reminder = UIAction(title: "Add to Reminders", image: UIImage(systemName: "list.bullet")) { [weak page] _ in
            guard let page else { return }
            installed.object(forKey: page)?.addToReminders(event, source: source)
        }
        let show = UIAction(title: "Show in Calendar", image: UIImage(systemName: "calendar.day.timeline.left")) { [weak page] _ in
            guard let page else { return }
            installed.object(forKey: page)?.showInCalendar(event.start)
        }
        return [calendar, reminder, show]
    }

    static func build(_ builder: UIMenuBuilder, in page: WKWebView) {
        guard builder.system == .context else { return }
        let elements = elements(for: selection(in: page), in: page)
        guard !elements.isEmpty else { return }
        builder.insertChild(UIMenu(identifier: menuIdentifier, options: .displayInline, children: elements), atStartOfMenu: .root)
    }

    static func willPresent(in page: WKWebView) {
        let text = selection(in: page), times = SelectionTimes.find(in: text)
        let hasEvent = SelectionEvents.find(in: text, pageTitle: page.title) != nil
        guard let owner = installed.object(forKey: page) else { return }
        // Every selection menu loses Copy Link with Highlight; one with an amount, the system's
        // conversion; one with a time or event, the system's date actions, moved into Rise's.
        if owner.nativeMenu == nil { owner.nativeMenu = SelectionTimeNativeMenu(page: page) }
        owner.nativeMenu?.begin(relocatesDates: hasEvent || !times.isEmpty && times.allSatisfy({ !$0.isZoneOnly }),
                                replacesConversion: !SelectionCurrencyMenu.elements(for: text, in: page).isEmpty)
    }

    static func willDismiss(in page: WKWebView) {
        installed.object(forKey: page)?.nativeMenu?.stop()
    }

    /// Calendar's own editor, filled in with the event and the page; it needs no access to the
    /// person's calendars, as they choose where it's saved themselves.
    private func addToCalendar(_ found: SelectionEvent, source: URL?) {
        guard let presenter else { return }
        let store = EKEventStore(), event = EKEvent(eventStore: store)
        event.title = found.title
        event.location = found.location
        event.isAllDay = found.isAllDay
        event.startDate = found.start
        // An all-day event ends within its last day.
        event.endDate = found.isAllDay ? found.end.addingTimeInterval(-1) : found.end
        if !found.isAllDay { event.timeZone = found.timeZone ?? .current }
        event.url = source ?? found.meetingURL
        event.notes = found.notes
        let editor = EKEventEditViewController()
        editor.eventStore = store; editor.event = event; editor.editViewDelegate = self
        Task { [weak self, weak presenter] in
            // The system editor can save without access; reversing that save needs full access.
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await store.requestFullAccessToEvents()
            }
            guard self != nil else { return }
            presenter?.present(editor, animated: true)
        }
    }

    private var presenter: UIViewController? {
        guard var controller = page?.window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed { controller = presented }
        return controller
    }

    private func addToReminders(_ found: SelectionEvent, source: URL?) {
        guard let presenter else { return }
        let date = found.isAllDay ? found.start.formatted(date: .abbreviated, time: .omitted)
            : found.start.formatted(date: .abbreviated, time: .shortened)
        let editor = UIAlertController(title: "Add to Reminders", message: date, preferredStyle: .alert)
        editor.addTextField { field in
            field.placeholder = "Title"
            field.text = found.title
        }
        editor.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let add = UIAlertAction(title: "Add", style: .default) { [weak self, weak editor] _ in
            guard let self, let title = editor?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
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
                    // A day's reminder is due that day, and says so in the morning.
                    var due = Calendar.current.dateComponents(found.isAllDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute, .second], from: found.start)
                    due.calendar = .current; if !found.isAllDay { due.timeZone = .current }
                    reminder.dueDateComponents = due
                    let alarm = found.isAllDay ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: found.start) ?? found.start : found.start
                    reminder.addAlarm(EKAlarm(absoluteDate: alarm))
                    reminder.url = source
                    reminder.notes = [found.location, found.notes].compactMap { $0 }.joined(separator: "\n\n")
                    try store.save(reminder, commit: true)
                    browser?.didAddSelectionItem(reminder, store: store)
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

    private func showInCalendar(_ date: Date) {
        UIApplication.shared.open(Self.calendarURL(for: date)) { [weak self] opened in
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
        let receipt = action == .saved ? controller.event : nil
        let store = controller.eventStore!
        controller.dismiss(animated: true) { [weak self] in
            if let receipt { self?.browser?.didAddSelectionItem(receipt, store: store) }
        }
    }

    private var browser: BrowserViewController? {
        var responder: UIResponder? = page
        while let next = responder?.next {
            if let browser = next as? BrowserViewController { return browser }
            responder = next
        }
        return nil
    }

    static let source = #"""
    (() => {
      const frame = crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`;
      const post = (text, raw) => window.webkit.messageHandlers.riseSelection.postMessage({frame, text, raw});
      let sent = '', sentRaw = '';
      // The document's selection, or a text field's, which keeps its own to itself.
      function selected() {
        const text = String(getSelection() || ''), field = document.activeElement;
        if (text || !(field instanceof HTMLTextAreaElement || field instanceof HTMLInputElement)) return text;
        try { return field.value.slice(field.selectionStart ?? 0, field.selectionEnd ?? 0); } catch { return ''; }
      }
      document.addEventListener('selectionchange', () => {
        const selectedText = selected(), text = selectedText.trim(), shown = text.length > 3000 ? '' : text;
        const raw = selectedText.length > __BASE64_LIMIT__ ? '' : selectedText;
        if (shown !== sent || raw !== sentRaw) post(sent = shown, sentRaw = raw);
      });
      addEventListener('pagehide', () => { if (sent || sentRaw) post(sent = '', sentRaw = ''); });
      if (window === top) {
        window.webkit.messageHandlers.riseSelection.postMessage({replaced: false});
        addEventListener('pageshow', event => {
          if (event.persisted) window.webkit.messageHandlers.riseSelection.postMessage({replaced: !!globalThis.riseCurrency?.active});
        });
      }
    })();
    """#.replacingOccurrences(of: "__BASE64_LIMIT__", with: String(SelectionBase64.maximumBytes))
}
