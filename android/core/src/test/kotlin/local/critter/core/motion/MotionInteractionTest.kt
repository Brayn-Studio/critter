package local.critter.core.motion

import local.critter.core.builtin
import local.critter.core.bundledSkin
import local.critter.core.protocol.PetState
import local.critter.core.skin.MotionClip
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

private fun stepUntilLoop(a: MotionActor, limit: Int = 500): Int {
    var n = 0
    while (a.isPlayingOnce && n < limit) { a.step(); n += 1 }
    return n
}

private fun rows(k: MotionClip): List<List<String>> =
    k.map { listOf(it.pose, "${it.ticks}", "${it.dx}", "${it.dy}", it.effect ?: "") }

private fun stepWhileTraveling(a: MotionActor, limit: Int = 200) {
    var n = 0
    while (a.traveling && n < limit) { a.step(); n += 1 }
}

class MotionInteractionTest {
    // MARK: - Travel

    @Test
    fun travelKeysMatchPreview() {
        val names = builtin().interactions
        val k = MotionTravel.keys(fromDx = 30, fromDy = 0, toDy = 0, delay = 2, hopLength = 14, names = names)
        assertEquals(
            listOf(
                listOf("base", "2", "30", "0", ""), listOf("air", "1", "28", "2", ""), listOf("air", "1", "25", "3", ""), listOf("air", "1", "23", "2", ""), listOf("base", "1", "20", "0", ""),
                listOf("air", "1", "17", "2", ""), listOf("air", "1", "15", "3", ""), listOf("air", "1", "12", "2", ""), listOf("base", "1", "10", "0", ""),
                listOf("air", "1", "8", "2", ""), listOf("air", "1", "5", "3", ""), listOf("air", "1", "3", "2", ""), listOf("base", "1", "0", "0", ""),
                listOf("base", "2", "0", "-2", "dust_small"), listOf("base", "1", "0", "0", ""), listOf("shut", "1", "0", "0", ""),
            ),
            rows(k),
        )
    }

    @Test
    fun seatKeysEndRaised() {
        val names = builtin().interactions
        val k = MotionTravel.keys(fromDx = -20, fromDy = 0, toDy = 2, delay = 0, hopLength = 14, names = names)
        assertEquals(
            listOf(
                listOf("air", "1", "-17", "2", ""), listOf("air", "1", "-15", "4", ""), listOf("air", "1", "-12", "3", ""), listOf("base", "1", "-10", "1", ""),
                listOf("air", "1", "-7", "3", ""), listOf("air", "1", "-5", "5", ""), listOf("air", "1", "-2", "4", ""), listOf("base", "1", "0", "2", ""),
                listOf("base", "1", "0", "1", "dust_small"), listOf("base", "1", "0", "2", "@seat"),
            ),
            rows(k),
        )
    }

    @Test
    fun travelCompletesAndClearsTraveling() {
        val a = makeActor()
        a.enterState(PetState.waiting, quiet = true)
        var ok: Boolean? = null
        a.travel(fromDx = 30, fromDy = 0, delay = 2) { ok = it }
        assertTrue(a.traveling)
        assertEquals(30, a.snapshot().bodyX)
        assertNull(a.snapshot().accessory)
        assertNull(a.snapshot().badge)
        assertEquals(18, stepUntilLoop(a))
        assertEquals(true, ok)
        assertFalse(a.traveling)
        assertEquals("ask", a.currentClipName)
        assertNotNull(a.snapshot().accessory)
        assertNotNull(a.snapshot().badge)
    }

    @Test
    fun travelInterruptedCompletesFalse() {
        val a = makeActor()
        var ok: Boolean? = null
        a.travel(fromDx = 30, fromDy = 0, delay = 0) { ok = it }
        a.step()
        a.play("blink")
        assertEquals(false, ok)
        assertFalse(a.traveling)
        // a new travel that replaces one in flight stays traveling
        var first: Boolean? = null
        var second: Boolean? = null
        a.travel(fromDx = 10, fromDy = 0, delay = 0) { first = it }
        a.travel(fromDx = 20, fromDy = 0, delay = 0) { second = it }
        assertEquals(false, first)
        assertNull(second)
        assertTrue(a.traveling)
    }

