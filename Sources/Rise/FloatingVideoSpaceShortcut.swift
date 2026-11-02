import AppKit
import Carbon.HIToolbox
import os

/// Space belongs to PiP only while the pointer is over its picture. A temporary
/// system hotkey works in other apps and consumes the key there, without an
/// Accessibility keyboard monitor. Leaving PiP releases it immediately.
@MainActor final class FloatingVideoSpaceShortcut {
    static let identifier = EventHotKeyID(signature: 0x52535043, id: 1) // RSPC
    private var key: EventHotKeyRef?, handler: EventHandlerRef?
    private var held = false
    private let available: () -> Bool, action: () -> Void
    var isRegistered: Bool { key != nil }

    init(available: @escaping () -> Bool, action: @escaping () -> Void) {
        self.available = available; self.action = action
    }
    func setEnabled(_ enabled: Bool) {
        guard enabled else { stop(); return }
        guard key == nil else { return }
        var types = [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: $0)
        }
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x52535043, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<FloatingVideoSpaceShortcut>.fromOpaque(context).takeUnretainedValue()
                shortcut.receive(pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
                return noErr
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return }
        let status = RegisterEventHotKey(UInt32(kVK_Space), 0, Self.identifier, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &key)
        if status != noErr {
            stop()
            Logger(subsystem: "Rise", category: "PictureInPicture").notice("Could not register PiP Space shortcut: \(status)")
        }
    }
    private func receive(pressed: Bool) {
        if !pressed { held = false; return }
        guard !held, available() else { return }
        held = true; action()
    }
    private func stop() {
        if let key { UnregisterEventHotKey(key); self.key = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        held = false
    }
    deinit {
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
