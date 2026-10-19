package local.critter.phone

import local.critter.phone.ui.pairing.ScanGuard
import org.junit.jupiter.api.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ScanGuardTest {
    private val code = "critter-pair://192.168.1.20:47823?fp=00&code=K7M2QX9P"

    /** The camera reads the code that just failed many times a second: those reads start nothing for 3 s. */
    @Test fun theCodeThatJustFailedIsIgnoredForAWhile() {
        val guard = ScanGuard(holdMs = 3_000)
        guard.failed(code, nowMs = 10_000)
        assertTrue(guard.ignores(code, 10_000))
        assertTrue(guard.ignores(code, 12_999))
        assertFalse(guard.ignores("critter-pair://another", 10_500), "a different code is read at once")
    }

    /** After the hold, scanning the same code again tries again (Wi‑Fi fixed, certificate checked). */
    @Test fun theSameCodeRetriesOnceTheHoldIsOver() {
        val guard = ScanGuard(holdMs = 3_000)
        guard.failed(code, nowMs = 10_000)
        assertFalse(guard.ignores(code, 13_000))
        // It failed again: held again from then.
        guard.failed(code, nowMs = 14_000)
        assertTrue(guard.ignores(code, 16_000))
        assertFalse(guard.ignores(code, 17_000))
    }

    @Test fun nothingIsIgnoredBeforeAFailureOrAfterClear() {
        val guard = ScanGuard()
        assertFalse(guard.ignores(code, 0))
        guard.failed(code, nowMs = 1_000)
        guard.clear()
        assertFalse(guard.ignores(code, 1_100))
        // A failure that came from no scan (typed code, a link) holds nothing back.
        guard.failed(null, nowMs = 2_000)
        assertFalse(guard.ignores(code, 2_100))
    }
}
