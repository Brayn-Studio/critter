package local.critter.core.motion

import local.critter.core.protocol.PetState
import local.critter.core.skin.ClipKey
import local.critter.core.skin.MotionClip
import local.critter.core.skin.SkinManifest
import local.critter.core.skin.Tint

/**
 * One pet's motion, advanced one tick (`skin.tickMs`) at a time and read out as an
 * `ActorSnapshot`. Pure logic and not thread-safe: create and use it on one thread.
 *
 * Three playback layers, highest priority first: a one-shot clip (`play`), a mode loop
 * (`setMode`, e.g. while held) and the base loop (`setLoop`, the state's loop). While held
 * under ground (`holdUnderground`), that hold replaces both loops.
 *
 * The state brain (MotionActorState.kt) and travel, follow and gaze (MotionActorInteraction.kt)
 * are extension functions of this class in the same package, as Swift's extensions are.
 */
class MotionActor(
    val skin: SkinManifest,
    internal val rng: MotionRNG,
    reduceMotion: Boolean = false,
) {
    var reduceMotion: Boolean = reduceMotion
        set(value) {
            val old = field
            field = value
            if (value && !old) reduceMotionTurnedOn()
        }
    var tint: Tint? = null
    var alpha: Double = 1.0
    var z: Int = 2
    var hidden = false
    var noAccessory = false

    /** Height the actor is lifted off the ground, in cells (while held). */
    var lift = 0

    /** Sideways swing while held, in cells. Not drawn under reduced motion (`drawnLag`). */
    var lag = 0

    /** The swing as drawn: none under reduced motion, where a held Critter keeps still. */
    val drawnLag: Int get() = if (reduceMotion) 0 else lag

    var clock = 0
        internal set
    var modeName: String? = null
        internal set

    /** Name of the clip playing now; null for a generated clip. */
    var currentClipName: String? = null
        internal set
    var currentKeyIndex = 0
        internal set
    var particles: MutableList<Particle> = mutableListOf()
        internal set
    val isPlayingOnce: Boolean get() = onceActive

    // Playback layers.
    internal var baseClip: MotionClip = emptyList()
    internal var baseName: String? = null
    internal var modeClip: MotionClip? = null
    internal var onceActive = false
    internal var onceCompletion: ((Boolean) -> Unit)? = null

    /**
     * The state's entrance to replay if the one-shot playing now -- that entrance, or the
     * exit leading into it -- is cut short by a hop (see `travel`); null for any other one-shot.
     */
    internal var onceEntrance: String? = null
    internal var current: MotionClip = emptyList()
    internal var keyTicks = 0

    /** Per effect name, how many times it fired (picks the next `cycle` group). */
    internal var effectCycles: MutableMap<String, Int> = mutableMapOf()

    // State brain (MotionActorState.kt).
    var state: PetState = PetState.idle
        internal set

    /** The running variant shown (or last shown). */
    var variant = ""
        internal set
    var asleep = false
        internal set

    /** Whether the waiting state's resident "!" has appeared. */
    var badgeVisible = true
        internal set

    /** When false, nothing happens on its own: no fidgets, sleep, impatience or variant switch. */
    var brainEnabled = true
    internal var accessoryName: String? = null
    internal var propName: String? = null
    internal var idleTicks = 0
    internal var waitTicks = 0
    internal var fidgetIn = 80

    /** Ticks since the badge appeared; it hops for the first 2. */
    internal var badgeAge = 99

    /** The variant the latest activity asks for, and for how many ticks it has asked. */
    internal var desiredVariant = ""
    internal var desiredTicks = 0
    internal var variantShownTicks = 0

    // Travel, follow and gaze (MotionActorInteraction.kt).
    var traveling = false
        internal set
    var following = false
        internal set
    internal var travelSeat: Seat? = null

    /** Identifies the latest travel, so only its own completion clears the travel flags. */
    internal var travelID = 0

    /** Still dragging: keep following even when caught up. */
    internal var followHold = false
    internal var followLook: String? = null

    /** Follow offset in cells, y up. */
    internal var offX: Double = 0.0
    internal var offY: Double = 0.0
    internal var gazeZone: GazeZone? = null

    /** Cells under ground it is held at (`holdUnderground`); null while not held. */
    var underground: Int? = null
        internal set

    init {
        variant = skin.state(PetState.running).defaultVariant ?: ""
        desiredVariant = variant
        tint = skin.state(PetState.idle).tint
        accessoryName = skin.state(PetState.idle).accessory
        setLoop(stateLoopName())
    }

    // MARK: - Playback

    fun setLoop(name: String) = setLoop(skin.clips[name] ?: emptyList(), name)

    fun setLoop(clip: MotionClip, name: String?) {
        baseClip = clip
        baseName = name
        if (!onceActive && modeClip == null && underground == null) start(clip, name)
    }

    fun setMode(name: String?) {
        modeName = name
        modeClip = name?.let { skin.clips[it] ?: emptyList() }
        if (!onceActive && underground == null) resumeLoop()
    }

    fun play(name: String, completion: ((Boolean) -> Unit)? = null) =
        play(skin.clips[name] ?: emptyList(), name, completion)

    /**
     * Plays `clip` once over the loops. A one-shot it replaces completes with `false` -- after
     * the new one has started, so that callback may itself start another clip.
     */
    fun play(clip: MotionClip, name: String?, completion: ((Boolean) -> Unit)? = null) {
        val replaced = onceCompletion
        onceEntrance = null
        onceActive = true
        onceCompletion = completion
        start(clip, name)
        replaced?.invoke(false)
    }

    fun cancelOnce() {
        if (!onceActive) return
        val done = onceCompletion
        onceActive = false
        onceCompletion = null
        onceEntrance = null
        resumeLoop()
        done?.invoke(false)
    }

    /**
     * Ends the one-shot as if it played to the end: back to the start of the mode (or base)
     * loop, then the completion with `true`.
     */
    internal fun finishOnce() {
        val done = onceCompletion
        onceActive = false
        onceCompletion = null
        onceEntrance = null
        resumeLoop()
        done?.invoke(true)
    }

    internal fun resumeLoop() {
        val ground = underground
        val mode = modeClip
        if (ground != null) {
            start(listOf(ClipKey(pose = skin.interactions.land, ticks = 9999, dx = 0, dy = -ground)), null)
        } else if (mode != null) {
            start(mode, modeName)
        } else {
            start(baseClip, baseName)
        }
    }

    private fun start(clip: MotionClip, name: String?) {
        current = clip
        currentClipName = name
        currentKeyIndex = 0
        keyTicks = 0
        enterKey()
    }

    private fun enterKey() {
        currentKey?.effect?.let { emit(it) }
    }

    internal val currentKey: ClipKey? get() = current.getOrNull(currentKeyIndex)

    /**
     * Fires a particle effect. Unknown names are ignored; names starting with "@" are
     * engine-internal events, never particles.
     */
    fun emit(effect: String) {
        if (effect.startsWith("@")) {
            val seat = travelSeat
            if (effect == MotionTravel.SEAT_EFFECT && seat != null) applySeat(seat)
            return
        }
        if (reduceMotion) return
        val spec = skin.effects[effect] ?: return
        val turn = effectCycles[effect] ?: 0
        effectCycles[effect] = turn + 1
        particles.addAll(ParticleSpawner.spawn(spec, cycleIndex = turn, rng = rng))
    }

    // MARK: - Tick

    fun step() {
        followStep()
        brainStep()
        clock += 1
        badgeAge += 1
        val dt = skin.tickMs.toDouble() / 1000
        for (p in particles) p.step(dt)
        particles.removeAll { !it.isAlive }
        val spec = accessorySpec
        val every = spec?.twinkleEvery
        val twinkle = spec?.twinkle
        if (every != null && every > 0 && twinkle != null && clock % every == 0 && !noAccessory && underground == null) {
            emit(twinkle)
        }
        advanceKey()
    }

    private fun advanceKey() {
        val key = currentKey
        if (key == null) {
            if (onceActive) finishOnce()
            return
        }
        keyTicks += 1
        if (keyTicks < key.ticks) return
        keyTicks = 0
        currentKeyIndex += 1
        if (currentKeyIndex >= current.size) {
            if (onceActive) {
                finishOnce()
                return
            }
            currentKeyIndex = 0
        }
        enterKey()
    }

    // MARK: - Output

    fun snapshot(): ActorSnapshot {
        val f = frame()
        val markers = !hidden && markersAllowed(f.dy)
        val lag = drawnLag
        val particleDraws = if (hidden) emptyList() else particles.map { p ->
            val d = p.draw()
            d.copy(x = d.x + f.dx + lag, y = d.y - lift)
        }
        return ActorSnapshot(
            hidden = hidden, pose = f.pose, bodyX = f.dx + lag, bodyY = f.dy + lift,
            offsetX = jsRound(offX), offsetY = jsRound(offY),
            tint = tint, alpha = alpha, z = z, shadowWidth = shadowWidth(air = f.dy + lift),
            accessory = if (markers) accessoryDraw() else null,
            badge = if (markers) badgeDraw() else null,
            particles = particleDraws, props = if (hidden) emptyList() else propDraws(dx = f.dx),
        )
    }

    internal class Frame(val pose: String, val dx: Int, val dy: Int)

    /** The pose and key offset to show now. */
    internal fun frame(): Frame {
        if (following && !reduceMotion) return Frame(followPose(), 0, 0)
        if (reduceMotion) {
            val ground = underground
            if (ground != null) return Frame(skin.interactions.land, 0, -ground)
            if (modeName == skin.interactions.held) return Frame(skin.interactions.heldStill, 0, 0)
            val st = skin.state(state)
            if (asleep) return Frame(st.sleep?.still ?: st.still, 0, 0)
            return Frame(activeGaze ?: st.still, 0, st.stillDy ?: 0)
        }
        val key = currentKey
        return Frame(activeGaze ?: key?.pose ?: skin.interactions.lookCenter, key?.dx ?: 0, key?.dy ?: 0)
    }

    /** Ticks until the snapshot can next change on its own (at least 1). */
    fun ticksUntilChange(): Int {
        if (followMoving) return 1
        var n = NEVER
        val key = currentKey
        if (key != null) n = key.ticks - keyTicks else if (onceActive) n = 1
        val dt = skin.tickMs.toDouble() / 1000
        for (particle in particles) n = minOf(n, particle.ticksUntilDrawChanges(dt))
        n = minOf(n, markerTicksLeft(), brainTicksLeft())
        return maxOf(1, n)
    }

    companion object {
        /** Returned by `ticksUntilChange` when nothing will change on its own. */
        internal const val NEVER = Int.MAX_VALUE

        /** Shadow width in cells for a body `air` cells above the ground. */
        internal fun shadowWidth(air: Int): Int = if (air <= 0) 0 else if (air <= 2) 10 else if (air <= 5) 6 else 2
    }
}
