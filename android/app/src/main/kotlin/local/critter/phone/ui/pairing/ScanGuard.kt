package local.critter.phone.ui.pairing

/**
 * Keeps the scanner from starting the same failed attempt over and over: the camera reads a code many times a
 * second, so the text that just failed is ignored for [holdMs]. After that, the same code tries again (the user
 * fixed the Wi‑Fi, or checked the Mac), at most once per hold. Main thread only.
 */
class ScanGuard(private val holdMs: Long = 3_000) {
    private var text: String? = null
    private var failedAt = 0L

    /** An attempt from [text] failed at [nowMs]; null (a typed code, a link) holds nothing back. */
    fun failed(text: String?, nowMs: Long) {
        this.text = text
        failedAt = nowMs
    }

    fun ignores(text: String, nowMs: Long): Boolean = text == this.text && nowMs - failedAt < holdMs

    fun clear() {
        text = null
    }
}
