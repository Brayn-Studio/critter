package local.critter.core.motion

import local.critter.core.builtin
import local.critter.core.withState
import local.critter.core.protocol.PetState
import local.critter.core.skin.ClipKey
import local.critter.core.skin.SKIN_STATES
import local.critter.core.skin.SkinManifest
import local.critter.core.skin.Tint
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun makeActor(skin: SkinManifest = builtin(), seed: Long = 7, reduceMotion: Boolean = false) =
    MotionActor(skin = skin, rng = MotionRNG(seed = seed), reduceMotion = reduceMotion)

/** Steps until the one-shot ends (or `limit` ticks), returning how many steps it took. */
private fun stepUntilLoop(a: MotionActor, limit: Int = 500): Int {
    var n = 0
    while (a.isPlayingOnce && n < limit) { a.step(); n += 1 }
    return n
}

class MotionStateTest {
    // MARK: - enterState

    @Test
    fun quietEnterSetsLoopOnly() {
        val a = makeActor()
        a.enterState(PetState.waiting, quiet = true)
        assertEquals(PetState.waiting, a.state)
        assertEquals("ask", a.currentClipName)
        assertFalse(a.isPlayingOnce)
        assertTrue(a.badgeVisible)
        assertEquals(16, a.snapshot().badge?.x)
        assertEquals("q", a.snapshot().accessory?.glyph)
    }

    @Test
    fun enterPlaysEnterThenLoop() {
        val a = makeActor()
        a.enterState(PetState.done)
        assertEquals("celebrate", a.currentClipName)
        assertTrue(a.isPlayingOnce)
        assertNull(a.tint)
        assertEquals(24, stepUntilLoop(a))
        assertEquals("content", a.currentClipName)
    }

    @Test
    fun leavingLaptopClosesBeforeAlert() {
        val a = makeActor()
        a.enterState(PetState.running, quiet = true)
        assertEquals("laptop", a.variant)
        assertEquals("laptop", a.currentClipName)
        a.enterState(PetState.waiting)
        assertEquals("lap_close", a.currentClipName)
        assertNull(a.snapshot().badge)
        repeat(6) { a.step() }
        assertEquals("lap_close", a.currentClipName)
        assertNull(a.snapshot().badge)
        a.step() // lap_close is 7 ticks
        assertEquals("alert", a.currentClipName)
        val popped = a.snapshot().badge
        assertNotNull(popped)
        a.step()
        a.step() // badge settled, clock 9 is off the hop beat
        val resting = a.snapshot().badge
        assertNotNull(resting)
        assertEquals(resting.y - 1, popped.y)
        assertEquals(-7, resting.y)
    }

    @Test
    fun interruptedExitStillShowsBadge() {
        // the exit is cancelled (e.g. another Critter is dragged and this one starts following)
        val a = makeActor()
        a.enterState(PetState.running, quiet = true)
        a.enterState(PetState.waiting)
        repeat(3) { a.step() }
        assertEquals("lap_close", a.currentClipName)
        a.cancelOnce()
        assertTrue(a.badgeVisible)
        assertEquals("ask", a.currentClipName) // the entrance is skipped, the loop goes on
        assertEquals(-8, a.snapshot().badge?.y) // just appeared: hopping
        repeat(30) {
            a.step()
            assertNotEquals("alert", a.currentClipName)
            assertNotNull(a.snapshot().badge)
        }

        // the exit is replaced by a layout hop: the badge shows once it lands
        val b = makeActor()
        b.enterState(PetState.running, quiet = true)
        b.enterState(PetState.waiting)
        b.step()
        b.travel(fromDx = 20, fromDy = 0, delay = 0)
        assertTrue(b.badgeVisible)
        stepUntilLoop(b)
        assertNotNull(b.snapshot().badge)

        // a newer state still drops the stale exit entirely
        val c = makeActor()
        c.enterState(PetState.running, quiet = true)
        c.enterState(PetState.waiting)
        c.enterState(PetState.done, quiet = true)
        c.cancelOnce()
        assertNull(c.snapshot().badge)
    }

