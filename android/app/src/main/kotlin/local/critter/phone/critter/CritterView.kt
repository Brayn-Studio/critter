package local.critter.phone.critter

import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.MotionEvent
import android.view.View
import local.critter.core.motion.ActorSnapshot
import local.critter.core.motion.GazeZone
import local.critter.core.motion.MotionActor
import local.critter.core.motion.MotionCues
import local.critter.core.motion.MotionDrag
import local.critter.core.motion.MotionGaze
import local.critter.core.motion.MotionRNG
import local.critter.core.motion.PileSeating
import local.critter.core.motion.Pt
import local.critter.core.motion.RubDetector
import local.critter.core.motion.TickGrid
import local.critter.core.motion.carry
import local.critter.core.motion.enterState
import local.critter.core.motion.holdUnderground
import local.critter.core.motion.releaseUnderground
import local.critter.core.motion.setActivity
import local.critter.core.motion.setGaze
import local.critter.core.motion.sleepNow
import local.critter.core.motion.travel
import local.critter.core.motion.unseat
import local.critter.core.motion.wake
import local.critter.core.motion.walkHome
import local.critter.core.protocol.PetState
import local.critter.core.skin.MotionClip
import local.critter.core.skin.SkinManifest
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * One Critter to draw. [x] and [y] are view pixels: where the base box's column 0 meets the ground
 * (y grows downward); [scale] is pixels per cell. [seatRow] puts it on the back of a pile (dimmed, still, no
 * shadow); [sleeping] shows an idle Critter dozing (the offline pile).
 */
data class CritterSlot(
    val sessionId: String,
    val manifest: SkinManifest,
    val state: PetState,
    val activity: String?,
    val dimStrength: Double,
    val x: Float,
    val y: Float,
    val scale: Float,
    val seatRow: Int? = null,
    val sleeping: Boolean = false,
)

interface CritterTouchListener {
    /** A touch that was neither a drag nor a rub: the Critter was booped. */
    fun onTap(sessionId: String)

    /** The finger let go after lifting the Critter (it has been dropped). */
    fun onLongDragEnd(sessionId: String)

    /** The finger moved past the drag threshold: the Critter is lifted. */
    fun onDragStart(sessionId: String) {}

    /** The finger's total movement in screen pixels since it touched down, while the Critter is held. */
    fun onDragBy(dxPx: Float, dyPx: Float) {}

    /** With [CritterView.carryOnDrag]: the Critter was carried away from its place ([away]), or walked back to it. */
    fun onCarry(sessionId: String, away: Boolean) {}
}

/**
 * Draws one or more Critters with the desktop's rules ([CritterRenderer]), advances them on a clock that only
 * wakes when the picture can next change ([CritterClock]) and stops while it cannot be seen, and reacts to
 * touch the way the pet reacts to the mouse (spec §8.2): a press is noticed (sleepers wake, the others reach
 * up), a drag past 3 dp lifts, a release drops or boops, rubbing back and forth pets, and the others look at
 * the finger. No hover on a phone, so nothing happens without a finger on the screen.
 */
class CritterView(context: Context) : View(context) {
    private class Entry(var slot: CritterSlot, var actor: MotionActor, var atlas: SpriteAtlas) {
        var last: ActorSnapshot? = null
    }

    private class Press(val id: String, val downRawX: Float, val downRawY: Float) {
        var dragging = false
        var grabbedId: String? = null
        var lastRawX = downRawX
        var lastMove = 0.0
        var squeezed = false
        var carrying = false
    }

    var listener: CritterTouchListener? = null

    /** A touch that lands on no Critter counts for the first one (the pile's label and counts belong to it). */
    var claimAllTouches = false

    /**
     * A drag carries the lifted Critter sideways inside the view, and once let go it lands and walks back to its
     * place (the board, spec §8.7). Off, the Critter stays put and the window follows the finger instead
     * ([CritterTouchListener.onDragBy], the floating pile).
     */
    var carryOnDrag: Boolean = false

