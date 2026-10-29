import AppKit

/// Menu commands and the shortcuts handled before Chromium sees a key use one saved registry.
@MainActor final class KeyboardShortcuts {
    static let preferencesKey = "Rise.KeyboardShortcuts"
    struct Command {
        let id: String
        var title: String
        var group: String
        var defaults: [KeyboardShortcut]
        var items: [NSMenuItem] = []
    }
    private let preferences: UserDefaults
    private(set) var commands: [Command] = []
    private var overrides: [String: [String]]
    var onChange: (() -> Void)?
    init(preferences: UserDefaults) {
        self.preferences = preferences
        overrides = preferences.dictionary(forKey: Self.preferencesKey) as? [String: [String]] ?? [:]
        // Commands with an early key handler must also work before the app's menu is built.
        let early: [(String, String, String, [String])] = [
            ("undo:", "Undo", "Edit", ["Command+Z"]), ("redo:", "Redo", "Edit", ["Command+Shift+Z"]),
            ("moveCurrentTabUp", "Move Tab Up", "Tabs", ["Command+Alt+Up"]),
            ("moveCurrentTabDown", "Move Tab Down", "Tabs", ["Command+Alt+Down"]),
            ("moveCurrentTabToTop", "Move Tab to Top", "Tabs", ["Command+Ctrl+Alt+Up"]),
            ("tabSwitcherNext", "Tab Switcher: Next Tab", "Tabs", ["Ctrl+Tab"]),
            ("tabSwitcherPrevious", "Tab Switcher: Previous Tab", "Tabs", ["Ctrl+Shift+Tab"]),
            ("smartRename", "Smart Rename Tab under Pointer", "Tabs", ["Ctrl+R"]),
            ("activateSuggestedTab", "Switch to Suggested Open Tab", "Tabs", ["Command+Enter"]),
        ]
        for (id, title, group, bindings) in early { commands.append(Command(id: id, title: title, group: group, defaults: bindings.compactMap(KeyboardShortcut.init))) }
        for number in 1...9 {
            commands.append(Command(id: "selectTab\(number)", title: "Select Tab \(number)", group: "Tabs", defaults: [KeyboardShortcut("Command+\(number)")!]))
        }
    }
    func register(_ item: NSMenuItem, group: String, id explicitID: String? = nil) {
        guard let action = item.action else { return }
        let id = explicitID ?? NSStringFromSelector(action)
        item.identifier = NSUserInterfaceItemIdentifier("shortcut:\(id)")
        let binding = item.keyEquivalent.isEmpty ? nil : KeyboardShortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
        if let index = commands.firstIndex(where: { $0.id == id }) {
            if let binding, !commands[index].defaults.contains(binding) { commands[index].defaults.append(binding) }
            commands[index].items.append(item)
        } else {
            commands.append(Command(id: id, title: item.title, group: group, defaults: binding.map { [$0] } ?? [], items: [item]))
        }
    }
    func clearMenuItems() { for index in commands.indices { commands[index].items.removeAll() } }
    func bindings(_ id: String) -> [KeyboardShortcut] {
        if let custom = overrides[id] {
            let parsed = custom.compactMap(KeyboardShortcut.init)
            if parsed.count == custom.count { return parsed }
        }
        return commands.first { $0.id == id }?.defaults ?? []
    }
    func matches(_ id: String, _ event: NSEvent) -> Bool {
        guard let binding = KeyboardShortcut(event: event) else { return false }
        return bindings(id).contains(binding)
    }
    func command(for event: NSEvent) -> Command? { commands.first { matches($0.id, event) } }
    /// Prevent Chromium's built-in command from resurrecting an app shortcut the user removed.
    func isRemovedDefault(_ event: NSEvent) -> Bool {
        guard let binding = KeyboardShortcut(event: event) else { return false }
        return commands.contains { overrides[$0.id] != nil && $0.defaults.contains(binding) && !bindings($0.id).contains(binding) }
    }
    @discardableResult func set(_ id: String, at index: Int, to value: String) -> String? {
        guard commands.contains(where: { $0.id == id }) else { return "Unknown command." }
        var current = bindings(id)
        guard (0...current.count).contains(index) else { return "This shortcut changed. Please try again." }
        if value.isEmpty {
            if current.indices.contains(index) { current.remove(at: index) }
        } else {
            guard let binding = KeyboardShortcut(value) else { return "Include Command, Control or Option, or use a function key." }
            if let conflict = commands.first(where: { $0.id != id && bindings($0.id).contains(binding) }) {
                return "Already assigned to “\(conflict.title)”. Choose another shortcut or remove it from that command."
            }
            if current.enumerated().contains(where: { $0.offset != index && $0.element == binding }) { return "This command already has that shortcut." }
            if current.indices.contains(index) { current[index] = binding } else { current.append(binding) }
        }
        overrides[id] = current.map(\.rawValue)
        save(); return nil
    }
    @discardableResult func reset(_ id: String) -> String? {
        guard let command = commands.first(where: { $0.id == id }) else { return "Unknown command." }
        for binding in command.defaults { removeConflicts(binding, except: id) }
        overrides.removeValue(forKey: id); save(); return nil
    }
    /// Helium's explicit Save action moves a conflicting binding to the chosen command.
    @discardableResult func assign(_ value: String, to id: String) -> String? {
        guard commands.contains(where: { $0.id == id }) else { return "Unknown command." }
        guard let binding = KeyboardShortcut(value) else { return "Include Command, Control or Option, or use a function key." }
        removeConflicts(binding, except: id)
        var current = bindings(id)
        if !current.contains(binding) { current.append(binding) }
        overrides[id] = current.map(\.rawValue)
        save(); return nil
    }
    @discardableResult func remove(_ value: String, from id: String) -> String? {
        guard commands.contains(where: { $0.id == id }), let binding = KeyboardShortcut(value) else { return "Invalid shortcut." }
        overrides[id] = bindings(id).filter { $0 != binding }.map(\.rawValue)
        save(); return nil
    }
    private func removeConflicts(_ binding: KeyboardShortcut, except id: String) {
        for command in commands where command.id != id {
            let current = bindings(command.id)
            if current.contains(binding) { overrides[command.id] = current.filter { $0 != binding }.map(\.rawValue) }
        }
    }
    func resetAll() { overrides.removeAll(); save() }
    func applyToMenus() {
        for command in commands {
            let current = bindings(command.id)
            for (index, item) in command.items.enumerated() {
                item.keyEquivalent = current.indices.contains(index) ? current[index].keyEquivalent : ""
                item.keyEquivalentModifierMask = current.indices.contains(index) ? current[index].modifiers : []
            }
        }
    }
    var settings: [[String: Any]] {
        commands.map { command in
            ["id": command.id, "title": command.title, "group": command.group,
             "bindings": bindings(command.id).map(\.rawValue), "defaults": command.defaults.map(\.rawValue),
             "displayBindings": bindings(command.id).map(\.display),
             "modified": bindings(command.id) != command.defaults]
        }
    }
    private func save() {
        preferences.set(overrides, forKey: Self.preferencesKey)
        applyToMenus(); onChange?()
    }
}