    @Test
    fun staleEnterIsDropped() {
        val a = makeActor()
        a.enterState(PetState.running, quiet = true)
        a.enterState(PetState.waiting) // lap_close playing
        a.enterState(PetState.done) // immediately done
        assertEquals("celebrate", a.currentClipName)
        val seen = mutableSetOf<String>()
        repeat(30) {
            a.step()
            seen += a.currentClipName ?: ""
        }
        assertFalse("alert" in seen)
        assertEquals("content", a.currentClipName)
        repeat(300) {
            a.step()
            seen += a.currentClipName ?: ""
        }
        assertFalse("alert" in seen)
    }

    @Test
    fun doneToIdlePlaysSeen() {
        val a = makeActor()
        a.enterState(PetState.done, quiet = true)
        a.enterState(PetState.idle)
        assertEquals("seen", a.currentClipName)
        assertEquals(Tint.dim, a.tint)
        assertEquals(5, stepUntilLoop(a))
        assertEquals("idle", a.currentClipName)
    }

    @Test
    fun enterWithoutEnterClipCancelsOnce() {
        val a = makeActor()
        a.enterState(PetState.waiting, quiet = true)
        var ok: Boolean? = null
        a.play("blink") { ok = it }
        a.enterState(PetState.idle)
        assertEquals(false, ok)
        assertFalse(a.isPlayingOnce)
        assertEquals("idle", a.currentClipName)
    }

