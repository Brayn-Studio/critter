import CritterClient
import CritterKit
import SwiftUI
import UIKit

/// The app's colours (visual design §5, Android `Theme.kt` and `BoardColors.kt`), all taken from the skins' palettes
/// or the desktop pet's head marks. The light and dark sets follow the system appearance on their own (each colour
/// is a dynamic one); the board's set is fixed. The meadow's skies are `SkyColors` (CritterClient).
enum Theme {
    // MARK: - Surfaces and ink

    /// The page.
    static let bg = Color(light: 0xF4F2FA, dark: 0x17142A)
    /// Cards.
    static let surface = Color(light: 0xFFFFFF, dark: 0x221E36)
    /// Wells, secondary buttons, unlit meter cells.
    static let surface2 = Color(light: 0xEFECF7, dark: 0x1B1830)
    /// The darker bottom row (lip) of a surface.
    static let shade = Color(light: 0xDED7F0, dark: 0x0E0B1C)
    /// Dividers.
    static let line = Color(light: 0xE6E1F2, dark: 0x2F2A47)

    /// Body text: Sprig's eye colour (13.6:1 on `bg`).
    static let ink = Color(light: 0x2A2140, dark: 0xF3F0FC)
    /// Secondary text (6.4:1 on white).
    static let ink2 = Color(light: 0x625A7A, dark: 0xADA6C6)
    /// Icons and placeholders only, never text that has to be read.
    static let ink3 = Color(light: 0x8C85A3, dark: 0x7D7698)

    // MARK: - Sprig's purple

    /// The primary button (white text 6.2:1).
    static let brand = Color(light: 0x6346D6, dark: 0x9C88FF)
    /// The primary button's lip.
    static let brandDeep = Color(light: 0x4A30B0, dark: 0x6A54D8)
    /// What is chosen.
    static let brandSoft = Color(light: 0xECE7FF, dark: 0x2E2752)
    /// Text on `brand`.
    static let onBrand = Color(light: 0xFFFFFF, dark: 0x160F2E)
    /// A switch's knob.
    static let knob = Color(light: 0xFFFFFF, dark: 0xE9E5F7)
    /// The three highlight cells at the top left of a coloured face (white at 50 %, 40 % in the dark).
    static let highlight = Color(light: 0xFFFFFF, lightOpacity: 0.5, dark: 0xFFFFFF, darkOpacity: 0.4)

    // MARK: - States

    static let run = Color(light: 0xA86B00, dark: 0xFFC655)
    static let runBg = Color(light: 0xFFF1CC, dark: 0x3A2F14)
    static let runGlyph = Color(light: 0xE8A21E, dark: 0xF2B33D)
    /// The one loud colour of the app, only for waiting: the fill, with ink on it (7.4:1).
    static let wait = Color(rgb: 0xFF9F0A)
    static let waitDeep = Color(light: 0xD97F00, dark: 0xC27200)
    /// Waiting words on a light (or dark) background rather than on the orange.
    static let waitInk = Color(light: 0x9A5600, dark: 0xFFB54A)
    static let waitBg = Color(light: 0xFFE9CC, dark: 0x3D2A12)
    static let done = Color(light: 0x1E7A3A, dark: 0x5DD47E)
    static let doneBg = Color(light: 0xDFF5E4, dark: 0x173324)
    static let doneGlyph = Color(light: 0x2FB457, dark: 0x5DD47E)
    static let err = Color(light: 0xC42A20, dark: 0xFF7A70)
    static let errBg = Color(light: 0xFFE3E0, dark: 0x3D1A1C)
    static let errGlyph = Color(light: 0xF0453A, dark: 0xFF7A70)
    static let idle = Color(light: 0x625A7A, dark: 0xADA6C6)
    static let idleBg = Color(light: 0xECEAF3, dark: 0x2A2640)
    /// Ink on the solid waiting orange, the same in both themes.
    static let inkOnWait = Color(rgb: 0x2A2140)

    // MARK: - The command slip and the scrim