    @Test
    fun travelReplacedFromACompletionLeavesNoStrayFlags() {
        // travel 1's completion starts another clip while travel 2 is replacing it
        val a = makeActor()
        a.enterState(PetState.done, quiet = true)
        var first: Boolean? = null
        var second: Boolean? = null
        a.travel(fromDx = 30, fromDy = 0, delay = 0) { ok ->
            first = ok
            a.play("blink")
        }
        a.step()
        a.travel(fromDx = -20, fromDy = 0, delay = 0, seat = PileSeating.seat(row = 2)) { second = it }
        assertEquals(false, first)
        assertEquals(false, second)
        assertFalse(a.traveling)
        assertEquals("blink", a.currentClipName)
        assertNull(a.travelSeat)
        a.reduceMotion = true // must not seat it or end the blink
        assertTrue(a.tint == null && a.alpha == 1.0 && a.z == 2)
        assertEquals("blink", a.currentClipName)

        // ...or cancels the one-shot
        val b = makeActor()
        var cancelled: Boolean? = null
        b.travel(fromDx = 30, fromDy = 0, delay = 0) { b.cancelOnce() }
        b.travel(fromDx = 10, fromDy = 0, delay = 0) { cancelled = it }
        assertEquals(false, cancelled)
        assertFalse(b.traveling)
        assertFalse(b.isPlayingOnce)
        assertEquals("idle", b.currentClipName)
    }

    @Test
    fun noBrainWhileTravelingOrFollowing() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        val fidgetIn = a.fidgetIn
        a.travel(fromDx = 30, fromDy = 0, delay = 0)
        repeat(5) { a.step() }
        assertTrue(a.traveling)
        assertEquals(fidgetIn, a.fidgetIn)
        assertEquals(0, a.idleTicks)
        stepUntilLoop(a)
        a.startFollow(lookLeft = true)
        repeat(300) { a.step() }
        assertTrue(a.following)
        assertEquals(fidgetIn, a.fidgetIn)
        assertEquals(0, a.idleTicks)
        assertFalse(a.isPlayingOnce)

