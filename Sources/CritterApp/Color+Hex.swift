import AppKit
import CritterCore

extension NSColor {
    /// `#RRGGBB` → color; anything unparsable becomes mid-gray rather than crashing.
    convenience init(hex: String, alpha: CGFloat = 1) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            self.init(white: 0.5, alpha: alpha)
            return
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension PetState {
    /// The state color (bubble stripe, count chips): waiting orange, done green, error red,
    /// running/idle gray.
    var color: NSColor { NSColor(hex: colorHex) }

    /// A darker shade of the state color for the white-on-color name tag, as in the
    /// prototype, so the white text stays legible.
    var tagColor: NSColor {
        switch self {
        case .waiting: return NSColor(hex: "#C77800")
        case .done: return NSColor(hex: "#248A3D")
        case .error: return NSColor(hex: "#D70015")
        case .running: return NSColor(hex: "#636366")
        case .idle: return NSColor(hex: "#48484A")
        }
    }
}
