package local.critter.phone.ui.theme

import androidx.compose.ui.graphics.Color

/** The board's colors (design §5): fixed, not following the theme; it is on for hours, often on an OLED. */
object BoardColors {
    val bg = Color(0xFF000000)
    val clock = Color(0xFF8D88A3)
    val name = Color(0xFFB9B4CC)
    val dim = Color(0xFF7D7896)
    val horizon = Color(0xFF1A1630)
    val grass = Color(0xFF16301B)
    val card = Color(0xFF0C0A14)
    val edge = Color(0xFF221E33)
    val wait = Color(0xFFFF9F0A)

    // The mockup's other board tokens (`.board` in the mockup CSS), for the pieces §5 does not name.

    /** Bubbles, the mode button, the command slip. */
    val card2 = Color(0xFF15121F)

    /** What a pro card's session is doing. */
    val doing = Color(0xFFA39EB8)

    /** Text on a waiting bubble or card (warm, next to the orange edge). */
    val waitInk = Color(0xFFF3D7AE)

    /** Meter cells: unlit, and lit while calm or busy (dimmed versions of the meter colors). */
    val meterOff = Color(0xFF1C1830)
    val meterCalm = Color(0xFF3C6E43)
    val meterBusy = Color(0xFF8A6A22)

    /** Lit cells of a nearly full meter; the mockup shows no board meter past 85%, so this dims the red like the others. */
    val meterHot = Color(0xFF8C3A35)

    val meter = MeterColors(off = meterOff, calm = meterCalm, busy = meterBusy, hot = meterHot)
}
