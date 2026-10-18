package local.critter.core.board

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BoardTriggerTest {
    private val open = BoardTrigger.Action.Open
    private val close = BoardTrigger.Action.Close
    private val none = BoardTrigger.Action.None

    private fun shownTrigger(): BoardTrigger = BoardTrigger().apply {
        onPower(true, 0)
        onBoardShown(true)
    }

    @Test fun opensAfterHoldWhileChargingAndLandscape() {
        val t = BoardTrigger()
        assertEquals(none, t.onPower(true, 0))
        assertEquals(none, t.onOrientation(landscape = true, still = true, nowMs = 0))
        assertEquals(none, t.onOrientation(true, true, 2_900))
        assertEquals(3_000L, t.nextDeadline())
        assertEquals(open, t.onTick(3_000))
        // Not asked again for the same hold.
        assertEquals(none, t.onOrientation(true, true, 3_500))
    }

    @Test fun movingResetsTheHold() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(true, true, 0)
        t.onOrientation(true, false, 2_000)
        assertNull(t.nextDeadline())
        t.onOrientation(true, true, 2_500)
        assertEquals(none, t.onOrientation(true, true, 5_000))
        assertEquals(open, t.onOrientation(true, true, 5_500))
    }

    @Test fun doesNotOpenWhenNotCharging() {
        val t = BoardTrigger()
        assertEquals(none, t.onOrientation(true, true, 0))
        assertEquals(none, t.onOrientation(true, true, 10_000))
        assertEquals(none, t.onTick(20_000))
        assertNull(t.nextDeadline())
    }

    @Test fun brieflyPortraitDoesNotExit() {
        val t = shownTrigger()
        assertEquals(none, t.onOrientation(false, true, 1_000))
        assertEquals(none, t.onOrientation(true, true, 3_000)) // 2 s upright, then back
        assertNull(t.nextDeadline())
        assertEquals(none, t.onTick(10_000))
        assertEquals(none, t.onOrientation(false, true, 11_000))
        assertEquals(none, t.onOrientation(true, true, 13_900))
    }

    @Test fun portraitForThreeSecondsExits() {
        val t = shownTrigger()
        assertEquals(none, t.onOrientation(false, true, 1_000))
        assertEquals(4_000L, t.nextDeadline())
        assertEquals(none, t.onTick(3_999))
        assertEquals(close, t.onTick(4_000))
    }

    @Test fun unplugExitsAfterTenSeconds() {
        val t = shownTrigger()
        assertEquals(none, t.onPower(false, 5_000))
        assertEquals(15_000L, t.nextDeadline())
        assertEquals(none, t.onTick(14_999))
        assertEquals(close, t.onTick(15_000))
    }

    @Test fun replugWithinTenSecondsKeepsBoard() {
        val t = shownTrigger()
        t.onPower(false, 5_000)
        assertEquals(none, t.onPower(true, 12_000))
        assertNull(t.nextDeadline())
        assertEquals(none, t.onTick(30_000))
    }

    @Test fun manualExitSuppressesUntilReplug() {
        val t = shownTrigger()
        t.onManualExit(1_000)
        t.onBoardShown(false)
        t.onOrientation(true, true, 2_000)
        assertEquals(none, t.onOrientation(true, true, 20_000))
        assertNull(t.nextDeadline())
        // Unplug and plug in again: automatic opening is back.
        t.onPower(false, 21_000)
        t.onPower(true, 25_000)
        t.onOrientation(true, true, 25_000)
        assertEquals(open, t.onOrientation(true, true, 28_000))
    }

    @Test fun sensorWantedOnlyWhileCharging() {
        val t = BoardTrigger()
        assertFalse(t.sensorWanted)
        t.onPower(true, 0)
        assertTrue(t.sensorWanted)
        t.onPower(false, 1)
        assertFalse(t.sensorWanted)
    }

    @Test fun flatOnTheTableIsNotLandscape() {
        assertTrue(BoardTrigger.isLandscape(9.7f, 0.5f, 1.0f))
        assertTrue(BoardTrigger.isLandscape(-9.7f, 0.5f, 1.0f))
        assertFalse(BoardTrigger.isLandscape(0.3f, 0.5f, 9.8f))
        assertFalse(BoardTrigger.isLandscape(0.3f, 9.8f, 1.0f)) // upright portrait
        assertFalse(BoardTrigger.isLandscape(7.5f, 0f, 6.5f)) // propped back too far
    }

    @Test fun stillMeansNoAxisMovedHalfAUnitInOneAndAHalfSeconds() {
        val s = BoardTrigger.Stillness()
        assertTrue(s.add(0, 9.7f, 0f, 1f))
        assertTrue(s.add(500, 9.8f, 0.1f, 1.2f))
        assertFalse(s.add(1_000, 9.0f, 0.1f, 1.2f))
        // The jolt leaves the window after 1.5 s.
        assertFalse(s.add(1_900, 9.0f, 0.1f, 1.2f))
        assertTrue(s.add(2_100, 9.0f, 0.1f, 1.2f))
    }
}