    static let term = Color(light: 0x2A2140, dark: 0x0E0B1C)
    static let termInk = Color(rgb: 0xF3F0FC)
    /// The prompt sign.
    static let termDim = Color(light: 0xA89FC8, dark: 0x8E86AE)
    /// Under a sheet.
    static let scrim = Color(light: 0x1A1230, lightOpacity: 0.42, dark: 0x05030C, darkOpacity: 0.6)

    /// A state's colours: its text, its background, its symbol, and the darker bottom row of its tag.
    struct StateColors {
        var fg: Color
        var bg: Color
        var glyph: Color
        var lip: Color
    }

    /// A state's colours (Android `CritterColors.state`). Waiting is the loud one: ink on the solid orange.
    static func state(_ state: PetState) -> StateColors {
        switch state {
        case .running: StateColors(fg: run, bg: runBg, glyph: runGlyph, lip: run.opacity(0.18))
        case .waiting: StateColors(fg: inkOnWait, bg: wait, glyph: wait, lip: waitDeep)
        case .done: StateColors(fg: done, bg: doneBg, glyph: doneGlyph, lip: done.opacity(0.18))
        case .error: StateColors(fg: err, bg: errBg, glyph: errGlyph, lip: err.opacity(0.18))
        case .idle: StateColors(fg: idle, bg: idleBg, glyph: ink3, lip: idle.opacity(0.18))
        }
    }

    /// The connection's words (`tone`) and its dot: green while connected, red when only pairing again helps, grey
    /// otherwise (Android `ConnectionCard`, `ConnectionTag`).
    static func conn(_ state: ConnState) -> (tone: Color, dot: Color) {
        switch state {
        case .connected: (done, doneGlyph)
        case .needsRepair: (err, errGlyph)
        default: (ink2, ink3)
        }
    }

    // MARK: - Words several screens share

    /// A request that is gone: answered on the Mac (or anywhere else) before the phone did.
    static let handledElsewhere = "已在电脑上处理"

    /// The paired Mac's name, "Mac" when it has none.
    static func macName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "Mac" }
        return name
    }

    // MARK: - The board

    /// The board's colours (design §5): fixed, not following the theme; it is on for hours, often on an OLED.
    enum Board {
        static let bg = Color(rgb: 0x000000)
        static let clock = Color(rgb: 0x8D88A3)
        static let name = Color(rgb: 0xB9B4CC)
        static let dim = Color(rgb: 0x7D7896)
        static let horizon = Color(rgb: 0x1A1630)
        static let grass = Color(rgb: 0x16301B)
        static let card = Color(rgb: 0x0C0A14)
        static let edge = Color(rgb: 0x221E33)
        static let wait = Color(rgb: 0xFF9F0A)
        /// Bubbles, the mode button, the command slip (the mockups' `.board` tokens).
        static let card2 = Color(rgb: 0x15121F)
        /// What a pro card's session is doing.
        static let doing = Color(rgb: 0xA39EB8)
        /// Text on a waiting bubble or card, warm next to the orange edge.
        static let waitInk = Color(rgb: 0xF3D7AE)
        /// Meter cells: unlit, and lit while calm, busy or nearly full (dimmed versions of the meter colours).
        static let meterOff = Color(rgb: 0x1C1830)
        static let meterCalm = Color(rgb: 0x3C6E43)
        static let meterBusy = Color(rgb: 0x8A6A22)
        static let meterHot = Color(rgb: 0x8C3A35)
    }
}

extension Color {
    /// 0xRRGGBB (as `SkyColors` and the manifests write them).
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(uiColor: UIColor(rgb: rgb, alpha: opacity))
    }

    /// One colour in the light appearance and another in the dark, switching with the system.
    init(light: UInt32, lightOpacity: Double = 1, dark: UInt32, darkOpacity: Double = 1) {
        let light = UIColor(rgb: light, alpha: lightOpacity)
        let dark = UIColor(rgb: dark, alpha: darkOpacity)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension UIColor {
    /// 0xRRGGBB.
    convenience init(rgb: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
