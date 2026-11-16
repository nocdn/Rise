import AppKit
import os

/// Diagnostics for a page's floating window (Meet's call), in the system log under subsystem
/// dev.bartosz.Rise, category FloatingPage, beside the engine's own lines about where Chrome places
/// it. Window frames, levels and classes only: never the page's address or title.
///
///     /usr/bin/log stream --predicate 'subsystem == "dev.bartosz.Rise" AND category == "FloatingPage"' --level debug
@MainActor enum FloatingPageLog {
    static let logger = Logger(subsystem: "dev.bartosz.Rise", category: "FloatingPage")
    /// Set while Rise itself moves the window, so its moves aren't taken for Chrome's.
    static var riseIsMoving = false

    static func describe(_ frame: NSRect) -> String {
        "(\(Int(frame.minX.rounded())), \(Int(frame.minY.rounded())), \(Int(frame.width.rounded()))×\(Int(frame.height.rounded())))"
    }
    /// A window by its number, frame, level and state, enough to tell Chrome's windows apart.
    static func describe(_ window: NSWindow) -> String {
        var parts = ["#\(window.windowNumber)", NSStringFromClass(type(of: window)), describe(window.frame), "level \(window.level.rawValue)"]
        if window.isKeyWindow { parts.append("key") }
        if !window.isVisible { parts.append("hidden") }
        if let parent = window.parent { parts.append("child of #\(parent.windowNumber)") }
        if let screen = window.screen { parts.append("on a screen showing \(describe(screen.visibleFrame))") } else { parts.append("off every screen") }
        let children = (window.childWindows ?? []).filter { !($0 is FloatingPageVeil) }
        if !children.isEmpty {
            parts.append("children [\(children.map { "\(NSStringFromClass(type(of: $0))) \(describe($0.frame))\($0.isVisible ? "" : " hidden")" }.joined(separator: ", "))]")
        }
        return parts.joined(separator: " ")
    }
    /// Who called, as far up as it's telling: AppKit's and Rise's names, the engine's offsets. Past
    /// this logging and the notification that brought it here.
    static func caller() -> String {
        let frames = Thread.callStackSymbols.map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst() }
        let delivery: Set<Substring> = ["Rise", "Foundation", "CoreFoundation", "libswiftCore.dylib", "libswift_Concurrency.dylib"]
        return frames.drop { $0.first.map(delivery.contains) ?? true }.prefix(14).map { $0.joined(separator: " ") }.joined(separator: " < ")
    }
}

