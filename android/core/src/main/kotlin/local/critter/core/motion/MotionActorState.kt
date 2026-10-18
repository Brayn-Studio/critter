package local.critter.core.motion

import local.critter.core.protocol.PetState
import local.critter.core.skin.AccessorySpec
import local.critter.core.skin.VariantSpec
import local.critter.core.skin.WeightedClip
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin

// States, the brain (fidgets, sleep, impatience, work-variant debounce), head markers and
// props — animation v2 design §4.2–4.5, §4.7 and §4.12. MotionActor+State.swift.

/** A new activity must persist this long before the running variant switches... */
internal const val VARIANT_SETTLE_TICKS = 20

/** ...and the current variant must have shown at least this long. */
internal const val VARIANT_MIN_SHOW_TICKS = 40

// MARK: - States

/** The base loop the current state wants now. */
fun MotionActor.stateLoopName(): String {
    val st = skin.state(state)
    val sleep = st.sleep
    if (asleep && sleep != null) return sleep.loop
    if (state == PetState.running) variantSpec(variant)?.let { return it.loop }
    val impatient = st.impatient
    if (isImpatient && impatient != null) return impatient.loop
    return st.loop ?: ""
}

fun MotionActor.enterState(s: PetState, quiet: Boolean = false) {
    // Held under ground, it takes the state quietly: an entrance would bring it back up.
    val silent = quiet || underground != null
    val previous = state
    val exit = if (previous == PetState.running && s != PetState.running) variantSpec(variant)?.exit else null
    val st = skin.state(s)
    state = s
    asleep = false
    idleTicks = 0
    waitTicks = 0
    tint = st.tint
    accessoryName = st.accessory
    if (s == PetState.running) {
        variant = desiredVariant
        desiredTicks = 0
        variantShownTicks = 0
    }
    propName = if (s == PetState.running) variantSpec(variant)?.prop else null
    setLoop(stateLoopName())
    fidgetIn = rng.integer(40..90)
    badgeVisible = silent || reduceMotion
    if (silent) return
    if (reduceMotion) { // no entrances or exits under reduced motion
        cancelOnce()
        return
    }
    val enter = if (s == PetState.running) variantSpec(variant)?.enter ?: st.enter else st.enter
    val seen = skin.state(PetState.done).seen
    if (exit != null) {
        play(exit) { ok ->
            if (state == s) {
                // An interrupted exit skips the entrance, but the badge must still show.
                if (ok) startEntrance(enter) else revealBadge()
            }
        }
        if (currentClipName == exit) onceEntrance = enter
    } else if (enter == null && previous == PetState.done && s == PetState.idle && seen != null) {
        play(seen)
        onceEntrance = seen
    } else {
        startEntrance(enter)
    }
}

/**
 * Plays the entrance (or cancels the one-shot when there is none); the waiting badge appears
 * the moment it starts.
 */
internal fun MotionActor.startEntrance(enter: String?) {
    revealBadge()
    if (enter != null) {
        play(enter)
        onceEntrance = enter
    } else {
        cancelOnce()
    }
}

private fun MotionActor.revealBadge() {
    if (skin.state(state).badge == null) return
    badgeVisible = true
    badgeAge = 0
}

/**
 * Records which kind of work the session is doing; null or unknown means the default variant.
 * Outside `running` it is just remembered; while running the switch is debounced.
 */
fun MotionActor.setActivity(activity: String?) {
    val running = skin.state(PetState.running)
    val v = activity?.takeIf { running.variants?.get(it) != null } ?: running.defaultVariant ?: ""
    if (v == desiredVariant) return
    desiredVariant = v
    desiredTicks = 0
}

fun MotionActor.wake() {
    if (!asleep) return
    asleep = false
    idleTicks = 0
    setLoop(stateLoopName())
    skin.state(state).sleep?.wake?.let { play(it) }
}

internal fun MotionActor.variantSpec(name: String): VariantSpec? = skin.state(PetState.running).variants?.get(name)

internal val MotionActor.isImpatient: Boolean
    get() {
        val impatient = skin.state(PetState.waiting).impatient
        if (state != PetState.waiting || impatient == null) return false
        return waitTicks >= impatient.after
    }

// MARK: - Brain

internal val MotionActor.brainActive: Boolean
    get() = brainEnabled && underground == null && modeName == null && !traveling && !following

