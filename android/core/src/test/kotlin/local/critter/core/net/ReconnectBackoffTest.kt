package local.critter.core.net

import kotlin.test.Test
import kotlin.test.assertEquals

class ReconnectBackoffTest {
    @Test fun backoffDoublesToCapAndResets() {
        val b = ReconnectBackoff()
        val delays = List(8) { b.nextDelayMs() }
        assertEquals(listOf(2_000L, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000, 60_000), delays)
        b.reset()
        assertEquals(2_000L, b.nextDelayMs())
    }
}