    @Test
    fun fallsAsleepAfter2000TicksAndWakes() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        repeat(1999) { a.step() }
        assertFalse(a.asleep)
        a.step()
        assertTrue(a.asleep)
        assertEquals("sleep", a.stateLoopName())
        assertEquals("doze", a.currentClipName)
        assertNull(a.snapshot().accessory)
        assertTrue(stepUntilLoop(a) > 0)
        assertEquals("sleep", a.currentClipName)
        repeat(300) { // no fidgets while asleep
            a.step()
            assertEquals("sleep", a.currentClipName)
        }
        a.wake()
        assertFalse(a.asleep)
        assertEquals("wake", a.currentClipName)
        assertEquals("idle", a.stateLoopName())
        stepUntilLoop(a)
        assertEquals("idle", a.currentClipName)
    }

    @Test
    fun waitingTurnsImpatientAt500() {
        val a = makeActor()
        a.enterState(PetState.waiting, quiet = true)
        repeat(480) { a.step() }
        repeat(499 - 480) { // the "!" hops 2 ticks in every 20
            a.step()
            assertEquals(if (a.clock % 20 < 2) -8 else -7, a.snapshot().badge?.y)
        }
        assertEquals("ask", a.stateLoopName())
        a.step()
        assertEquals("impatient", a.stateLoopName())
        assertEquals("impatient", a.currentClipName)
        repeat(24) { // now 2 in every 8
            a.step()
            assertEquals(if (a.clock % 8 < 2) -8 else -7, a.snapshot().badge?.y)
        }
    }

    @Test
    fun fidgetPlaysAPickAndReschedules() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        val fidget = a.skin.state(PetState.idle).fidget!!
        val picks = fidget.pick.map { it.clip }.toSet()
        assertTrue(a.fidgetIn in 40..90)
        repeat(5) {
            val n = a.fidgetIn
            repeat(n - 1) { a.step() }
            assertFalse(a.isPlayingOnce)
            a.step()
            assertTrue(a.isPlayingOnce)
            assertTrue((a.currentClipName ?: "") in picks)
            assertTrue(a.fidgetIn in 60..160)
            stepUntilLoop(a)
        }
    }

    @Test
    fun noFidgetDuringMode() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        a.setMode("pet")
        val fidgetIn = a.fidgetIn
        repeat(300) { a.step() }
        assertEquals(fidgetIn, a.fidgetIn)
        assertEquals(0, a.idleTicks)
        assertFalse(a.isPlayingOnce)
        assertEquals("pet", a.currentClipName)
    }

    @Test
    fun hiddenCritterHoldsItsFidgetButKeepsItsOtherTimers() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        a.hidden = true
        val fidgetIn = a.fidgetIn
        repeat(300) { a.step() }
        assertFalse(a.isPlayingOnce) // no invisible fidgets waking the clock
        assertEquals(fidgetIn, a.fidgetIn)
        assertEquals(300, a.idleTicks) // still on its way to sleep
        assertEquals(2000 - 300, a.brainTicksLeft()) // only the way to sleep counts, not the fidget
        a.hidden = false
        repeat(fidgetIn) { a.step() }
        assertTrue(a.isPlayingOnce) // shown again: the countdown carries on
    }

    // MARK: - Work variants

    @Test
    fun activityDebounce() {
        val a = makeActor()
        a.enterState(PetState.running, quiet = true)
        a.fidgetIn = 10_000
        a.setActivity("think")
        repeat(39) {
            a.step()
            assertEquals("laptop", a.variant)
            assertEquals("laptop", a.currentClipName)
        }
        a.step()
        assertEquals("think", a.variant)
        assertEquals("lap_close", a.currentClipName)
        stepUntilLoop(a)
        assertEquals("think", a.currentClipName)
        assertEquals("think", a.stateLoopName())
    }

    @Test
    fun switchToVariantWithEnterPlaysIt() {
        val a = makeActor()
        a.setActivity("read")
        a.enterState(PetState.running, quiet = true)
        a.fidgetIn = 10_000
        a.setActivity("laptop")
        repeat(40) { a.step() }
        assertEquals("laptop", a.variant)
        assertEquals("lap_open", a.currentClipName) // read has no exit; laptop's own enter
        stepUntilLoop(a)
        assertEquals("laptop", a.currentClipName)
    }

    @Test
    fun briefActivityFlickerIgnored() {
        val a = makeActor()
        a.enterState(PetState.running, quiet = true)
        a.fidgetIn = 10_000
        a.setActivity("think")
        repeat(10) { a.step() }
        a.setActivity("laptop")
        repeat(300) {
            a.step()
            assertNotEquals("lap_close", a.currentClipName)
        }
        assertEquals("laptop", a.variant)
    }

    @Test
    fun runningEntryUsesDesiredVariant() {
        val a = makeActor()
        a.setActivity("read")
        assertEquals("laptop", a.variant) // only remembered outside running
        a.enterState(PetState.running)
        assertEquals("read", a.variant)
        assertEquals("work_enter", a.currentClipName)
        assertEquals("read", a.stateLoopName())
        stepUntilLoop(a)
        assertEquals("read", a.currentClipName)
    }

    @Test
    fun unknownActivityMeansDefaultVariant() {
        val a = makeActor()
        a.setActivity("juggle")
        a.setActivity("no_such_tool")
        a.enterState(PetState.running, quiet = true)
        assertEquals("laptop", a.variant)
        a.setActivity("bash")
        a.setActivity(null)
        repeat(100) { a.step() }
        assertEquals("laptop", a.variant)
    }

    // MARK: - Head markers and props

    @Test
    fun spinnerFollowsCosine() {
        val a = makeActor()
        a.enterState(PetState.running, quiet = true)
        val frames = mutableMapOf<Int, GlyphDraw?>()
        while (a.clock <= 33) {
            frames[a.clock] = a.snapshot().accessory
            a.step()
        }
        assertEquals(
            listOf("s0", "s1", "s3", "s5", "s3", "s0"),
            listOf(0, 5, 10, 17, 25, 33).map { frames[it]?.glyph },
        )
        assertEquals(7, frames[17]?.x)
        assertEquals(-7, frames[17]?.y)
        assertEquals(9, frames[0]?.x) // s0 is 1×1: centred in the 5-row box
        assertEquals(-5, frames[0]?.y)
        assertEquals("#D97757", frames[17]?.color)
    }

    @Test
    fun accessoryHiddenWhenAsleepHeldOrMerged() {
        val a = makeActor()
        a.enterState(PetState.waiting, quiet = true)
        assertTrue(a.snapshot().accessory != null && a.snapshot().badge != null)
        a.setMode("held")
        assertTrue(a.snapshot().accessory == null && a.snapshot().badge == null)
        a.setMode(null)
        a.noAccessory = true
        assertTrue(a.snapshot().accessory == null && a.snapshot().badge == null)
        a.noAccessory = false
        a.hidden = true
        assertTrue(a.snapshot().accessory == null && a.snapshot().badge == null)
        a.hidden = false
        assertTrue(a.snapshot().accessory != null && a.snapshot().badge != null)

        val skin = builtin().withState("idle") { it.copy(accessory = "q", sleep = it.sleep!!.copy(after = 5)) }
        val b = makeActor(skin)
        b.enterState(PetState.idle, quiet = true)
        assertNotNull(b.snapshot().accessory)
        repeat(5) { b.step() }
        assertTrue(b.asleep)
        assertNull(b.snapshot().accessory)
    }

    @Test
    fun markersHiddenWhenKeyIsDeepOrHigh() {
        val a = makeActor()
        a.enterState(PetState.error, quiet = true)
        fun accessory(dy: Int): GlyphDraw? {
            a.play(listOf(ClipKey(pose = "base", ticks = 3, dx = 2, dy = dy)), null)
            return a.snapshot().accessory
        }
        assertNull(accessory(-6))
        assertNull(accessory(7))
        assertNotNull(accessory(-5))
        assertNotNull(accessory(6))
        // the marker ignores the body's dx and dy, but moves with lag and lift
        a.lag = 2
        a.lift = 1
        assertEquals(GlyphDraw(glyph = "bang", color = "#FF3B30", x = 8 + 2, y = -7 - 1, alpha = 1.0), accessory(3))
    }

    @Test
    fun checkTwinklesEvery43Ticks() {
        val a = makeActor()
        a.enterState(PetState.done, quiet = true)
        a.fidgetIn = 10_000
        assertEquals("check", a.snapshot().accessory?.glyph)
        repeat(42) { a.step() }
        assertTrue(a.particles.isEmpty())
        a.step()
        assertEquals(43, a.clock)
        assertEquals(listOf("spark"), a.particles.map { it.glyph })
        assertEquals(14, a.snapshot().particles.firstOrNull()?.x)
        assertEquals(-9, a.snapshot().particles.firstOrNull()?.y)
        a.noAccessory = true
        repeat(43) { a.step() }
        assertTrue(a.particles.isEmpty())
    }

    @Test
    fun qBobsEvery7Ticks() {
        val a = makeActor()
        a.enterState(PetState.waiting, quiet = true)
        repeat(28) {
            assertEquals(if ((a.clock / 7) % 2 == 1) -9 else -8, a.snapshot().accessory?.y)
            assertEquals(7, a.snapshot().accessory?.x)
            a.step()
        }
    }

    @Test
    fun juggleBallsFollowFormula() {
        val a = makeActor()
        a.setActivity("juggle")
        a.enterState(PetState.running, quiet = true)
        assertEquals(
            listOf(
                GlyphDraw(glyph = "ball", color = "#D97757", x = 3, y = -2, alpha = 1.0),
                GlyphDraw(glyph = "ball", color = "#F0A487", x = 7, y = -8, alpha = 1.0),
                GlyphDraw(glyph = "ball", color = "#D97757", x = 10, y = -8, alpha = 1.0),
            ),
            a.snapshot().props,
        )
        a.lag = 1
        a.lift = 2
        assertEquals(4, a.snapshot().props[0].x)
        assertEquals(-4, a.snapshot().props[0].y)
        a.play("blink") // only while the variant's loop plays
        assertTrue(a.snapshot().props.isEmpty())
    }

    // MARK: - Reduced motion

    @Test
    fun reduceMotionShowsStills() {
        val skin = builtin()
        val a = makeActor(reduceMotion = true)
        for (s in SKIN_STATES) {
            a.enterState(s, quiet = true)
            assertEquals(skin.state(s).still, a.snapshot().pose)
        }
        a.enterState(PetState.error, quiet = true)
        assertEquals("slump", a.snapshot().pose)
        assertEquals(-1, a.snapshot().bodyY)
        a.lift = 2
        assertEquals(1, a.snapshot().bodyY)
        a.lift = 0

        a.enterState(PetState.running, quiet = true)
        assertEquals("dotbig", a.snapshot().accessory?.glyph)
        assertEquals("lap_a", a.snapshot().pose)
        assertEquals(0, a.snapshot().bodyX)
        a.setMode("held")
        assertEquals("held_a", a.snapshot().pose)
        a.setMode(null)

        a.enterState(PetState.waiting) // badge at once, and it never hops
        assertTrue(a.badgeVisible)
        repeat(25) {
            assertEquals(-7, a.snapshot().badge?.y)
            assertEquals(-8, a.snapshot().accessory?.y)
            a.step()
        }

        a.enterState(PetState.done)
        assertFalse(a.isPlayingOnce) // no entrance under reduced motion
        repeat(60) {
            a.step()
            assertTrue(a.particles.isEmpty())
        }

        a.enterState(PetState.idle)
        repeat(2000) { a.step() }
        assertTrue(a.asleep)
        assertEquals("shut", a.snapshot().pose)
    }

    @Test
    fun reduceMotionSwitchesVariantWithoutExit() {
        val a = makeActor(reduceMotion = true)
        a.enterState(PetState.running, quiet = true)
        a.setActivity("think")
        repeat(40) { a.step() }
        assertEquals("think", a.variant)
        assertFalse(a.isPlayingOnce)
        assertEquals("think", a.currentClipName)
    }

    // MARK: - ticksUntilChange

    @Test
    fun ticksUntilChangeCountsBrainAndAccessories() {
        val long = listOf(ClipKey(pose = "base", ticks = 1000))

        // fidget countdown
        val idle = makeActor()
        idle.enterState(PetState.idle, quiet = true)
        idle.fidgetIn = 5
        assertEquals(5, idle.ticksUntilChange())
        // falling asleep
        idle.fidgetIn = 10_000
        idle.idleTicks = 1995
        assertEquals(5, idle.ticksUntilChange())

        // spinner frame (think's first key is 10 ticks; s0 → s1 at clock 4)
        val spin = makeActor()
        spin.setActivity("think")
        spin.enterState(PetState.running, quiet = true)
        spin.fidgetIn = 10_000
        assertEquals(4, spin.ticksUntilChange())

        // waiting: badge hop ends at clock 2, then the q bob at 7, then impatience
        val wait = makeActor()
        wait.enterState(PetState.waiting, quiet = true)
        wait.setLoop(long, null)
        assertEquals(2, wait.ticksUntilChange())
        wait.step()
        wait.step()
        assertEquals(5, wait.ticksUntilChange())
        wait.noAccessory = true
        wait.waitTicks = 497
        assertEquals(3, wait.ticksUntilChange())

        // check twinkle
        val done = makeActor()
        done.enterState(PetState.done, quiet = true)
        done.setLoop(long, null)
        done.fidgetIn = 10_000
        assertEquals(43, done.ticksUntilChange())

        // juggled balls move every tick
        val juggle = makeActor()
        juggle.setActivity("juggle")
        juggle.enterState(PetState.running, quiet = true)
        assertEquals(1, juggle.ticksUntilChange())

        // variant debounce
        val run = makeActor()
        run.enterState(PetState.running, quiet = true)
        run.noAccessory = true
        run.fidgetIn = 10_000
        run.setLoop(long, null)
        run.setActivity("think")
        assertEquals(40, run.ticksUntilChange())
        repeat(25) { run.step() }
        assertEquals(15, run.ticksUntilChange())

        // nothing counts down while the brain is off
        val off = makeActor()
        off.enterState(PetState.idle, quiet = true)
        off.brainEnabled = false
        off.setLoop(long, null)
        assertEquals(1000, off.ticksUntilChange())
    }
}
