import Carbon.HIToolbox
import ClawdCore

/// The global show/hide shortcut (default ⌃⌥C), registered with Carbon's
/// `RegisterEventHotKey`: it fires whichever app is in front, needs no Accessibility
/// permission, and swallows the keystroke. One instance lives as long as the app.
@MainActor
final class HotKey {
    /// Called on the main thread each time the hot key is pressed.
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers `spec` in place of the current hot key. Returns Carbon's status: `noErr`,
    /// or an error such as `eventHotKeyExistsErr` when that combination is already taken.
    func register(_ spec: HotKeySpec) -> OSStatus {
        unregister()
        if handlerRef == nil {
            var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(), hotKeyHandler, 1, &pressed,
                Unmanaged.passUnretained(self).toOpaque(), &handlerRef
            )
            guard status == noErr else { return status }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, EventHotKeyID(signature: hotKeySignature, id: 1),
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr { hotKeyRef = ref }
        return status
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    fileprivate func pressed() {
        onPress?()
    }
}

/// "CLWD": tags our hot key so the handler ignores anyone else's.
private let hotKeySignature: OSType = 0x434C_5744

/// Carbon delivers hot-key events for the application target on the main thread.
private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr, id.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.pressed() }
    return noErr
}