    /**
     * Where the Critters look while no finger is down: the collapsed floating pile looks into the screen (design
     * §8.4); null looks straight ahead. A finger still drives the gaze and hands it back when it lifts. The engine
     * only lets idle and done Critters look, so busy ones keep their own animations.
     */
    var restingGaze: GazeZone? = null
        set(value) {
            if (field == value) return
            field = value
            clock.catchUp()
            applyRestingGaze()
            clock.poke()
        }

    /** How many times [onDraw] ran; for the debug gallery and the power check. */
    var debugFrameCount: Int = 0
        private set

    private val density = resources.displayMetrics.density
    private val renderer = CritterRenderer()
    private val entries = LinkedHashMap<String, Entry>()
    private val order = ArrayList<Entry>()
    private val clock = CritterClock(DEFAULT_TICK_MS) { tick(it) }
    private var layoutDirty = false
    private var reduceMotion = false
    private var systemReduce = false
    private var windowShown = false
    private var aggregatedShown = false
    private var paused = false

    private var press: Press? = null
    private var pettingId: String? = null

    /** Critters carried away from their place, from the lift until they are back ([CritterTouchListener.onCarry]). */
    private val away = HashSet<String>()

    /** Those of them walking back. */
    private val homing = HashSet<String>()

    private val handler = Handler(Looper.getMainLooper())

    /** Clips waiting for their delay ([playClip]); dropped when the view is detached. */
    private val delayedClips = ArrayList<Runnable>()

    // The staggered steps of the latest sink or rise; a newer one cancels them.
    private val staged = ArrayList<Runnable>()
    private var showHideGeneration = 0
    private var sinking: MutableSet<String>? = null
    private var sinkDone: (() -> Unit)? = null

    /** Held under ground by [riseAll] and not released yet. */
    private var rising: MutableSet<String>? = null

    private val rub = RubDetector()
    private var gaze = HashMap<String, GazeZone?>()

    /** Reduce motion is on when the settings say so or the system's animation scale is 0. */
    private fun applyReduceMotion() {
        val want = MotionPrefs.manual || systemReduce
        if (want == reduceMotion) return
        reduceMotion = want
        for (e in entries.values) e.actor.reduceMotion = want
    }

    fun setActors(list: List<CritterSlot>) {
        applyReduceMotion()
        // One clock for the whole view, on its skins' tick (the library only lets skins on one tick share a row).
        list.firstOrNull()?.let { clock.retune(it.manifest.tickMs.toLong()) }
        clock.catchUp()
        val ids = HashSet<String>(list.size * 2)
        list.mapTo(ids) { it.sessionId }
        val gone = entries.keys.filter { it !in ids }
        for (id in gone) {
            entries.remove(id)
            forget(id)
        }
        for (slot in list) {
            val entry = entries[slot.sessionId]
            if (entry == null || entry.slot.manifest !== slot.manifest) {
                if (entry != null) forget(slot.sessionId)
                entries[slot.sessionId] = createEntry(slot)
            } else {
                update(entry, slot)
            }
        }
        applyRestingGaze()
        layoutDirty = true
        clock.poke()
    }

    /** Plays [clip] once on one Critter (for the "notice" hop when a session starts waiting). */
    fun play(sessionId: String, clip: String) {
        clock.catchUp()
        val entry = entries[sessionId] ?: return
        if (isFree(sessionId)) entry.actor.play(clip)
        clock.poke()
    }

    /** The hop a Critter makes when it needs you (the skin's `notice` action). */
    fun notice(sessionId: String) {
        val notice = entries[sessionId]?.slot?.manifest?.interactions?.notice ?: return
        play(sessionId, notice)
    }

    /** Plays [clip] once on one Critter after [delayMs], if it is free by then; under reduce motion it keeps its still pose. */
    fun playClip(sessionId: String, clip: MotionClip, delayMs: Long = 0) {
        if (delayMs > 0) {
            val runnable = object : Runnable {
                override fun run() {
                    delayedClips.remove(this)
                    playClip(sessionId, clip)
                }
            }
            delayedClips += runnable
            handler.postDelayed(runnable, delayMs)
            return
        }
        clock.catchUp()
        val entry = entries[sessionId] ?: return
        if (!reduceMotion && isFree(sessionId)) entry.actor.play(clip, null)
        clock.poke()
    }