internal fun MotionActor.brainStep() {
    if (!brainActive) return
    val st = skin.state(state)
    val sleep = st.sleep
    if (state == PetState.idle && !asleep && sleep != null) {
        idleTicks += 1
        if (idleTicks >= sleep.after) {
            asleep = true
            setLoop(sleep.loop)
            play(sleep.doze)
            return
        }
    }
    val impatient = st.impatient
    if (state == PetState.waiting && impatient != null) {
        waitTicks += 1
        if (waitTicks == impatient.after) setLoop(impatient.loop)
    }
    if (state == PetState.running) debounceVariant()
    // Nobody sees a hidden Critter fidget (a pile member behind the lead), and its one-shot
    // would keep the clock waking for nothing: its countdown waits until it shows again.
    val fidget = st.fidget
    if (fidget != null && !onceActive && !asleep && !reduceMotion && !hidden) {
        fidgetIn -= 1
        if (fidgetIn <= 0) {
            rng.pick(fidget.pick)?.let { play(it) }
            val lo = fidget.every.firstOrNull() ?: 1
            fidgetIn = rng.integer(lo..maxOf(lo, fidget.every.lastOrNull() ?: lo))
        }
    }
}

private fun MotionActor.debounceVariant() {
    variantShownTicks += 1
    if (desiredVariant == variant) return
    desiredTicks += 1
    if (desiredTicks >= VARIANT_SETTLE_TICKS && variantShownTicks >= VARIANT_MIN_SHOW_TICKS) {
        switchVariant(desiredVariant)
    }
}

/** Old variant's exit (if any), then the new variant's own enter (if any) over its loop. */
private fun MotionActor.switchVariant(v: String) {
    val old = variantSpec(variant)
    val new = variantSpec(v)
    variant = v
    desiredTicks = 0
    variantShownTicks = 0
    propName = new?.prop
    setLoop(stateLoopName())
    if (reduceMotion) return
    val oldExit = old?.exit
    val newEnter = new?.enter
    if (oldExit != null) {
        play(oldExit) { ok ->
            if (ok && state == PetState.running && variant == v && newEnter != null) play(newEnter)
        }
    } else if (newEnter != null) {
        play(newEnter)
    }
}

internal fun MotionActor.brainTicksLeft(): Int {
    if (!brainActive) return MotionActor.NEVER
    val st = skin.state(state)
    var n = MotionActor.NEVER
    if (st.fidget != null && !onceActive && !asleep && !reduceMotion && !hidden) n = minOf(n, fidgetIn)
    val sleep = st.sleep
    if (state == PetState.idle && !asleep && sleep != null) n = minOf(n, sleep.after - idleTicks)
    val impatient = st.impatient
    if (state == PetState.waiting && impatient != null && waitTicks < impatient.after) {
        n = minOf(n, impatient.after - waitTicks)
    }
    if (state == PetState.running && desiredVariant != variant) {
        n = minOf(n, maxOf(VARIANT_SETTLE_TICKS - desiredTicks, VARIANT_MIN_SHOW_TICKS - variantShownTicks))
    }
    return n
}

// MARK: - Head markers and props

internal val MotionActor.accessorySpec: AccessorySpec? get() = accessoryName?.let { skin.accessories[it] }

/**
 * Head marker and badge are hidden while merged, held, traveling, asleep, or when the key
 * sinks or rises too far.
 */
internal fun MotionActor.markersAllowed(dy: Int): Boolean =
    !noAccessory && modeName != skin.interactions.held && !traveling && !asleep && dy > -6 && dy < 7

internal fun MotionActor.accessoryDraw(): GlyphDraw? {
    val spec = accessorySpec ?: return null
    val glyph: String
    val top: Int
    var bob = 0
    val frames = spec.frames
    val single = spec.glyph
    if (frames != null && frames.isNotEmpty()) {
        glyph = if (reduceMotion) spec.reduced ?: frames[0] else frames[spinnerFrame(spec, frames, clock)]
        val h = glyphHeight(glyph)
        val box = spec.box ?: h
        top = -2 - box + floor((box - h).toDouble() / 2).toInt()
    } else if (single != null) {
        glyph = single
        top = -2 - glyphHeight(single)
        val every = spec.bobEvery
        if (every != null && every > 0 && !reduceMotion && (clock / every) % 2 == 1) bob = -1
    } else {
        return null
    }
    return GlyphDraw(glyph = glyph, color = spec.color, x = centeredX(glyph) + drawnLag, y = top + bob - lift, alpha = 1.0)
}

