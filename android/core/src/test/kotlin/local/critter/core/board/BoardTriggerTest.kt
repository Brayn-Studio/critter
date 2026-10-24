package local.critter.core.board

import local.critter.core.board.BoardTrigger.Pose
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BoardTriggerTest {
    private val open = BoardTrigger.Action.Open
    private val close = BoardTrigger.Action.Close
    private val none = BoardTrigger.Action.None
    private val blocked = BoardTrigger.Action.Blocked

    private val landscape = Pose.Landscape
    private val upright = Pose.Upright
    private val flat = Pose.Other

    private fun shownTrigger(): BoardTrigger = BoardTrigger().apply {
        onPower(true, 0)
        onBoardShown(true)
    }

    @Test fun opensAfterHoldWhileChargingAndLandscape() {
        val t = BoardTrigger()
        assertEquals(none, t.onPower(true, 0))
        assertEquals(none, t.onOrientation(landscape, still = true, nowMs = 0))
        assertEquals(none, t.onOrientation(landscape, true, 2_900))
        assertEquals(3_000L, t.nextDeadline())
        assertEquals(open, t.onTick(3_000))
        t.onBoardShown(true)
        // Not asked again for the same hold.
        assertEquals(none, t.onOrientation(landscape, true, 3_500))
    }

    @Test fun movingResetsTheHold() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        t.onOrientation(landscape, false, 2_000)
        assertNull(t.nextDeadline())
        t.onOrientation(landscape, true, 2_500)
        assertEquals(none, t.onOrientation(landscape, true, 5_000))
        assertEquals(open, t.onOrientation(landscape, true, 5_500))
    }

    @Test fun doesNotOpenWhenNotCharging() {
        val t = BoardTrigger()
        assertEquals(none, t.onOrientation(landscape, true, 0))
        assertEquals(none, t.onOrientation(landscape, true, 10_000))
        assertEquals(none, t.onTick(20_000))
        assertNull(t.nextDeadline())
    }

    @Test fun doesNotOpenWhenSwitchedOff() {
        val t = BoardTrigger()
        t.autoOpen = false
        t.onPower(true, 0)
        assertFalse(t.sensorWanted)
        t.onOrientation(landscape, true, 0)
        assertEquals(none, t.onOrientation(landscape, true, 5_000))
        assertNull(t.nextDeadline())
        // A board opened by hand still closes when stood upright, so the sensor runs while it is up.
        t.onBoardShown(true)
        assertTrue(t.sensorWanted)
        t.onOrientation(upright, true, 6_000)
        assertEquals(close, t.onTick(9_000))
    }

    /**
     * Switched off in the middle of a hold, the hold is forgotten: its deadline would only come round to an open that
     * can no longer happen (a caller that re-posts a tick for it would spin), and switched on again it must not
     * open on the old stillness, without a fresh 3 s.
     */
    @Test fun switchingOffDuringTheHoldForgetsIt() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        assertEquals(3_000L, t.nextDeadline())
        t.autoOpen = false
        assertNull(t.nextDeadline())
        assertEquals(none, t.onTick(3_000))
        assertNull(t.nextDeadline())
        // Switched on again: the hold starts afresh from the next still reading.
        t.autoOpen = true
        assertNull(t.nextDeadline())
        assertEquals(none, t.onTick(3_500))
        assertEquals(none, t.onOrientation(landscape, true, 4_000))
        assertEquals(7_000L, t.nextDeadline())
        assertEquals(none, t.onTick(6_999))
        assertEquals(open, t.onTick(7_000))

        // Off and on again before the old deadline: still no open at it.
        val quick = BoardTrigger()
        quick.onPower(true, 0)
        quick.onOrientation(landscape, true, 0)
        quick.autoOpen = false
        quick.autoOpen = true
        assertEquals(none, quick.onTick(3_000))
        assertNull(quick.nextDeadline())
    }

    @Test fun brieflyUprightDoesNotExit() {
        val t = shownTrigger()
        assertEquals(none, t.onOrientation(upright, true, 1_000))
        assertEquals(none, t.onOrientation(landscape, true, 3_000)) // 2 s upright, then back
        assertNull(t.nextDeadline())
        assertEquals(none, t.onTick(10_000))
        assertEquals(none, t.onOrientation(upright, true, 11_000))
        assertEquals(none, t.onOrientation(landscape, true, 13_900))
    }

    @Test fun uprightForThreeSecondsExits() {
        val t = shownTrigger()
        assertEquals(none, t.onOrientation(upright, true, 1_000))
        assertEquals(4_000L, t.nextDeadline())
        assertEquals(none, t.onTick(3_999))
        assertEquals(close, t.onTick(4_000))
    }

    /** Ruling P3-R4: only standing it up closes the board; flat on a desk or a charging pad does not. */
    @Test fun lyingFlatDoesNotExit() {
        val t = shownTrigger()
        assertEquals(none, t.onOrientation(flat, true, 1_000))
        assertNull(t.nextDeadline())
        assertEquals(none, t.onOrientation(flat, true, 30_000))
        assertEquals(none, t.onTick(60_000))
        // Upright after lying flat: the 3 s start from standing up.
        assertEquals(none, t.onOrientation(upright, true, 61_000))
        assertEquals(none, t.onTick(63_999))
        assertEquals(close, t.onTick(64_000))
    }

    @Test fun lyingFlatDoesNotOpen() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(flat, true, 0)
        assertEquals(none, t.onOrientation(flat, true, 5_000))
        assertNull(t.nextDeadline())
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
        assertFalse(t.sensorWanted)
        t.onOrientation(landscape, true, 2_000)
        assertEquals(none, t.onOrientation(landscape, true, 20_000))
        assertNull(t.nextDeadline())
        // Unplug and plug in again: automatic opening is back.
        t.onPower(false, 21_000)
        t.onPower(true, 25_000)
        t.onOrientation(landscape, true, 25_000)
        assertEquals(open, t.onOrientation(landscape, true, 28_000))
    }

    /** The screen switched off over a board: it stays up (not re-opened, no screen lit), and nothing opens in the dark. */
    @Test fun screenOffDoesNotReopen() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        assertEquals(open, t.onTick(3_000))
        t.onBoardShown(true)

        assertEquals(none, t.onScreen(false, 5_000))
        assertFalse(t.sensorWanted)
        assertNull(t.nextDeadline())
        // Readings that still trickle in (a wake-up, a batch) change nothing while the screen is off.
        assertEquals(none, t.onOrientation(landscape, true, 6_000))
        assertEquals(none, t.onOrientation(landscape, true, 9_500))
        assertEquals(none, t.onTick(20_000))

        // Even with the board gone, the dark screen is never lit by an opening.
        t.onBoardShown(false)
        assertEquals(none, t.onOrientation(landscape, true, 21_000))
        assertEquals(none, t.onOrientation(landscape, true, 25_000))
        assertNull(t.nextDeadline())

        // Back on: a fresh 3 s hold first.
        assertEquals(none, t.onScreen(true, 30_000))
        assertTrue(t.sensorWanted)
        assertEquals(none, t.onOrientation(landscape, true, 30_500))
        assertEquals(none, t.onTick(33_000))
        assertEquals(open, t.onTick(33_500))
    }

    @Test fun screenOffForgetsAHoldInProgress() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        t.onScreen(false, 2_000)
        assertNull(t.nextDeadline())
        assertEquals(none, t.onTick(3_000))
    }

    /** Pulling the charger while the board's screen is off still takes the board away 10 s later. */
    @Test fun unplugWhileHiddenStillCloses() {
        val t = shownTrigger()
        t.onScreen(false, 1_000)
        assertEquals(none, t.onPower(false, 5_000))
        assertEquals(15_000L, t.nextDeadline())
        assertEquals(none, t.onTick(14_999))
        assertEquals(close, t.onTick(15_000))
    }

    /** Asked to open, and nothing came up within 2 s: no more asking until the next plug-in. */
    @Test fun openThatNeverShowsBacksOffUntilReplug() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        assertEquals(open, t.onTick(3_000))
        assertEquals(5_000L, t.nextDeadline())
        assertEquals(blocked, t.onTick(5_000))
        assertFalse(t.sensorWanted)
        t.onOrientation(landscape, true, 5_500)
        assertEquals(none, t.onOrientation(landscape, true, 9_000))
        assertNull(t.nextDeadline())

        t.onPower(false, 10_000)
        t.onPower(true, 11_000)
        t.onOrientation(landscape, true, 11_000)
        assertEquals(open, t.onTick(14_000))
    }

    /** The 2 s tick after an opening the system never showed says so, once; the ticks after it are quiet. */
    @Test fun openThatNeverShowsReportsBlocked() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        assertEquals(open, t.onTick(3_000))
        assertEquals(none, t.onTick(4_900))
        assertEquals(blocked, t.onTick(5_000))
        assertEquals(none, t.onTick(5_100))
        assertEquals(none, t.onOrientation(landscape, true, 6_000))
        assertNull(t.nextDeadline())
    }

    @Test fun openThatFailsOutrightReportsBlocked() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        assertEquals(open, t.onTick(3_000))
        assertEquals(blocked, t.onOpenFailed())
        assertEquals(none, t.onTick(5_000))
    }

    @Test fun openThatShowsInTimeIsNotSuppressed() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        assertEquals(open, t.onTick(3_000))
        t.onBoardShown(true)
        assertNull(t.nextDeadline())
        assertEquals(none, t.onTick(5_000))
        // Closed by the trigger (stood up), then laid down again: it opens again on this charge.
        t.onOrientation(upright, true, 6_000)
        assertEquals(close, t.onTick(9_000))
        t.onBoardShown(false)
        t.onOrientation(landscape, true, 10_000)
        assertEquals(open, t.onTick(13_000))
    }

    @Test fun openThatFailsOutrightBacksOffUntilReplug() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        assertEquals(open, t.onTick(3_000))
        t.onOpenFailed()
        assertNull(t.nextDeadline())
        t.onOrientation(landscape, true, 4_000)
        assertEquals(none, t.onTick(10_000))
    }

    /** From the Open until its board comes up: that board opened by itself. */
    @Test fun awaitingOpenFromTheOpenUntilTheBoardComesUp() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        assertFalse(t.awaitingOpen)
        assertEquals(open, t.onTick(3_000))
        assertTrue(t.awaitingOpen)
        t.onBoardShown(true)
        assertFalse(t.awaitingOpen)
    }

    /** Pulled within the 2 s: a board the user opens by hand later is not the one that was asked for. */
    @Test fun awaitingOpenEndsWhenTheChargerIsPulled() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onOrientation(landscape, true, 0)
        assertEquals(open, t.onTick(3_000))
        assertEquals(none, t.onPower(false, 4_000))
        assertFalse(t.awaitingOpen)
        assertNull(t.nextDeadline())
    }

    @Test fun awaitingOpenEndsWhenTheOpenIsGivenUp() {
        val timedOut = BoardTrigger()
        timedOut.onPower(true, 0)
        timedOut.onOrientation(landscape, true, 0)
        assertEquals(open, timedOut.onTick(3_000))
        assertEquals(blocked, timedOut.onTick(5_000))
        assertFalse(timedOut.awaitingOpen)

        val failed = BoardTrigger()
        failed.onPower(true, 0)
        failed.onOrientation(landscape, true, 0)
        assertEquals(open, failed.onTick(3_000))
        failed.onOpenFailed()
        assertFalse(failed.awaitingOpen)
    }

    /** A board opened by hand was never asked for. */
    @Test fun aBoardOpenedByHandWasNotAwaited() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        assertFalse(t.awaitingOpen)
        t.onBoardShown(true)
        assertFalse(t.awaitingOpen)
    }

    @Test fun sensorWantedOnlyWhileChargingWithTheScreenOn() {
        val t = BoardTrigger()
        assertFalse(t.sensorWanted)
        t.onPower(true, 0)
        assertTrue(t.sensorWanted)
        t.onScreen(false, 1)
        assertFalse(t.sensorWanted)
        t.onScreen(true, 2)
        assertTrue(t.sensorWanted)
        t.onPower(false, 3)
        assertFalse(t.sensorWanted)
    }

    @Test fun posesFromGravity() {
        assertEquals(landscape, BoardTrigger.poseOf(9.7f, 0.5f, 1.0f))
        assertEquals(landscape, BoardTrigger.poseOf(-9.7f, 0.5f, 1.0f))
        assertEquals(flat, BoardTrigger.poseOf(0.3f, 0.5f, 9.8f)) // flat on the table
        assertEquals(upright, BoardTrigger.poseOf(0.3f, 9.8f, 1.0f)) // held upright
        assertEquals(upright, BoardTrigger.poseOf(0.3f, -9.8f, 1.0f)) // upside down
        assertEquals(flat, BoardTrigger.poseOf(7.5f, 0f, 6.5f)) // propped back too far
        assertEquals(flat, BoardTrigger.poseOf(5f, 5f, 6.5f)) // in between
    }

    @Test fun stillMeansNoAxisMovedHalfAUnitInOneAndAHalfSeconds() {
        val s = BoardTrigger.Stillness()
        assertFalse(s.add(0, 9.7f, 0f, 1f))
        assertTrue(s.add(1_500, 9.8f, 0.1f, 1.2f))
        assertFalse(s.add(2_000, 9.0f, 0.1f, 1.2f))
        // The reading at 1.5 s held until the jolt at 2 s: still in the window at 3.4 s, gone from it at 3.5 s.
        assertFalse(s.add(3_400, 9.0f, 0.1f, 1.2f))
        assertTrue(s.add(3_500, 9.0f, 0.1f, 1.2f))
    }

    /** One reading says nothing about movement: the phone may be swinging through landscape. */
    @Test fun oneReadingIsNotStill() {
        assertFalse(BoardTrigger.Stillness().add(10_000, 9.7f, 0f, 1f))
        val s = BoardTrigger.Stillness()
        s.add(0, 9.7f, 0f, 1f)
        s.clear()
        assertFalse(s.add(5_000, 9.7f, 0f, 1f), "cleared: a fresh start")
    }

    /** Still since the first of the readings that showed it, not since the window was first full. */
    @Test fun stillSinceIsWhereTheStillReadingsBegin() {
        val s = BoardTrigger.Stillness()
        for (t in 0L..1_400L step 200) s.add(t, 9.7f, 0f, 1f)
        assertNull(s.stillSince)
        assertTrue(s.add(1_600, 9.7f, 0f, 1f))
        assertEquals(0L, s.stillSince)
        assertTrue(s.add(5_000, 9.7f, 0f, 1f))
        assertEquals(0L, s.stillSince, "the same still spell")
        assertFalse(s.add(5_200, 5f, 5f, 5f))
        assertNull(s.stillSince)
    }

    /**
     * Design §8.6: charging, landscape and still for 3 s opens the board. Real readings every 200 ms from 0: the
     * 1.5 s it takes to see the phone is still are part of those 3 s, not added to them.
     */
    @Test fun gravityReadingsOpenTheBoardAfterThreeSeconds() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onSensorStarted()
        var openedAt: Long? = null
        for (now in 0L..6_000L step 100) {
            val action = when {
                now % 200 == 0L -> t.onGravity(9.7f, 0.3f, 1.0f, now)
                (t.nextDeadline() ?: Long.MAX_VALUE) <= now -> t.onTick(now)
                else -> none
            }
            if (action == open && openedAt == null) openedAt = now
        }
        assertEquals(3_000L, openedAt)
    }

    /** Readings from before the sensor was started again (the screen was off, say) count for nothing. */
    @Test fun aRestartedSensorStartsTheStillnessAfresh() {
        val t = BoardTrigger()
        t.onPower(true, 0)
        t.onSensorStarted()
        for (now in 0L..2_000L step 200) t.onGravity(9.7f, 0.3f, 1.0f, now)
        t.onScreen(false, 2_100)
        t.onScreen(true, 10_000)
        t.onSensorStarted()
        var openedAt: Long? = null
        for (now in 10_000L..16_000L step 100) {
            val action = when {
                now % 200 == 0L -> t.onGravity(9.7f, 0.3f, 1.0f, now)
                (t.nextDeadline() ?: Long.MAX_VALUE) <= now -> t.onTick(now)
                else -> none
            }
            if (action == open && openedAt == null) openedAt = now
        }
        assertEquals(13_000L, openedAt)
    }

    @Test fun stillAfterAFullWindow() {
        val s = BoardTrigger.Stillness()
        for (t in 0L..1_400L step 200) assertFalse(s.add(t, 9.7f, 0f, 1f), "at $t ms the readings cover less than 1.5 s")
        assertTrue(s.add(1_600, 9.7f, 0f, 1f))
    }
}