        val r = makeActor()
        r.enterState(PetState.running, quiet = true)
        r.setActivity("think")
        r.startFollow(lookLeft = false)
        repeat(100) { r.step() }
        assertEquals("laptop", r.variant)
    }

    @Test
    fun seatAppliesDimAlphaZAtLastKey() {
        val a = makeActor()
        a.enterState(PetState.done, quiet = true)
        a.fidgetIn = 10_000
        var ok: Boolean? = null
        a.travel(fromDx = -20, fromDy = 0, delay = 0, seat = PileSeating.seat(row = 2)) { ok = it }
        repeat(8) { a.step() }
        assertTrue(a.tint == null && a.alpha == 1.0 && a.z == 2)
        a.step() // the last key starts
        assertEquals(Tint.dim, a.tint)
        assertEquals(0.55, a.alpha)
        assertEquals(0, a.z)
        assertTrue(a.traveling)
        a.step()
        assertEquals(true, ok)
        assertFalse(a.traveling)
        repeat(50) { a.step() }
        assertEquals(2, a.snapshot().bodyY)
        assertEquals("base", a.snapshot().pose)
        assertEquals(Tint.dim, a.tint)
    }

    @Test
    fun unseatRestoresStateLook() {
        val a = makeActor()
        a.enterState(PetState.waiting, quiet = true)
        a.noAccessory = true
        a.travel(fromDx = -20, fromDy = 0, delay = 0, seat = PileSeating.seat(row = 1))
        stepUntilLoop(a)
        assertTrue(a.tint == Tint.dim && a.alpha == 0.75 && a.z == 1)
        assertEquals(1, a.snapshot().bodyY)
        a.unseat()
        assertNull(a.tint)
        assertEquals(1.0, a.alpha)
        assertEquals(2, a.z)
        assertFalse(a.noAccessory)
        assertEquals("ask", a.currentClipName)
        assertEquals(0, a.snapshot().bodyY)

        val idle = makeActor()
        idle.enterState(PetState.idle, quiet = true)
        idle.travel(fromDx = 8, fromDy = 0, delay = 0, seat = PileSeating.seat(row = 2))
        stepUntilLoop(idle)
        idle.unseat()
        assertEquals(Tint.dim, idle.tint) // idle's own tint
        assertEquals(1.0, idle.alpha)
    }

    @Test
    fun travelUnderReduceMotionCompletesImmediately() {
        val a = makeActor(reduceMotion = true)
        a.enterState(PetState.waiting, quiet = true)
        var ok: Boolean? = null
        a.travel(fromDx = 30, fromDy = 0, delay = 2, seat = PileSeating.seat(row = 1)) { ok = it }
        assertEquals(true, ok)
        assertFalse(a.traveling)
        assertFalse(a.isPlayingOnce)
        assertTrue(a.tint == Tint.dim && a.alpha == 0.75 && a.z == 1)

        var plain: Boolean? = null
        a.travel(fromDx = -12, fromDy = 0, delay = 0) { plain = it }
        assertEquals(true, plain)
        assertFalse(a.traveling)
    }

    @Test
    fun enablingReduceMotionFinishesTravel() {
        val a = makeActor()
        a.enterState(PetState.done, quiet = true)
        var ok: Boolean? = null
        a.travel(fromDx = -20, fromDy = 0, delay = 4, seat = PileSeating.seat(row = 2)) { ok = it }
        a.emit("dust")
        repeat(3) { a.step() }
        assertTrue(a.traveling)
        assertNull(ok)
        a.reduceMotion = true
        assertEquals(true, ok)
        assertFalse(a.traveling)
        assertFalse(a.isPlayingOnce)
        assertTrue(a.tint == Tint.dim && a.alpha == 0.55 && a.z == 0)
        assertTrue(a.particles.isEmpty())

        val b = makeActor()
        var plain: Boolean? = null
        b.travel(fromDx = 30, fromDy = 0, delay = 0) { plain = it }
        b.step()
        b.reduceMotion = true
        assertEquals(true, plain)
        assertFalse(b.traveling)
        assertEquals(Tint.dim, b.tint) // idle's own tint, untouched
        assertEquals(1.0, b.alpha)
    }

    // MARK: - Follow

    @Test
    fun followWalksThenJogs() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        a.startFollow(lookLeft = false)
        assertTrue(a.following)
        a.followShift(dx = 10.0, dy = 0.0)
        var s = a.snapshot()
        assertEquals(-10, s.offsetX)
        assertEquals("walk_r_b", s.pose) // trotting at clock 0
        val xs = mutableListOf<Int>()
        val poses = mutableListOf<String>()
        repeat(9) {
            a.step()
            s = a.snapshot()
            xs += s.offsetX
            poses += s.pose
            assertTrue(s.bodyX == 0 && s.bodyY == 0 && s.offsetY == 0)
        }
        assertEquals(listOf(-8, -6, -5, -4, -3, -2, -1, 0, 0), xs)
        // trotting (|offset| > 6) swaps legs every tick, walking every 2 ticks
        assertEquals(listOf("walk_r_a", "walk_r_a", "walk_r_a", "walk_r_b", "walk_r_b", "walk_r_a", "walk_r_a", "look_r", "look_r"), poses)
        assertTrue(a.following) // still held: keeps following

        val b = makeActor()
        b.startFollow(lookLeft = true)
        b.followShift(dx = -3.0, dy = 0.0)
        assertEquals(3, b.snapshot().offsetX)
        assertTrue(b.snapshot().pose.startsWith("walk_l_"))
    }

    @Test
    fun followCapsAt12And8() {
        val a = makeActor()
        a.startFollow(lookLeft = true)
        a.followShift(dx = 30.0, dy = -20.0)
        assertEquals(-12, a.snapshot().offsetX)
        assertEquals(8, a.snapshot().offsetY)
        a.followShift(dx = -50.0, dy = 50.0)
        assertEquals(12, a.snapshot().offsetX)
        assertEquals(-8, a.snapshot().offsetY)
    }

    @Test
    fun verticalCatchUpHopsAndLandsWithDust() {
        val a = makeActor()
        a.startFollow(lookLeft = true)
        a.followShift(dx = 0.0, dy = 3.0) // the window went up 3 cells
        assertEquals(-3, a.snapshot().offsetY)
        assertEquals("air", a.snapshot().pose)
        a.step()
        a.step()
        assertEquals(-1, a.snapshot().offsetY)
        assertEquals("air", a.snapshot().pose)
        assertTrue(a.particles.isEmpty())
        a.step()
        assertEquals(0, a.snapshot().offsetY)
        assertEquals("look_l", a.snapshot().pose)
        assertEquals(2, a.particles.size) // dust_small on landing
    }

    @Test
    fun followEndsAfterReleaseAndBlinks() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        a.startFollow(lookLeft = true)
        a.followShift(dx = 3.0, dy = 0.0)
        repeat(5) { a.step() }
        assertTrue(a.following) // caught up but still held
        assertFalse(a.isPlayingOnce)
        a.releaseFollow()
        a.step()
        assertFalse(a.following)
        assertEquals("blink", a.currentClipName)

        val b = makeActor()
        b.startFollow(lookLeft = true)
        b.followShift(dx = 3.0, dy = 0.0)
        b.releaseFollow()
        b.step()
        b.step()
        assertTrue(b.following)
        b.step() // caught up on this tick
        assertFalse(b.following)
        assertEquals("blink", b.currentClipName)
    }

    @Test
    fun reduceMotionFollowStaysPut() {
        val a = makeActor()
        a.startFollow(lookLeft = true)
        a.followShift(dx = 10.0, dy = 4.0)
        a.reduceMotion = true
        assertTrue(a.snapshot().offsetX == 0 && a.snapshot().offsetY == 0)
        a.followShift(dx = 10.0, dy = 4.0)
        assertTrue(a.snapshot().offsetX == 0 && a.snapshot().offsetY == 0)
        assertEquals("base", a.snapshot().pose) // idle's still, not a walk
        a.releaseFollow()
        a.step()
        assertFalse(a.following)
        assertFalse(a.isPlayingOnce) // no blink under reduced motion
    }

    @Test
    fun followIgnoredWhileTraveling() {
        val a = makeActor()
        a.travel(fromDx = 30, fromDy = 0, delay = 0)
        a.startFollow(lookLeft = true)
        assertFalse(a.following)
        a.followShift(dx = 10.0, dy = 0.0)
        assertEquals(0, a.snapshot().offsetX)
        assertTrue(a.traveling)

        val h = makeActor()
        h.hidden = true
        h.startFollow(lookLeft = true)
        assertFalse(h.following)

        val c = makeActor()
        c.play("wink")
        c.startFollow(lookLeft = true) // a follower drops what it was doing
        assertTrue(c.following)
        assertFalse(c.isPlayingOnce)
    }

    @Test
    fun ticksUntilChangeWhileFollowing() {
        val a = makeActor()
        a.enterState(PetState.error, quiet = true) // slump: a 36-tick key, a still marker
        a.startFollow(lookLeft = true)
        assertEquals(36, a.ticksUntilChange()) // caught up and held: nothing moves
        a.followShift(dx = 2.0, dy = 0.0)
        assertEquals(1, a.ticksUntilChange())
        a.step()
        a.step()
        assertEquals(0, a.snapshot().offsetX)
        assertEquals(34, a.ticksUntilChange())
        a.releaseFollow()
        assertEquals(1, a.ticksUntilChange()) // ends (and blinks) on the next tick
    }

    @Test
    fun travelEndsAFollowOnTheSpot() {
        val a = makeActor()
        a.startFollow(lookLeft = true)
        a.followShift(dx = 5.0, dy = 2.0)
        assertTrue(a.followOffset.x == -5 && a.followOffset.y == -2)
        a.travel(fromDx = 20, fromDy = 0, delay = 0)
        assertFalse(a.following)
        assertTrue(a.traveling)
        assertTrue(a.followOffset.x == 0 && a.followOffset.y == 0)
        assertEquals("air", a.snapshot().pose) // the hop shows, not a walk
        a.releaseFollow()
        stepUntilLoop(a)
        assertFalse(a.following)
        assertNotEquals("blink", a.currentClipName) // no follow left to end with a blink
    }

    @Test
    fun followOffsetMatchesTheSnapshot() {
        val a = makeActor()
        a.startFollow(lookLeft = false)
        a.followShift(dx = 2.5, dy = -1.5)
        val s = a.snapshot()
        assertTrue(a.followOffset.x == s.offsetX && a.followOffset.y == s.offsetY)
        assertTrue(s.offsetX == -2 && s.offsetY == 2) // jsRound(-2.5) = -2, jsRound(1.5) = 2
    }

    @Test
    fun hopStartsWhereAFollowerIsDrawn() {
        val a = makeActor()
        a.startFollow(lookLeft = true)
        a.followShift(dx = 5.0, dy = -2.0) // drawn 5 cells left, 2 cells up
        val drawn = a.snapshot()
        assertTrue(drawn.offsetX == -5 && drawn.offsetY == 2)
        a.travel(fromDx = 20, fromDy = 0, delay = 2)
        val s = a.snapshot()
        assertTrue(s.offsetX == 0 && s.offsetY == 0)
        assertTrue(s.bodyX == 15 && s.bodyY == 2) // the same spot, now as the hop's start
    }

    // MARK: - Entrances cut short by a hop

    @Test
    fun hopReplaysTheEntranceItCutShort() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        a.enterState(PetState.done)
        assertEquals("celebrate", a.currentClipName)
        a.step()
        var landed: Boolean? = null
        a.travel(fromDx = 20, fromDy = 0, delay = 0) { landed = it }
        stepWhileTraveling(a)
        assertEquals(true, landed)
        assertEquals("celebrate", a.currentClipName) // the whole entrance, after the hop
        assertTrue(a.isPlayingOnce)
        stepUntilLoop(a)
        assertEquals("content", a.currentClipName)

        // running → done: the hop cuts the laptop's exit; the done entrance plays after it
        val r = makeActor()
        r.enterState(PetState.running, quiet = true)
        r.enterState(PetState.done)
        assertEquals("lap_close", r.currentClipName)
        r.travel(fromDx = -14, fromDy = 0, delay = 0)
        stepWhileTraveling(r)
        assertEquals("celebrate", r.currentClipName)
    }

    @Test
    fun hopReplaysTheWaitingAlertWithItsBadge() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        a.enterState(PetState.waiting)
        assertEquals("alert", a.currentClipName)
        a.travel(fromDx = 14, fromDy = 0, delay = 0)
        assertNull(a.snapshot().badge) // markers hide while hopping
        stepWhileTraveling(a)
        assertEquals("alert", a.currentClipName)
        assertTrue(a.badgeVisible)
        assertEquals(0, a.badgeAge) // the ! pops up again with the alert
    }

    @Test
    fun hopLeavesOtherOneShotsAndSeatsAlone() {
        // the entrance was already over: back to the loop
        val done = makeActor()
        done.enterState(PetState.idle, quiet = true)
        done.enterState(PetState.done)
        stepUntilLoop(done)
        done.travel(fromDx = 14, fromDy = 0, delay = 0)
        stepWhileTraveling(done)
        assertFalse(done.isPlayingOnce)

        // a fidget is not an entrance
        val idle = makeActor()
        idle.enterState(PetState.idle, quiet = true)
        idle.play("wink")
        idle.travel(fromDx = 14, fromDy = 0, delay = 0)
        stepWhileTraveling(idle)
        assertFalse(idle.isPlayingOnce)

        // a hop into a pile seat stays seated
        val seated = makeActor()
        seated.enterState(PetState.idle, quiet = true)
        seated.enterState(PetState.done)
        seated.travel(fromDx = 14, fromDy = 0, delay = 0, seat = PileSeating.seat(row = 1))
        stepWhileTraveling(seated)
        assertFalse(seated.isPlayingOnce)
        assertEquals(1, seated.snapshot().bodyY)

        // a new state during the hop plays its own entrance instead
        val changed = makeActor()
        changed.enterState(PetState.idle, quiet = true)
        changed.enterState(PetState.done)
        changed.travel(fromDx = 14, fromDy = 0, delay = 0)
        changed.step()
        changed.enterState(PetState.error)
        assertEquals("oops", changed.currentClipName)
        assertFalse(changed.traveling)
    }

    @Test
    fun reducedMotionDrawsNoSwing() {
        val held = makeActor(reduceMotion = true)
        held.setMode("held")
        held.lift = 3
        held.lag = -2
        var s = held.snapshot()
        assertEquals("held_a", s.pose)
        assertTrue(s.bodyX == 0 && s.bodyY == 3) // lifted, but not swung
        held.reduceMotion = false
        assertEquals(-2, held.snapshot().bodyX)

        val w = makeActor(reduceMotion = true)
        w.enterState(PetState.waiting, quiet = true)
        val still = w.snapshot()
        w.lag = 3
        w.particles = mutableListOf(Particle(glyph = "dot", color = "#B4BAC4", x = 4.0, y = 0.0, life = 10))
        s = w.snapshot()
        assertEquals(still.bodyX, s.bodyX)
        assertTrue(s.badge?.x == still.badge?.x && s.accessory?.x == still.accessory?.x)
        assertEquals(4, s.particles.firstOrNull()?.x)
    }

    // MARK: - Gaze

    @Test
    fun gazeZones() {
        val c = Pt(100.0, 100.0)
        fun zone(x: Double, y: Double): GazeZone? = MotionGaze.zone(pointer = Pt(x, y), center = c, unit = 3.0)
        assertNull(zone(300.0, 100.0)) // 200 pt away
        assertEquals(GazeZone.up, zone(100.0, 140.0)) // 40 above
        assertEquals(GazeZone.left, zone(70.0, 100.0)) // 30 left
        assertEquals(GazeZone.right, zone(130.0, 100.0)) // 30 right
        assertEquals(GazeZone.down, zone(100.0, 80.0)) // 20 below
        assertEquals(GazeZone.center, zone(105.0, 100.0))
        assertEquals(GazeZone.center, zone(100.0, 95.0)) // only 5 below
        assertEquals(GazeZone.center, zone(100.0, 120.0)) // 20 above is not above enough
        assertEquals(GazeZone.right, zone(150.0, 140.0)) // above, but more sideways than up
    }

    @Test
    fun gazeOnlyWhenCalm() {
        val w = makeActor()
        w.enterState(PetState.waiting, quiet = true)
        w.setGaze(GazeZone.left)
        assertEquals("raise", w.snapshot().pose)

        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        a.setGaze(GazeZone.left)
        assertEquals("look_l", a.snapshot().pose)
        a.setGaze(GazeZone.up)
        assertEquals("look_up", a.snapshot().pose)
        a.play("blink")
        assertEquals("shut", a.snapshot().pose) // no gaze over a one-shot
        a.cancelOnce()
        a.setMode("pet")
        assertEquals("happy_l", a.snapshot().pose) // nor over a mode
        a.setMode(null)
        a.setGaze(null)
        assertEquals("base", a.snapshot().pose)

        val d = makeActor()
        d.enterState(PetState.done, quiet = true)
        d.setGaze(GazeZone.right)
        assertEquals("bloom_r", d.snapshot().pose) // done's own gaze poses keep the flower open

        val r = makeActor(reduceMotion = true)
        r.enterState(PetState.idle, quiet = true)
        r.setGaze(GazeZone.down)
        assertEquals("look_down", r.snapshot().pose)
    }

    @Test
    fun stateGazePosesReplaceTheLookPoses() {
        // Sprig's done state keeps its flower on while it looks around.
        val a = makeActor(bundledSkin("sprig"))
        a.enterState(PetState.done, quiet = true)
        a.setGaze(GazeZone.right)
        assertEquals("bloom_r", a.snapshot().pose)
        a.setGaze(GazeZone.center)
        assertEquals("bloom_open", a.snapshot().pose)
        // The zone outlasts the state: idle has no gaze of its own, so the plain look poses.
        a.setGaze(GazeZone.right)
        a.enterState(PetState.idle, quiet = true)
        assertEquals("look_r", a.snapshot().pose)
    }

    // MARK: - Rubbing

    @Test
    fun rubNeedsThreeReversalsInOneSecond() {
        val r = RubDetector()
        // x positions at 0.1 s steps: right, left (1), right (2), left (3)
        val rubbing = listOf(0.0, 5.0, 0.0, 5.0, 0.0).mapIndexed { i, x -> r.move(x = x, at = 0.1 * i) }
        assertEquals(listOf(false, false, false, false, true), rubbing)

        val slow = RubDetector()
        val slowRubbing = listOf(0.0 to 0.0, 5.0 to 0.1, 0.0 to 0.6, 5.0 to 1.2, 0.0 to 1.8).map { (x, t) -> slow.move(x = x, at = t) }
        assertEquals(listOf(false, false, false, false, false), slowRubbing) // the first reversal is over a second old
    }

    @Test
    fun rubIgnoresSmallMovesAndEndsAfter700ms() {
        val r = RubDetector()
        val jitter = (0..10).map { i -> r.move(x = if (i % 2 == 0) 0.0 else 2.0, at = 0.05 * i) }
        assertFalse(jitter.contains(true))
        assertFalse(r.shouldEnd(at = 2.0)) // nothing counted yet

        for ((i, x) in listOf(5.0, 0.0, 5.0, 0.0).withIndex()) r.move(x = x, at = 1 + 0.1 * i)
        val smallMove = r.move(x = 1.0, at = 1.35)
        assertTrue(smallMove) // still rubbing
        assertFalse(r.shouldEnd(at = 1.95)) // last counted move at 1.3
        assertTrue(r.shouldEnd(at = 2.01))
        r.reset()
        assertFalse(r.shouldEnd(at = 5.0))
        val afterReset = r.move(x = 40.0, at = 5.0)
        assertFalse(afterReset)
    }

    // MARK: - Hover and held swing

    @Test
    fun hoverAreaCoversTheBodyColumnsAndAFewPointsBelowTheGround() {
        val o = Pt(100.0, 50.0)
        fun on(x: Double, y: Double, offset: Pair<Int, Int> = 0 to 0, pile: Boolean = false): Boolean =
            MotionHover.contains(pointer = Pt(x, y), anchor = o, unit = 3.0, offset = offset, pile = pile)
        assertTrue(on(103.0, 50.0)) // column 1, on the ground
        assertFalse(on(102.9, 50.0))
        assertTrue(on(151.0, 50.0)) // column 17
        assertFalse(on(151.1, 50.0))
        assertTrue(on(120.0, 48.0)) // 2 pt below the ground
        assertFalse(on(120.0, 47.9))
        assertTrue(on(120.0, 83.0)) // 11 cells up
        assertFalse(on(120.0, 83.1))
        // following 4 cells left and 2 down: the area goes along
        assertTrue(on(145.0, 50.0))
        assertFalse(on(145.0, 50.0, offset = -4 to -2))
        assertTrue(on(91.0, 44.0, offset = -4 to -2))
        assertFalse(on(91.0, 41.9, offset = -4 to -2))
        // the merged pile reaches 1 cell left, 27 right, 13 up
        assertTrue(on(97.0, 50.0, pile = true))
        assertFalse(on(96.9, 50.0, pile = true))
        assertTrue(on(181.0, 89.0, pile = true))
        assertFalse(on(181.1, 50.0, pile = true))
        assertFalse(on(120.0, 89.1, pile = true))
    }

    @Test
    fun heldSwingTrailsThePointerAndSettles() {
        assertEquals(0, MotionDrag.lag(pointerDx = 0.0))
        assertEquals(-1, MotionDrag.lag(pointerDx = 3.0))
        assertEquals(-1, MotionDrag.lag(pointerDx = 4.5)) // -1.5 rounds up to -1
        assertEquals(2, MotionDrag.lag(pointerDx = -4.5)) // 1.5 rounds up to 2
        assertEquals(-2, MotionDrag.lag(pointerDx = 7.5)) // -2.5 → -2 (Math.round)
        assertEquals(-3, MotionDrag.lag(pointerDx = 40.0))
        assertEquals(3, MotionDrag.lag(pointerDx = -40.0))
        assertEquals(2, MotionDrag.settle(3))
        assertEquals(-1, MotionDrag.settle(-2))
        assertEquals(0, MotionDrag.settle(0))
    }

    // MARK: - Pile seating

    @Test
    fun pileSeatsFarthestBackFirst() {
        assertEquals(
            mapOf("b" to 0, "d" to 2, "c" to 1, "a" to 1),
            PileSeating.seats(departureOrder = listOf("d", "c", "b", "a"), lead = "b", total = 4),
        )
        assertEquals(mapOf("y" to 0, "x" to 1), PileSeating.seats(departureOrder = listOf("x", "y"), lead = "y", total = 2))
        assertEquals(0, PileSeating.backRows(total = 1))
        assertEquals(1, PileSeating.backRows(total = 2))
        assertEquals(2, PileSeating.backRows(total = 7))
        assertEquals(Seat(row = 2, alpha = 0.55, z = 0), PileSeating.seat(row = 2))
        assertEquals(Seat(row = 1, alpha = 0.75, z = 1), PileSeating.seat(row = 1))
    }

    @Test
    fun pileShowsWhoeverACollapseWouldSeatLast() {
        // a → row 2, b, c → row 1 (c covers b).
        assertEquals(mapOf(2 to "a", 1 to "c"), PileSeating.shown(order = listOf("a", "b", "c"), lead = "l", total = 4, occupants = emptyMap()))
        assertEquals(mapOf(1 to "a"), PileSeating.shown(order = listOf("a"), lead = "l", total = 2, occupants = emptyMap()))
        assertTrue(PileSeating.shown(order = emptyList(), lead = "l", total = 1, occupants = emptyMap()).isEmpty())
    }

    @Test
    fun pileKeepsTheCollapsesOccupants() {
        assertEquals(
            mapOf(2 to "c", 1 to "a"),
            PileSeating.shown(order = listOf("a", "b", "c"), lead = "l", total = 4, occupants = mapOf(2 to "c", 1 to "a")),
        )
        // An occupant that left (or became the lead) gives its row to someone else behind.
        assertEquals(
            mapOf(2 to "c", 1 to "a"),
            PileSeating.shown(order = listOf("a", "b", "c"), lead = "l", total = 4, occupants = mapOf(2 to "x", 1 to "a")),
        )
    }

    @Test
    fun pileFillsEveryRowWhileSomeoneIsLeft() {
        // Merged [A, B, C] seated row 2 = B, row 1 = C; then C became the lead: B keeps row 2, and
        // row 1 (whose only seat candidate is B) goes to A rather than to the lead's look.
        assertEquals(
            mapOf(2 to "B", 1 to "A"),
            PileSeating.shown(order = listOf("A", "B"), lead = "C", total = 3, occupants = mapOf(2 to "B", 1 to "C")),
        )
        // Back rows grew from 1 to 2: the old row-1 occupant stays, the new row gets the other.
        assertEquals(
            mapOf(1 to "B", 2 to "C"),
            PileSeating.shown(order = listOf("B", "C"), lead = "A", total = 3, occupants = mapOf(1 to "B")),
        )
        // Never the same Critter twice.
        val shown = PileSeating.shown(order = listOf("a", "b"), lead = "l", total = 3, occupants = mapOf(1 to "a", 2 to "a"))
        assertEquals(shown.size, shown.values.toSet().size)
        assertEquals(2, shown.size)
    }

    // MARK: - Under ground

    @Test
    fun heldUnderGroundNothingBringsItBackUp() {
        val a = makeActor()
        a.enterState(PetState.done, quiet = true)
        a.startFollow(lookLeft = true)
        a.followShift(dx = 4.0, dy = 0.0)
        a.lift = 3
        a.fidgetIn = 10 // a fidget is due
        a.holdUnderground(depth = 12)
        assertTrue(!a.following && a.followOffset.x == 0 && a.lift == 0)
        a.play("burrow") // the sink itself plays over the hold
        assertEquals(0, a.snapshot().bodyY)
        stepUntilLoop(a)
        assertEquals(-12, a.snapshot().bodyY)
        assertEquals("base", a.snapshot().pose)
        repeat(10) { a.step() } // the poof fades
        assertTrue(a.particles.isEmpty())
        repeat(100) { // no fidget, and no twinkle sparkling in mid-air
            a.step()
            assertFalse(a.isPlayingOnce)
            assertTrue(a.particles.isEmpty())
        }
        a.enterState(PetState.waiting) // taken quietly: no alert jumping up
        assertFalse(a.isPlayingOnce)
        assertTrue(a.badgeVisible) // its "!" is up once it comes back
        a.setMode("pet")
        a.setGaze(GazeZone.left)
        a.startFollow(lookLeft = false)
        assertFalse(a.following)
        assertEquals(-12, a.snapshot().bodyY)
        assertTrue(a.snapshot().badge == null && a.snapshot().accessory == null)
        assertTrue(a.ticksUntilChange() > 1000) // and it wakes nobody
        a.reduceMotion = true // the still pose would stand on the ground
        assertEquals(-12, a.snapshot().bodyY)
    }

    @Test
    fun releasedFromUnderGroundItsLoopResumes() {
        val a = makeActor()
        a.enterState(PetState.idle, quiet = true)
        a.holdUnderground(depth = 12)
        a.enterState(PetState.waiting)
        a.play("pop_up") // popping back up, over the hold
        assertEquals(-12, a.snapshot().bodyY)
        a.releaseUnderground()
        assertNull(a.underground)
        assertEquals("pop_up", a.currentClipName) // the pop-up carries on...
        stepUntilLoop(a)
        assertEquals("ask", a.currentClipName) // ...into the state's loop
        assertEquals(0, a.snapshot().bodyY)
    }

    @Test
    fun underReducedMotionAHeldCritterIsGoneAtOnce() {
        val a = makeActor(reduceMotion = true)
        a.enterState(PetState.error, quiet = true)
        assertEquals(-1, a.snapshot().bodyY) // error's still pose sinks a cell
        a.holdUnderground(depth = 12)
        assertEquals(-12, a.snapshot().bodyY)
        a.releaseUnderground()
        assertEquals(-1, a.snapshot().bodyY)
    }
}