    /** The Critter looks up at you ([MotionCues.lookAtYou]): a sheet just settled over it. */
    fun lookAtYou(sessionId: String) {
        val skin = entries[sessionId]?.slot?.manifest ?: return
        playClip(sessionId, MotionCues.lookAtYou(skin))
    }

    /** One small hop ([MotionCues.hop]) after [delayMs]: the floating shelf opening and closing. */
    fun hop(sessionId: String, delayMs: Long = 0) {
        val skin = entries[sessionId]?.slot?.manifest ?: return
        playClip(sessionId, MotionCues.hop(skin), delayMs)
    }

    /**
     * Every Critter in view sinks into the ground (`vanish`), [staggerMs] after the previous one, and stays
     * there; then [onDone], unless [riseAll] or another sink came first. At once under reduce motion or out of
     * sight. The desktop's `FlockChoreographer.playVanish`.
     */
    fun sinkAll(staggerMs: Long = 60, onDone: () -> Unit) {
        val generation = newShowHide()
        clock.catchUp()
        val ids = entries.filterValues { !it.actor.hidden && it.actor.underground == null }.keys.toList()
        sinking = ids.toMutableSet()
        sinkDone = onDone
        if (ids.isEmpty() || reduceMotion || !clock.isRunning) {
            finishSink()
            return
        }
        ids.forEachIndexed { i, id -> stage(i * staggerMs) { sinkOut(id, generation) } }
    }

    /**
     * Every Critter in view comes up out of the ground, [staggerMs] after the previous one: `appear`, or with
     * [join] the skin's `join` (it looks left and right on the way up). Those still above ground go under first;
     * a sink in progress is called off. The desktop's `FlockChoreographer.playAppear`.
     */
    fun riseAll(staggerMs: Long = 90, join: Boolean = false) {
        newShowHide()
        clock.catchUp()
        val ids = entries.filterValues { !it.actor.hidden }.keys.toList()
        for (id in ids) entries[id]?.actor?.let { if (it.underground == null) it.holdUnderground(UNDERGROUND_CELLS) }
        rising = ids.toMutableSet()
        if (reduceMotion) {
            finishRise()
        } else {
            ids.forEachIndexed { i, id -> stage(i * staggerMs) { riseUp(id, join) } }
        }
        clock.poke()
    }

    /** Stops the clock without detaching (the screen went off); [setPaused] false resumes it. */
    fun setPaused(paused: Boolean) {
        this.paused = paused
        if (!paused) readSystemReduce()
        updateRunning()
    }

    /** The system "remove animations" switch (animation scale 0) = the desktop's "reduce motion"; it can change any time. */
    private fun readSystemReduce() {
        val scale = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        systemReduce = scale == 0f
        applyReduceMotion()
    }

    // ---- entries ------------------------------------------------------------------------------------------

    private fun createEntry(slot: CritterSlot): Entry {
        val actor = MotionActor(slot.manifest, MotionRNG.system(), reduceMotion)
        actor.setActivity(slot.activity)
        actor.enterState(slot.state, quiet = true)
        if (slot.sleeping) actor.sleepNow()
        val entry = Entry(slot, actor, AtlasPool.get(slot.manifest, slot.dimStrength))
        slot.seatRow?.let { seat(actor, it) }
        return entry
    }

    private fun update(entry: Entry, slot: CritterSlot) {
        val actor = entry.actor
        val old = entry.slot
        entry.slot = slot
        if (slot.dimStrength != old.dimStrength) entry.atlas = AtlasPool.get(slot.manifest, slot.dimStrength)
        actor.setActivity(slot.activity)
        if (slot.state != actor.state) actor.enterState(slot.state)
        if (slot.sleeping && !actor.asleep) actor.sleepNow()
        if (!slot.sleeping && old.sleeping) actor.wake()
        if (slot.seatRow != old.seatRow) {
            val row = slot.seatRow
            if (row != null) {
                seat(actor, row)
            } else {
                actor.brainEnabled = true
                actor.unseat()
            }
        }
    }

