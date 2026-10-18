package local.critter.core.motion

import local.critter.core.protocol.PetState
import local.critter.core.skin.ClipKey
import local.critter.core.skin.Tint
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

// Travel and pile seats, holding under ground, drag-follow and gaze — design §4.8–4.11.
// MotionActor+Interaction.swift.

/** Follow offset limits, in cells. */
internal const val FOLLOW_MAX_X = 12.0
internal const val FOLLOW_MAX_Y = 8.0

/** Beyond this horizontal offset a follower trots: 2 cells a tick instead of 1. */
internal const val FOLLOW_TROT_BEYOND = 6.0

/** Where the body is drawn relative to its anchor while following, in whole cells (y up). */
data class CellOffset(val x: Int, val y: Int)

// MARK: - Travel

/**
 * Hops from (`fromDx`, `fromDy`) cells relative to the new anchor to it. With `seat`, it
 * lands raised on the back of the pile and stays there dimmed. Under reduced motion it
 * arrives at once and `completion(true)` runs before returning.
 *
 * A hop that cuts short the state's entrance (or the exit leading into it) plays that
 * entrance again once it lands, as long as the state is still the same: a state change
 * that also moves the Critter's column must show both.
 */
fun MotionActor.travel(
    fromDx: Int,
    fromDy: Int,
    delay: Int,
    hopLength: Int = 14,
    seat: Seat? = null,
    completion: ((Boolean) -> Unit)? = null,
) {
    var startDx = fromDx
    var startDy = fromDy
    // Hopping somewhere else ends a follow: the hop starts where the body is drawn (the
    // follow offset folded into its start, y up like the keys), not at the anchor.
    if (following) {
        startDx += jsRound(offX)
        startDy += jsRound(offY)
        following = false
        followHold = false
        offX = 0.0
        offY = 0.0
    }
    val resumeEntrance = if (onceActive) onceEntrance else null
    val resumeState = state
    if (seat != null) setLoop(listOf(ClipKey(pose = skin.interactions.land, ticks = 9999, dx = 0, dy = seat.row)), null)
    if (reduceMotion) {
        if (seat != null) applySeat(seat)
        completion?.invoke(true)
        return
    }
    val keys = MotionTravel.keys(
        fromDx = startDx, fromDy = startDy, toDy = seat?.row ?: 0, delay = delay,
        hopLength = hopLength, names = skin.interactions,
    )
    // The flags belong to this travel only: a replaced travel's callback (or whatever it
    // starts) must neither clear them for this one nor leave them set after it.
    travelID += 1
    val id = travelID
    travelSeat = seat
    traveling = true
    play(keys, null) { ok ->
        if (travelID == id) {
            traveling = false
            travelSeat = null
            if (ok && seat == null && resumeEntrance != null && state == resumeState && !reduceMotion) {
                startEntrance(resumeEntrance)
            }
        }
        completion?.invoke(ok)
    }
}

/** Back from a pile seat to the state's own look and loop. */
fun MotionActor.unseat() {
    alpha = 1.0
    z = 2
    tint = skin.state(state).tint
    noAccessory = false
    setLoop(stateLoopName())
}

internal fun MotionActor.applySeat(seat: Seat) {
    tint = Tint.dim
    alpha = seat.alpha
    z = seat.z
}

/** Reduced motion just turned on: drop particles and follow offsets, land any hop at once. */
internal fun MotionActor.reduceMotionTurnedOn() {
    particles.clear()
    offX = 0.0
    offY = 0.0
    if (skin.state(state).badge != null) badgeVisible = true
    if (traveling) {
        travelSeat?.let { applySeat(it) }
        finishOnce()
    }
}

// MARK: - Under ground

/**
 * Sinks for good (a goodbye or a hide): from now on its loop is `depth` cells under
 * ground, above any mode or state loop, until `releaseUnderground()`. Only one-shots still
 * show over it (the sink itself, a drop-in); the brain rests, a state is taken quietly,
 * and a follow, a lift or a mode ends -- nothing brings it back up on its own.
 */