internal fun MotionActor.badgeDraw(): GlyphDraw? {
    val badge = skin.state(state).badge
    if (!badgeVisible || badge == null) return null
    val hop = if (!reduceMotion && badgeHops(clock, badgeAge)) -1 else 0
    return GlyphDraw(
        glyph = badge.glyph, color = badge.color, x = badge.x + drawnLag,
        y = -2 - glyphHeight(badge.glyph) + hop - lift, alpha = 1.0,
    )
}

private fun MotionActor.badgeHops(clock: Int, age: Int): Boolean {
    val badge = skin.state(state).badge ?: return false
    val period = if (isImpatient) badge.impatientHopEvery else badge.hopEvery
    return age < 2 || (period > 0 && clock % period < 2)
}

/** The juggled balls, only while the variant's own loop plays. */
internal fun MotionActor.propDraws(dx: Int): List<GlyphDraw> {
    if (reduceMotion || state != PetState.running) return emptyList()
    val name = propName ?: return emptyList()
    val prop = skin.props[name] ?: return emptyList()
    val loop = variantSpec(variant)?.loop ?: return emptyList()
    if (currentClipName != loop) return emptyList()
    return prop.colors.indices.map { i ->
        val ph = ((clock + 6 * i) % 18).toDouble() / 18
        GlyphDraw(
            glyph = prop.glyph, color = prop.colors[i], x = jsRound(3 + 11 * ph) + dx + drawnLag,
            y = -2 - jsRound(7 * sin(PI * ph)) - lift, alpha = 1.0,
        )
    }
}

/** Spinner frame on a cosine ease: slow at both ends of its period. */
private fun MotionActor.spinnerFrame(spec: AccessorySpec, frames: List<String>, at: Int): Int {
    val period = spec.periodMs
    if (period == null || period <= 0) return 0
    val t = (at.toLong() * skin.tickMs).toDouble()
    val i = jsRound((1 - cos(2 * PI * t / period.toDouble())) / 2 * (frames.size - 1).toDouble())
    return minOf(maxOf(i, 0), frames.size - 1)
}

internal fun MotionActor.markerTicksLeft(): Int {
    var n = MotionActor.NEVER
    if (!hidden && propDraws(0).isNotEmpty()) return 1
    val spec = accessorySpec
    val every = spec?.twinkleEvery
    if (spec != null && every != null && every > 0 && spec.twinkle != null &&
        !reduceMotion && !noAccessory && underground == null
    ) {
        n = minOf(n, every - clock % every)
    }
    if (hidden || reduceMotion || !markersAllowed(frame().dy)) return n
    if (spec != null) {
        val frames = spec.frames
        if (frames != null && frames.size > 1 && spec.periodMs != null) {
            val now = spinnerFrame(spec, frames, clock)
            n = minOf(n, (1..34).firstOrNull { spinnerFrame(spec, frames, clock + it) != now } ?: 34)
        }
        val bob = spec.bobEvery
        if (bob != null && bob > 0) n = minOf(n, bob - clock % bob)
    }
    val badge = skin.state(state).badge
    if (badgeVisible && badge != null) {
        val now = badgeHops(clock, badgeAge)
        val span = maxOf(badge.hopEvery, badge.impatientHopEvery) + 2
        val k = (1..span).firstOrNull { badgeHops(clock + it, badgeAge + it) != now }
        if (k != null) n = minOf(n, k)
    }
    return n
}

private fun MotionActor.glyphWidth(name: String): Int = skin.glyphs[name]?.firstOrNull()?.length ?: 0

private fun MotionActor.glyphHeight(name: String): Int = skin.glyphs[name]?.size ?: 0

/** Left column that centres the glyph on the base box (`round(9 − w/2)` for an 18-wide box). */
private fun MotionActor.centeredX(glyph: String): Int =
    jsRound((skin.grid.firstOrNull() ?: 18).toDouble() / 2 - glyphWidth(glyph).toDouble() / 2)

/** A weighted pick, as the preview's `pickWeighted`. */
internal fun MotionRNG.pick(list: List<WeightedClip>): String? {
    val total = list.sumOf { it.weight }
    var r = unit() * total.toDouble()
    for (w in list) {
        r -= w.weight.toDouble()
        if (r <= 0) return w.clip
    }
    return list.firstOrNull()?.clip
}