/// Watches Chrome's floating windows for what moves them, shows them and takes their focus, and
/// logs it: a run of moves once as it starts, from where, by whom, and once as it comes to rest.
@MainActor final class FloatingPageWatcher {
    static let shared = FloatingPageWatcher()
    enum Mover: String { case rise = "Rise", pointer = "the pointer", other = "something else" }
    private struct Run { var mover: Mover; var from: NSRect; var moves = 0 }
    private var observers: [Any] = []
    private var runs: [Int: Run] = [:]
    private var lastFrames: [Int: NSRect] = [:]
    private var rests: [Int: DispatchWorkItem] = [:]
    private var shown = Set<Int>()

    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ body: @escaping @MainActor (NSWindow) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { body(window) }
            })
        }
        observe(NSWindow.didMoveNotification) { [weak self] in self?.changed($0, resized: false) }
        observe(NSWindow.didResizeNotification) { [weak self] in self?.changed($0, resized: true) }
        observe(NSWindow.didBecomeKeyNotification) { [weak self] window in
            guard let self, self.watches(window) else { return }
            FloatingPageLog.logger.notice("Becomes key: \(FloatingPageLog.describe(window), privacy: .public)")
        }
        observe(NSWindow.didResignKeyNotification) { [weak self] window in
            guard let self, self.watches(window) else { return }
            FloatingPageLog.logger.notice("Resigns key: \(FloatingPageLog.describe(window), privacy: .public), Rise active \(NSApp.isActive)")
            // Whatever took the focus has it by the next turn.
            DispatchQueue.main.async {
                let key = NSApp.keyWindow.map(FloatingPageLog.describe) ?? "none in Rise"
                FloatingPageLog.logger.notice("The key window is now \(key, privacy: .public), Rise active \(NSApp.isActive)")
            }
        }
        observe(NSWindow.didChangeScreenNotification) { [weak self] window in
            guard let self, self.watches(window) else { return }
            FloatingPageLog.logger.notice("Changes screen: \(FloatingPageLog.describe(window), privacy: .public)")
        }
        observe(NSWindow.didChangeOcclusionStateNotification) { [weak self] window in
            guard let self, self.watches(window), window.occlusionState.contains(.visible),
                  self.shown.insert(window.windowNumber).inserted else { return }
            FloatingPageLog.logger.notice("Shows: \(FloatingPageLog.describe(window), privacy: .public), holding its page \(FloatingPageGestures.isFloatingPage(window))")
        }
        observe(NSWindow.willCloseNotification) { [weak self] window in
            guard let self, self.watches(window) else { return }
            FloatingPageLog.logger.notice("Closes: \(FloatingPageLog.describe(window), privacy: .public)")
            let number = window.windowNumber
            self.shown.remove(number); self.runs[number] = nil; self.lastFrames[number] = nil
            self.rests.removeValue(forKey: number)?.cancel()
        }
    }

    /// Chrome's floating windows, and the dialogs they hold, as the auto picture-in-picture choice.
    func watches(_ window: NSWindow) -> Bool {
        guard !(window is FloatingPageVeil) else { return false }
        return FloatingPageGestures.isFloatingChromeWindow(window) || window.parent.map(FloatingPageGestures.isFloatingChromeWindow) == true
    }

    private func changed(_ window: NSWindow, resized: Bool) {
        guard watches(window) else { return }
        let number = window.windowNumber, frame = window.frame
        let previous = lastFrames[number]; lastFrames[number] = frame
        guard previous != frame else { return }
        let mover: Mover = FloatingPageLog.riseIsMoving ? .rise : NSEvent.pressedMouseButtons & 1 != 0 ? .pointer : .other
        let what = resized ? "Resizes" : "Moves"
        if var run = runs[number], run.mover == mover {
            run.moves += 1; runs[number] = run
            FloatingPageLog.logger.debug("\(what, privacy: .public) by \(mover.rawValue, privacy: .public) to \(FloatingPageLog.describe(frame), privacy: .public)")
        } else {
            runs[number] = Run(mover: mover, from: previous ?? frame)
            let from = previous.map(FloatingPageLog.describe) ?? "where it was"
            if mover == .other {
                // Neither Rise nor a drag: the engine, the system or a site. Who asked is the clue.
                let caller = FloatingPageLog.caller()
                FloatingPageLog.logger.notice("\(what, privacy: .public) by \(mover.rawValue, privacy: .public) from \(from, privacy: .public): \(FloatingPageLog.describe(window), privacy: .public); called from \(caller, privacy: .public)")
            } else {
                FloatingPageLog.logger.notice("\(what, privacy: .public) by \(mover.rawValue, privacy: .public) from \(from, privacy: .public): \(FloatingPageLog.describe(window), privacy: .public)")
            }
        }
        rests[number]?.cancel()
        let rest = DispatchWorkItem { [weak self, weak window] in
            guard let self, let run = self.runs.removeValue(forKey: number) else { return }
            self.rests[number] = nil
            let at = window.map(FloatingPageLog.describe) ?? "a closed window"
            FloatingPageLog.logger.notice("Rests after \(run.moves+1) moves by \(run.mover.rawValue, privacy: .public) from \(FloatingPageLog.describe(run.from), privacy: .public): \(at, privacy: .public)")
        }
        rests[number] = rest
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3, execute: rest)
    }
}
