import Foundation

/// A global hot key: a virtual key code (`kVK_*`, keyboard-layout independent) plus a
/// modifier mask with the same bit values as Carbon's `cmdKey`/`shiftKey`/`optionKey`/
/// `controlKey`, so it can be handed straight to `RegisterEventHotKey`.
public struct HotKeySpec: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    /// ⌃⌥C (`kVK_ANSI_C` is 8).
    public static let `default` = HotKeySpec(keyCode: 8, modifiers: control | option)

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The Carbon mask for an `NSEvent.ModifierFlags` raw value; only ⇧⌃⌥⌘ count.
    public static func carbonModifiers(cocoaFlags: UInt) -> UInt32 {
        var mask: UInt32 = 0
        if cocoaFlags & (1 << 17) != 0 { mask |= shift }
        if cocoaFlags & (1 << 18) != 0 { mask |= control }
        if cocoaFlags & (1 << 19) != 0 { mask |= option }
        if cocoaFlags & (1 << 20) != 0 { mask |= command }
        return mask
    }

    /// Whether this combination may become the global hot key: it needs ⌃, ⌥ or ⌘ --
    /// a plain or shifted key would be taken away from typing in every app.
    public var isRecordable: Bool {
        modifiers & (Self.control | Self.option | Self.command) != 0
    }
}

/// How a `HotKeySpec` is shown: modifiers in the standard macOS order ⌃⌥⇧⌘, then the key.
public enum HotKeyFormat {
    /// ANSI-layout virtual key codes of the letters and digits (`kVK_ANSI_*`).
    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
    ]

    public static func display(_ s: HotKeySpec) -> String {
        var text = ""
        if s.modifiers & HotKeySpec.control != 0 { text += "⌃" }
        if s.modifiers & HotKeySpec.option != 0 { text += "⌥" }
        if s.modifiers & HotKeySpec.shift != 0 { text += "⇧" }
        if s.modifiers & HotKeySpec.command != 0 { text += "⌘" }
        return text + (keyNames[s.keyCode] ?? "Key\(s.keyCode)")
    }
}