    /** A pile member behind the lead: hops onto its row, then stays there dimmed and quiet. */
    private fun seat(actor: MotionActor, row: Int) {
        actor.brainEnabled = false
        actor.noAccessory = true
        actor.travel(fromDx = 0, fromDy = 0, delay = 0, seat = PileSeating.seat(row))
    }

    private fun forget(id: String) {
        gaze.remove(id)
        homing.remove(id)
        rising?.remove(id)
        sinkFinished(id)
        if (pettingId == id) pettingId = null
        val p = press
        if (p != null && (p.id == id || p.grabbedId == id)) press = null
        // Gone (or rebuilt at home) while carried or walking back: it is not away any more.
        if (away.remove(id)) listener?.onCarry(id, away = false)
    }

    // ---- lifetime -----------------------------------------------------------------------------------------

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        readSystemReduce()
        windowShown = windowVisibility == VISIBLE
        aggregatedShown = isShown
        updateRunning()
    }

    override fun onDetachedFromWindow() {
        cancelPress()
        windowShown = false
        aggregatedShown = false
        updateRunning() // finishes a sink
        finishRise()
        for (r in delayedClips) handler.removeCallbacks(r)
        delayedClips.clear()
        super.onDetachedFromWindow()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        windowShown = visibility == VISIBLE
        // Coming back into view (an activity resumed, the pile shown again): the switch may have changed meanwhile.
        if (windowShown) readSystemReduce()
        updateRunning()
    }

    override fun onConfigurationChanged(newConfig: Configuration?) {
        super.onConfigurationChanged(newConfig)
        readSystemReduce()
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        aggregatedShown = isVisible
        updateRunning()
    }

    private fun updateRunning() {
        if (isAttachedToWindow && windowShown && aggregatedShown && !paused) {
            clock.start()
        } else {
            if (!isAttachedToWindow || !windowShown) cancelPress()
            clock.stop()
            // Nobody can watch it sink: done now.
            finishSink()
        }
    }

    // ---- sink and rise -------------------------------------------------------------------------------------

    /** Calls off the previous sink or rise (its steps, and a sink's `onDone`) and starts a new one. */
    private fun newShowHide(): Int {
        cancelStaged()
        sinking = null
        sinkDone = null
        rising = null
        return ++showHideGeneration
    }

    /** Runs [step] after [delayMs] (now for 0), unless a newer sink or rise cancels it first. */
    private fun stage(delayMs: Long, step: () -> Unit) {
        if (delayMs <= 0) {
            step()
            return
        }
        val runnable = object : Runnable {
            override fun run() {
                staged.remove(this)
                step()
            }
        }
        staged += runnable
        handler.postDelayed(runnable, delayMs)
    }

    private fun cancelStaged() {
        for (r in staged) handler.removeCallbacks(r)
        staged.clear()
    }

    private fun sinkOut(id: String, generation: Int) {
        val actor = entries[id]?.actor ?: return sinkFinished(id)
        if (actor.underground != null) return sinkFinished(id)
        clock.catchUp()
        actor.holdUnderground(UNDERGROUND_CELLS)
        if (reduceMotion) {
            sinkFinished(id)
        } else {
            actor.play(actor.skin.interactions.vanish) { if (generation == showHideGeneration) sinkFinished(id) }
        }
        clock.poke()
    }

    private fun sinkFinished(id: String) {
        val left = sinking ?: return
        if (left.remove(id) && left.isEmpty()) finishSink()
    }

    /** Ends the sink in progress (if any): whoever is still above ground goes under at once, then its `onDone`. */
    private fun finishSink() {
        val done = sinkDone ?: return
        cancelStaged()
        sinking = null
        sinkDone = null
        for (e in entries.values) if (!e.actor.hidden && e.actor.underground == null) e.actor.holdUnderground(UNDERGROUND_CELLS)
        clock.poke()
        done()
    }

    /** Ends the rise in progress (if any): whoever is still held comes up at once, without the animation. */
    private fun finishRise() {
        val left = rising ?: return
        cancelStaged()
        rising = null
        for (id in left) entries[id]?.actor?.releaseUnderground()
        clock.poke()
    }

    private fun riseUp(id: String, join: Boolean) {
        rising?.remove(id)
        val actor = entries[id]?.actor ?: return
        clock.catchUp()
        actor.releaseUnderground()
        if (!reduceMotion) actor.play(if (join) actor.skin.interactions.join else actor.skin.interactions.appear)
        clock.poke()
    }

    // ---- clock ---------------------------------------------------------------------------------------------

    /** Advances every actor [ticks] ticks, refreshes the snapshots, and returns the ticks until the next change. */
    private fun tick(ticks: Int): Int {
        repeat(ticks) {
            for (e in entries.values) e.actor.step()
            interactionDidStep()
        }
        if (homing.isNotEmpty()) reportHome()
        var changed = layoutDirty
        layoutDirty = false
        var next = TickGrid.maxSleepTicks
        for (e in entries.values) {
            val s = e.actor.snapshot()
            if (s != e.last) {
                e.last = s
                changed = true
            }
            if (!e.actor.hidden || e.actor.isPlayingOnce) next = minOf(next, e.actor.ticksUntilChange())
        }
        if (changed) invalidate() // nothing changed, nothing drawn
        return minOf(next, interactionTicksUntilCue())
    }

    override fun onDraw(canvas: Canvas) {
        debugFrameCount++
        order.clear()
        for (e in entries.values) {
            val s = e.last ?: continue
            var i = order.size
            order.add(e)
            // Insertion sort by z (stable): later ones on top.
            while (i > 0 && (order[i - 1].last?.z ?: 0) > s.z) {
                order[i] = order[i - 1]
                i--
            }
            order[i] = e
        }
        for (e in order) {
            val s = e.last ?: continue
            renderer.draw(canvas, s, e.atlas, e.slot.x, e.slot.y, e.slot.scale, e.slot.seatRow)
        }
    }

    // ---- touch ---------------------------------------------------------------------------------------------

    private val now: Double get() = SystemClock.uptimeMillis() / 1000.0

    private fun isFree(id: String): Boolean {
        val a = entries[id]?.actor ?: return false
        return !a.hidden && !a.traveling && !a.following && a.underground == null
    }

    /** The visible Critter a touch at ([x], [y]) belongs to: its base box plus the room above it, with some slop. */
    private fun hit(x: Float, y: Float): String? {
        val slop = HIT_SLOP_DP * density
        var best: String? = null
        var bestDistance = Float.MAX_VALUE
        for ((id, e) in entries) {
            if (e.actor.hidden) continue
            val u = e.slot.scale
            val left = e.slot.x
            val ground = e.slot.y
            if (x < left - slop || x > left + BASE_COLUMNS * u + slop || y < ground - 12 * u - slop || y > ground + slop) continue
            val d = hypot(x - (left + 9 * u), y - (ground - 5 * u))
            if (d < bestDistance) {
                bestDistance = d
                best = id
            }
        }
        // The pile's front Critter (not a seated one behind it) takes the touches nobody else was under.
        return best ?: if (claimAllTouches) (entries.entries.firstOrNull { it.value.slot.seatRow == null } ?: entries.entries.firstOrNull())?.key else null
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> return pointerDown(event)
            MotionEvent.ACTION_MOVE -> pointerMove(event)
            MotionEvent.ACTION_UP -> pointerUp(event)
            MotionEvent.ACTION_CANCEL -> cancelPress()
        }
        return press != null
    }

    private fun pointerDown(e: MotionEvent): Boolean {
        cancelPress()
        val id = hit(e.x, e.y) ?: return false
        press = Press(id, e.rawX, e.rawY)
        clock.catchUp()
        endPet()
        if (isFree(id)) {
            val actor = entries.getValue(id).actor
            // A sleeper is woken by the touch (its startle gives way to the squeeze).
            actor.wake()
            actor.cancelOnce()
            actor.setMode(actor.skin.interactions.press)
            press?.squeezed = true
        }
        updateGaze(e.x, e.y)
        clock.poke()
        return true
    }

    private fun pointerMove(e: MotionEvent) {
        val p = press ?: return
        clock.catchUp()
        val t = now
        if (!p.dragging) {
            val moved = hypot(e.rawX - p.downRawX, e.rawY - p.downRawY) / density
            if (moved >= DRAG_THRESHOLD_DP) {
                p.dragging = true
                beginDrag(p)
            } else {
                updateGaze(e.x, e.y)
            }
        }
        if (p.dragging) {
            val grabbed = p.grabbedId?.let { entries[it]?.actor }
            if (grabbed != null && pettingId == null) {
                grabbed.lag = MotionDrag.lag(((e.rawX - p.lastRawX) / density).toDouble())
                p.lastMove = t
                if (p.carrying) carryTo(p, e.rawX) else listener?.onDragBy(e.rawX - p.downRawX, e.rawY - p.downRawY)
            }
            p.lastRawX = e.rawX
        }
        // Rubbing back and forth pets, even after the drag started lifting it (not one carried across the view).
        // Screen coordinates: the view's own move with the window while it is dragged.
        if (!p.carrying && rub.move((e.rawX / density).toDouble(), t) && pettingId != p.id && isFree(p.id)) startPet(p)
        clock.poke()
    }

    private fun beginDrag(p: Press) {
        endPet()
        rub.reset()
        clearGaze()
        val grabbed = entries[p.id]?.actor
        if (grabbed == null || !isFree(p.id)) {
            releaseMode(p.id)
            return
        }
        grabbed.cancelOnce()
        grabbed.setMode(grabbed.skin.interactions.held)
        grabbed.lift = HELD_LIFT_CELLS
        p.grabbedId = p.id
        p.lastMove = now
        listener?.onDragStart(p.id)
        if (carryOnDrag) {
            p.carrying = true
            away += p.id
            listener?.onCarry(p.id, away = true)
        }
    }

    /** The carried Critter follows the finger sideways, its base box kept inside the view. */
    private fun carryTo(p: Press, rawX: Float) {
        val e = entries[p.id] ?: return
        val u = e.slot.scale
        val min = -e.slot.x / u
        val max = maxOf(min, (width - e.slot.x) / u - BASE_COLUMNS)
        e.actor.carry(((rawX - p.downRawX) / u).coerceIn(min, max).toDouble())
    }

    /** Lets go of a carried Critter: it lands where it is (`drop`), then walks home; straight home under reduce motion. */
    private fun putDown(id: String, actor: MotionActor) {
        if (reduceMotion || !isFree(id)) {
            sendHome(id, actor)
            return
        }
        actor.play(actor.skin.interactions.drop) { if (entries[id]?.actor === actor) sendHome(id, actor) }
    }

    private fun sendHome(id: String, actor: MotionActor) {
        actor.walkHome()
        homing += id
    }

    /** Carried Critters that are back in their place: the place is theirs again. */
    private fun reportHome() {
        val home = homing.filter { entries[it]?.actor?.following != true }
        homing.removeAll(home.toSet())
        for (id in home) if (away.remove(id)) listener?.onCarry(id, away = false)
    }

    private fun startPet(p: Press) {
        val actor = entries[p.id]?.actor ?: return
        actor.lift = 0
        actor.lag = 0
        actor.setMode(actor.skin.interactions.pet)
        pettingId = p.id
        p.grabbedId = null
    }

    private fun pointerUp(e: MotionEvent) {
        val p = press ?: return
        press = null
        clock.catchUp()
        clearGaze()
        rub.reset()
        val actor = entries[p.id]?.actor
        if (pettingId != null) {
            endPet() // a rub is not a tap
            if (p.dragging) listener?.onLongDragEnd(p.id) // the window may have been moved before the rub was noticed
        } else if (p.dragging) {
            if (actor != null && p.grabbedId != null) {
                actor.lift = 0
                actor.lag = 0
                actor.setMode(null)
                if (p.carrying) putDown(p.id, actor) else if (isFree(p.id)) actor.play(actor.skin.interactions.drop)
            }
            clock.poke()
            listener?.onLongDragEnd(p.id)
            return
        } else {
            if (actor != null && p.squeezed) {
                actor.setMode(null)
                if (isFree(p.id)) actor.play(actor.skin.interactions.boopEnd)
            }
            clock.poke()
            listener?.onTap(p.id)
            return
        }
        clock.poke()
    }

    /** The touch ended without a release (the view was hidden or rebuilt mid-press): let go without the click. */
    private fun cancelPress() {
        val p = press ?: return
        press = null
        for (id in listOfNotNull(p.id, p.grabbedId).distinct()) {
            val actor = entries[id]?.actor ?: continue
            actor.lift = 0
            actor.lag = 0
            releaseMode(id)
        }
        if (p.carrying) {
            entries[p.id]?.actor?.carry(0.0)
            if (away.remove(p.id)) listener?.onCarry(p.id, away = false)
        }
        endPet()
        clearGaze()
        rub.reset()
        clock.poke()
    }

    private fun releaseMode(id: String) {
        val actor = entries[id]?.actor ?: return
        val mode = actor.modeName ?: return
        if (mode == actor.skin.interactions.press || mode == actor.skin.interactions.held) actor.setMode(null)
    }

    /** Ends petting (if any): back from the pet mode, with its little ending. */
    private fun endPet() {
        val id = pettingId ?: return
        pettingId = null
        val actor = entries[id]?.actor ?: return
        if (actor.modeName != actor.skin.interactions.pet) return
        actor.setMode(null)
        if (isFree(id)) actor.play(actor.skin.interactions.petEnd)
    }

    /** The others look at the finger (the pressed one is busy with its own mode). */
    private fun updateGaze(x: Float, y: Float) {
        // MotionGaze works in dp, y up.
        val pointer = Pt((x / density).toDouble(), (-y / density).toDouble())
        for ((id, e) in entries) {
            if (e.actor.hidden || e.slot.seatRow != null) continue
            val u = e.slot.scale / density
            val center = Pt(((e.slot.x + 9 * e.slot.scale) / density).toDouble(), ((-e.slot.y + 7 * e.slot.scale) / density).toDouble())
            val zone = MotionGaze.zone(pointer, center, u.toDouble())
            if (gaze[id] != zone) {
                gaze[id] = zone
                e.actor.setGaze(zone)
            }
        }
    }

    private fun clearGaze() {
        for (id in gaze.keys) entries[id]?.actor?.setGaze(null)
        gaze.clear()
        applyRestingGaze()
    }

    /** With no finger down, every Critter looks at [restingGaze] (a finger's gaze wins while it is down). */
    private fun applyRestingGaze() {
        if (press != null) return
        for (e in entries.values) e.actor.setGaze(restingGaze)
    }

    /** After every tick's step: petting ends 0.7 s after the last rub, and the held Critter's swing settles. */
    private fun interactionDidStep() {
        val t = now
        if (pettingId != null && rub.shouldEnd(t)) {
            endPet()
            rub.reset()
        }
        val p = press ?: return
        val id = p.grabbedId ?: return
        val actor = entries[id]?.actor ?: return
        if (p.dragging && actor.lag != 0 && t - p.lastMove > LAG_SETTLE_DELAY_S) actor.lag = MotionDrag.settle(actor.lag)
    }

    /** Ticks until the interactions need the clock again: every tick while petting or while the held one swings. */
    private fun interactionTicksUntilCue(): Int {
        if (pettingId != null) return 1
        val p = press
        val actor = p?.grabbedId?.let { entries[it]?.actor }
        if (p != null && p.dragging && actor != null && actor.drawnLag != 0) return 1
        return TickGrid.maxSleepTicks
    }

    private companion object {
        const val DEFAULT_TICK_MS = 60L
        const val DRAG_THRESHOLD_DP = 3f
        const val HIT_SLOP_DP = 6f
        const val HELD_LIFT_CELLS = 3
        const val LAG_SETTLE_DELAY_S = 0.12
        const val BASE_COLUMNS = 18

        /** How deep a sunk Critter is held: its whole body under the ground. */
        const val UNDERGROUND_CELLS = 12
    }
}
