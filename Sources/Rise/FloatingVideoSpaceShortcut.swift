import AppKit
import Carbon.HIToolbox
import os

/// Space, and F, belong to PiP only while the pointer is over its picture. A temporary
/// system hotkey works in other apps and consumes the key there, without an
/// Accessibility keyboard monitor. Leaving PiP releases it immediately.
@MainActor final class FloatingVideoSpaceShortcut {
    nonisolated static let identifier = EventHotKeyID(signature: 0x52535043, id: 1) // RSPC
    /// F, which returns the video to its tab as the arrows button does.
    nonisolated static let returnIdentifier = EventHotKeyID(signature: 0x52535043, id: 2)
    private var key: EventHotKeyRef?, handler: EventHandlerRef?
    private var held = false
    private let available: () -> Bool, action: () -> Void
    private let keyCode: UInt32, identifier: EventHotKeyID
    var isRegistered: Bool { key != nil }

    init(keyCode: Int = kVK_Space, identifier: EventHotKeyID = FloatingVideoSpaceShortcut.identifier,
         available: @escaping () -> Bool, action: @escaping () -> Void) {
        self.keyCode = UInt32(keyCode); self.identifier = identifier
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
                  id.signature == 0x52535043 else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<FloatingVideoSpaceShortcut>.fromOpaque(context).takeUnretainedValue()
                // Each shortcut's handler sees every one's presses; the other's go on to it.
                guard id.id == shortcut.identifier.id else { return OSStatus(eventNotHandledErr) }
                shortcut.receive(pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
                return noErr
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return }
        let status = RegisterEventHotKey(keyCode, 0, identifier, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &key)
        if status != noErr {
            stop()
            Logger(subsystem: "Rise", category: "PictureInPicture").notice("Could not register PiP shortcut \(self.keyCode): \(status)")
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
