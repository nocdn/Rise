import AppKit

/// A layout-aware key equivalent, in the same string format Chromium's shortcut input uses.
struct KeyboardShortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags
    static let modifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    private static let namedKeys: [String: String] = [
        "Up": "\u{F700}", "Down": "\u{F701}", "Left": "\u{F702}", "Right": "\u{F703}",
        "Tab": "\t", "Enter": "\r", "Space": " ", "Backspace": "\u{7F}", "Delete": "\u{F728}",
        "Home": "\u{F729}", "End": "\u{F72B}", "PageUp": "\u{F72C}", "PageDown": "\u{F72D}",
        "Comma": ",", "Period": ".", "Plus": "+",
    ]
    private static let shifted: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]
    init(key: String, modifiers: NSEvent.ModifierFlags) {
        var flags = modifiers.intersection(Self.modifierMask)
        if let base = Self.shifted[key] { self.key = base; flags.insert(.shift) }
        else { self.key = key.lowercased() }
        self.modifiers = flags
    }
    init?(_ value: String) {
        let parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            let flag: NSEvent.ModifierFlags
            switch part {
            case "Command": flag = .command
            case "Ctrl": flag = .control
            case "Alt": flag = .option
            case "Shift": flag = .shift
            default: return nil
            }
            guard !flags.contains(flag) else { return nil }; flags.insert(flag)
        }
        let key: String
        if let named = Self.namedKeys[last] { key = named }
        else if last.hasPrefix("F"), let number = Int(last.dropFirst()), (1...24).contains(number) {
            key = String(UnicodeScalar(0xF703 + number)!)
        } else if last.count == 1, let scalar = last.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) { key = last }
        else { return nil }
        self.init(key: key, modifiers: flags)
        guard isAssignable else { return nil }
    }
    init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let special: [UInt16: String] = [48: "\t", 36: "\r", 76: "\r", 51: "\u{7F}", 117: "\u{F728}",
            123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}"]
        guard let key = special[event.keyCode] ?? event.charactersIgnoringModifiers, key.count == 1 else { return nil }
        self.init(key: key, modifiers: event.modifierFlags)
    }
    var isAssignable: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty || isFunctionKey
    }
    private var isFunctionKey: Bool { key.unicodeScalars.first.map { (0xF704...0xF71B).contains($0.value) } ?? false }
    var rawValue: String {
        var parts: [String] = []
        for (flag, name): (NSEvent.ModifierFlags, String) in [(.command, "Command"), (.control, "Ctrl"), (.option, "Alt"), (.shift, "Shift")] {
            if modifiers.contains(flag) { parts.append(name) }
        }
        if isFunctionKey, let scalar = key.unicodeScalars.first { parts.append("F\(scalar.value-0xF703)") }
        else { parts.append(Self.namedKeys.first { $0.value == key }?.key ?? key.uppercased()) }
        return parts.joined(separator: "+")
    }
    var keyEquivalent: String {
        // AppKit matches the shifted character ({, +, !), while the saved
        // binding keeps the physical base key ([, =, 1) and Shift separately.
        guard modifiers.contains(.shift) else { return key }
        return Self.shifted.first { $0.value == key }?.key ?? key.uppercased()
    }
    var display: String {
        let symbols = rawValue.replacingOccurrences(of: "Command+", with: "⌘").replacingOccurrences(of: "Ctrl+", with: "⌃")
            .replacingOccurrences(of: "Alt+", with: "⌥").replacingOccurrences(of: "Shift+", with: "⇧")
        return symbols.replacingOccurrences(of: "Up", with: "↑").replacingOccurrences(of: "Down", with: "↓")
            .replacingOccurrences(of: "Left", with: "←").replacingOccurrences(of: "Right", with: "→")
            .replacingOccurrences(of: "Comma", with: ",").replacingOccurrences(of: "Period", with: ".")
            .replacingOccurrences(of: "Enter", with: "↩").replacingOccurrences(of: "Backspace", with: "⌫")
    }
}
