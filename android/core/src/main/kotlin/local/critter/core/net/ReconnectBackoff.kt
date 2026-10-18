package local.critter.core.net

/** Delays between reconnect attempts: [initialMs], doubling each time, capped at [maxMs]. */
class ReconnectBackoff(private val initialMs: Long = 2_000, private val maxMs: Long = 60_000) {
    private var next = initialMs

    /** The delay to wait before the next attempt; each call advances the schedule. */
    fun nextDelayMs(): Long {
        val delay = next
        next = (next * 2).coerceAtMost(maxMs)
        return delay
    }

    /** Call after a successful connection. */
    fun reset() {
        next = initialMs
    }
}