fun MotionActor.holdUnderground(depth: Int) {
    underground = depth
    modeName = null
    modeClip = null
    following = false
    followHold = false
    offX = 0.0
    offY = 0.0
    lift = 0
    lag = 0
    if (!onceActive) resumeLoop()
}

/** Back up from under ground: the state's loop resumes (after any one-shot playing). */
fun MotionActor.releaseUnderground() {
    if (underground == null) return
    underground = null
    if (!onceActive) resumeLoop()
}

// MARK: - Follow

/**
 * While another Critter is dragged, this one stays put on screen and walks after the window,
 * looking toward the dragged one once caught up. Ignored while traveling, hidden or held
 * under ground.
 */
fun MotionActor.startFollow(lookLeft: Boolean) {
    if (traveling || hidden || underground != null) return
    cancelOnce()
    gazeZone = null
    following = true
    followHold = true
    followLook = if (lookLeft) skin.interactions.lookLeft else skin.interactions.lookRight
}

/** The window moved by (`dx`, `dy`) cells, y up. */
fun MotionActor.followShift(dx: Double, dy: Double) {
    if (!following || reduceMotion) return
    offX = min(max(offX - dx, -FOLLOW_MAX_X), FOLLOW_MAX_X)
    offY = min(max(offY - dy, -FOLLOW_MAX_Y), FOLLOW_MAX_Y)
}

/** The drag ended: stop following once caught up. */
fun MotionActor.releaseFollow() {
    followHold = false
}

internal fun MotionActor.followStep() {
    if (!following) return
    if (reduceMotion) {
        offX = 0.0
        offY = 0.0
    }
    val sx = if (abs(offX) > FOLLOW_TROT_BEYOND) 2.0 else 1.0
    offX = if (abs(offX) <= sx) 0.0 else offX - (if (offX > 0) sx else -sx)
    if (offY != 0.0) {
        offY = if (abs(offY) <= 1) 0.0 else offY - (if (offY > 0) 1.0 else -1.0)
        if (offY == 0.0) emit(skin.interactions.landDust)
    }
    if (!followHold && offX == 0.0 && offY == 0.0) {
        following = false
        if (!reduceMotion) play(skin.interactions.blink)
    }
}

/** Where the body is drawn relative to its anchor while following: the snapshot's `offsetX`/`offsetY`, without building a snapshot. */
val MotionActor.followOffset: CellOffset get() = CellOffset(jsRound(offX), jsRound(offY))

/** Still catching up, or about to stop following. */
internal val MotionActor.followMoving: Boolean get() = following && (offX != 0.0 || offY != 0.0 || !followHold)

/** Hop while catching up vertically, walk (trot when far) horizontally, else look at the dragged one. */
internal fun MotionActor.followPose(): String {
    val names = skin.interactions
    if (abs(offY) >= 1) return names.hop
    if (abs(offX) >= 1) {
        val cycle = if (offX < 0) names.walkRight else names.walkLeft
        val odd = (clock / (if (abs(offX) > FOLLOW_TROT_BEYOND) 1 else 2)) % 2 == 1
        return cycle[(if (odd) 0 else 1) % cycle.size]
    }
    return followLook ?: names.lookCenter
}

// MARK: - Gaze

fun MotionActor.setGaze(zone: GazeZone?) {
    gazeZone = zone
}

/**
 * The gaze pose, when it may replace the current one: idle and awake, or done; no
 * one-shot, no mode, not following, not under ground. A state with its own `gaze` poses
 * looks around with those.
 */
internal val MotionActor.activeGaze: String?
    get() {
        val zone = gazeZone ?: return null
        if (!((state == PetState.idle && !asleep) || state == PetState.done) ||
            onceActive || modeName != null || following || underground != null
        ) {
            return null
        }
        skin.state(state).gaze?.let { return it.pose(zone) }
        val names = skin.interactions
        return when (zone) {
            GazeZone.left -> names.lookLeft
            GazeZone.right -> names.lookRight
            GazeZone.up -> names.lookUp
            GazeZone.down -> names.lookDown
            GazeZone.center -> names.lookCenter
        }
    }
