package local.critter.phone.overlay

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.PixelFormat
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.MotionEvent
import android.animation.Animator
import android.animation.ObjectAnimator
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.AccelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import androidx.core.animation.doOnEnd
import androidx.core.content.ContextCompat
import androidx.core.view.WindowInsetsCompat
import local.critter.core.flock.FlockModel
import local.critter.core.logic.SessionOrder
import local.critter.core.motion.MotionCues
import local.critter.core.overlay.Edge
import local.critter.core.overlay.OverlayGeometry
import local.critter.core.overlay.Rect
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SnapshotBody
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.MotionPrefs
import local.critter.phone.critter.SessionTap
import local.critter.phone.data.PhoneSettings
import local.critter.phone.ui.board.cardRequests
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The floating pile: one overlay window (`TYPE_APPLICATION_OVERLAY`, `WRAP_CONTENT`, not focusable, watching
 * outside touches, no screen limits) that shows a [PileView] when collapsed and a [ColumnView] when expanded.
 * Expanding and collapsing swap the content of the same window and re-position it with `updateViewLayout`.
 * The position (edge and height) is kept in the settings; after every layout change (rotation, split screen)
 * it is clamped back onto the screen. Main thread only.
 */
class OverlayController(private val context: Context, private val repo: BridgeRepository) {
    private val windowManager = context.getSystemService(WindowManager::class.java)
    private val density = context.resources.displayMetrics.density

    private var attached = false

    /** The window is on the screen (added to the window manager); until then only [params] change. */
    private var added = false
    private var expanded = false

    /** The shelf is playing its way back to the pile ([collapse]); [expanded] until it is done. */
    private var collapsing = false

    /** Where the pile's bottom is inside the shelf: the shelf grows from there and shrinks back to it. */
    private var shelfPivot = 0f
    private var hiddenForFullscreen = false

    /**
     * The board is on screen ([setBoardShown]). [hiddenForBoard] is the intent that follows from it, set at once:
     * the pile is out of sight, or on its way there while [sinkingForBoard] (the vanish is only the animation, so a
     * rebuild in the middle cannot leave a fresh pile showing over the board).
     */
    private var boardShown = false
    private var hiddenForBoard = false
    private var sinkingForBoard = false

    /** Under reduce motion, the fade that stands in for the sink ([setBoardShown]), while it runs. */
    private var boardFade: Animator? = null

    /** The night mode the content was built for; the View colors follow it. */
    private var night = context.isNight()
    private var settings = PhoneSettings()
    private var body: SnapshotBody? = null
    private var online = false

    private var pile: PileView? = null
    private var column: ColumnView? = null
    private var size = 0 to 0
    private var edge = Edge.Right
    private var topY = 0
    private var dragStartX = 0
    private var dragStartY = 0
    private var previousStates: Map<String, PetState>? = null

    private val params = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        FLAGS,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        // Placed in display coordinates, like screen(): by default the system starts the window's y under the
        // status bar (and the camera cutout in it), so the pile stood 28 dp lower than placed and a shelf at the
        // bottom ran off the screen. screen() keeps the window clear of the bars itself.
        if (Build.VERSION.SDK_INT >= 30) {
            fitInsetsTypes = 0
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
    }

    private val root = object : FrameLayout(context) {
        override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
            // A touch outside the window collapses the column (FLAG_WATCH_OUTSIDE_TOUCH).
            if (ev.action == MotionEvent.ACTION_OUTSIDE && expanded) collapse()
            return super.dispatchTouchEvent(ev)
        }
    }.apply {
        setOnApplyWindowInsetsListener { _, insets ->
            // The status bar is gone while a foreground app is immersive (a video, a game): hide, if asked to.
            val barsVisible = WindowInsetsCompat.toWindowInsetsCompat(insets).isVisible(WindowInsetsCompat.Type.statusBars())
            if (hiddenForFullscreen == barsVisible) {
                hiddenForFullscreen = !barsVisible
                applyVisibility()
            }
            insets
        }
    }

    /**
     * Whether the user can see the requests: on the pile (shown, screen on and unlocked), or on the board, which
     * stands in for a pile it hides ([requestsInSight]). Notifications wait while this holds.
     */
    val inSight: Boolean get() = requestsInSight(attached, screenInUse(), hiding())

    /**
     * Called once whenever [inSight] turns false (screen off, locked, the pile hidden or switched off, the board gone
     * with the pile out of sight): what only the pile showed gets its notification then. Main thread.
     */
    var onHidden: (() -> Unit)? = null
    private var wasInSight = false

    private fun noteSight() {
        val now = inSight
        if (wasInSight && !now) onHidden?.invoke()
        wasInSight = now
    }

    private fun screenInUse(): Boolean {
        val power = context.getSystemService(PowerManager::class.java)
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        return power.isInteractive && !keyguard.isKeyguardLocked
    }

    fun canDraw(): Boolean = Settings.canDrawOverlays(context)

    /** Adds the window; false without the "display over other apps" permission. */
    fun show(): Boolean {
        if (attached) return true
        if (!canDraw()) return false
        attached = true
        edge = if (settings.overlayOnRight) Edge.Right else Edge.Left
        topY = screen().let { it.top + (settings.overlayY * it.height).roundToInt() }
        rebuild()
        try {
            windowManager.addView(root, params)
        } catch (_: RuntimeException) {
            // The permission was revoked meanwhile, or the window token is bad: not attached, try again later.
            attached = false
            expanded = false
            root.removeAllViews()
            pile = null
            column = null
            noteSight() // the rebuild above counted it as in sight
            return false
        }
        added = true
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        ContextCompat.registerReceiver(context, screenReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        applyPaused()
        return true
    }

    fun hide() {
        if (!attached) return
        cancelAnimations()
        attached = false
        expanded = false
        collapsing = false
        runCatching { context.unregisterReceiver(screenReceiver) }
        pile?.critters?.setActors(emptyList())
        root.removeAllViews()
        pile = null
        column = null
        windowManager.removeView(root)
        added = false
        noteSight()
    }

    /** New data and settings: redraws, and makes the front Critter hop for a session that just started waiting. */
    fun update(body: SnapshotBody?, online: Boolean, settings: PhoneSettings) {
        val resized = settings.overlaySize != this.settings.overlaySize
        this.settings = settings
        val states = body?.sessions?.associate { it.id to it.state }
        val before = previousStates
        val newlyWaiting = online && before != null && states != null &&
            states.any { (id, state) -> state == PetState.waiting && before[id] != PetState.waiting }
        if (online) previousStates = states
        this.body = body
        this.online = online
        // On its way back to the pile: the pile is built from the newest data when it lands.
        if (!attached || collapsing) return
        // While expanded, only a different column size (sessions came or went) rebuilds it; otherwise the
        // column keeps its scroll position, its touch and its animations, and the actor diff does the rest.
        val rebuildNeeded = resized || if (expanded) {
            column == null || expandedSizeNow().let { it.width to it.height } != size
        } else {
            pile == null
        }
        if (rebuildNeeded) rebuild() else render()
        if (newlyWaiting && !expanded) pile?.notice()
    }

    /**
     * The pile becomes the shelf, which grows out of the pile's height (240 ms, a slight overshoot) while the
     * Critters hop one after the other from the top (design §7); a 150 ms fade under reduce motion.
     */
    fun expand() {
        if (expanded || !attached || body == null || !online || hiddenForBoard) return
        val pileTop = params.y
        val pileHeight = size.second
        expanded = true
        rebuild()
        val view = column ?: return
        shelfPivot = (pileTop - params.y + pileHeight).coerceIn(0, view.heightPx).toFloat()
        if (reduceMotion()) {
            view.alpha = 0f
            view.animate().alpha(1f).setDuration(FADE_MS).start()
            return
        }
        view.pivotY = shelfPivot
        view.scaleY = SHELF_FOLDED
        view.animate().scaleY(1f).setDuration(EXPAND_MS).setInterpolator(OvershootInterpolator(1.2f)).start()
        view.sessionIds.forEachIndexed { i, id -> view.critters.hop(id, i * HOP_STAGGER_MS) }
    }

    /**
     * Back to the pile: the Critters hop from the bottom up, the shelf shrinks to the pile's height (200 ms), the
     * pile takes its place and its lead hops as it lands (design §7); a 150 ms fade under reduce motion.
     */
    fun collapse() {
        if (!expanded || collapsing) return
        val view = column ?: return collapseNow()
        collapsing = true
        if (reduceMotion()) {
            view.animate().alpha(0f).setDuration(FADE_MS).withEndAction { if (column === view) landPile(fadeIn = true) }.start()
            return
        }
        val ids = view.sessionIds.asReversed()
        ids.forEachIndexed { i, id -> view.critters.hop(id, i * HOP_STAGGER_MS) }
        view.pivotY = shelfPivot
        view.animate()
            .setStartDelay((ids.size - 1).coerceAtLeast(0) * HOP_STAGGER_MS + hopMs())
            .scaleY(SHELF_FOLDED)
            .setDuration(COLLAPSE_MS)
            .setInterpolator(AccelerateInterpolator())
            .withEndAction { if (column === view) landPile(fadeIn = false) }
            .start()
    }

    /** Straight back to the pile without the animation (the board came up). */
    private fun collapseNow() {
        if (!expanded) return
        cancelAnimations()
        collapsing = false
        expanded = false
        rebuild()
    }

    /** The end of [collapse]: the pile is back, fading in or with its lead hopping. */
    private fun landPile(fadeIn: Boolean) {
        collapsing = false
        expanded = false
        rebuild()
        val p = pile ?: return
        if (fadeIn) {
            p.alpha = 0f
            p.animate().alpha(1f).setDuration(FADE_MS).start()
        } else {
            p.leadId?.let { p.critters.hop(it) }
        }
    }

    /**
     * The board came up ([shown]) or went: the pile sinks into the ground (`vanish`) and then hides, or shows again
     * and comes up out of it (`appear`); a 150 ms fade under reduce motion. Collapses first, without the animation.
     * While the user has the pile off, nothing moves; the pile only starts hidden if it is switched on while the
     * board is up.
     */
    fun setBoardShown(shown: Boolean) {
        if (shown == boardShown) return
        boardShown = shown
        hiddenForBoard = shown
        sinkingForBoard = false
        boardFade?.cancel()
        if (!attached) return
        if (shown) {
            collapseNow()
            val p = pile
            if (p != null && params.alpha == 1f && reduceMotion()) {
                // Still on screen while it fades, like the sink, so a snapshot or the board's immersive insets
                // meanwhile do not cut it short. Its end hides it; a rebuild (cancelAnimations) or the board going
                // again (above) calls it off, which ends it there.
                sinkingForBoard = true
                boardFade = ObjectAnimator.ofFloat(p, View.ALPHA, p.alpha, 0f).setDuration(FADE_MS).apply {
                    doOnEnd {
                        boardFade = null
                        sinkingForBoard = false
                        applyVisibility()
                        p.alpha = 1f
                    }
                    start()
                }
                return
            }
            val critters = p?.critters
            if (critters != null) {
                // Still on screen while it sinks; a rebuild meanwhile ends the sink (its Critters go) and the new
                // pile starts hidden.
                sinkingForBoard = true
                critters.sinkAll {
                    sinkingForBoard = false
                    applyVisibility()
                }
            }
            applyVisibility()
        } else {
            val wasHidden = params.alpha == 0f
            applyVisibility()
            val p = pile ?: return
            p.critters.riseAll()
            // Under reduce motion the Critters are up at once and the pile fades in.
            if (wasHidden && params.alpha == 1f && reduceMotion()) {
                p.alpha = 0f
                p.animate().alpha(1f).setDuration(FADE_MS).start()
            }
        }
    }

    /** The screen changed (rotation, split screen, fold, dark mode): put the window back inside it, in the right colors. */
    fun onConfigurationChanged() {
        if (!attached) return
        val nowNight = context.isNight()
        if (nowNight != night) {
            night = nowNight
            if (collapsing) collapseNow() else rebuild()
        } else {
            place()
        }
    }

    /**
     * How long one hop lasts ([MotionCues.hopMs]): the shelf folds once the last one has landed. The skins on screen
     * share one tick (the library only lets skins on the same tick join), so the first session's skin speaks for all.
     */
    private fun hopMs(): Long = MotionCues.hopMs(repo.skins.library.value.manifest(sessions().firstOrNull()?.skin ?: skinName()))

    /** Reduce motion: the settings switch or the system's animation scale at 0. */
    private fun reduceMotion(): Boolean =
        MotionPrefs.manual || Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

    private fun cancelAnimations() {
        boardFade?.cancel()
        pile?.animate()?.cancel()
        column?.animate()?.cancel()
    }

    // ---- content ---------------------------------------------------------------------------------------

    private fun unit(): Int = (UNIT_DP[settings.overlaySize.coerceIn(1, 3) - 1] * density).roundToInt().coerceAtLeast(1)

    private fun sessions(): List<BridgeSession> = body?.let { SessionOrder.forBoard(it) }.orEmpty()

    private fun dim(): Double = settings.overlayIdleDim?.toDouble() ?: body?.prefs?.idleDim ?: 1.0

    private fun skinName(): String = body?.prefs?.skin ?: "clawd"

    /** Builds the collapsed or expanded content from scratch (a size, an edge or the mode changed). */
    private fun rebuild() {
        // A transition in progress belongs to the views about to go.
        cancelAnimations()
        collapsing = false
        pile?.critters?.setActors(emptyList())
        column?.critters?.setActors(emptyList())
        root.removeAllViews()
        pile = null
        column = null
        val unit = unit()
        if (expanded) {
            val s = expandedSizeNow()
            val view = ColumnView(context, unit, edge, s.width, s.height, ::tapSession, ::collapse)
            column = view
            size = s.width to s.height
            root.addView(view, FrameLayout.LayoutParams(s.width, s.height))
        } else {
            val view = PileView(context, unit)
            view.listener = pileListener
            view.faceInward(edge)
            pile = view
            size = view.widthPx to view.heightPx
            root.addView(view, FrameLayout.LayoutParams(view.widthPx, view.heightPx))
        }
        render()
        place()
        applyVisibility()
        applyPaused()
    }

    /**
     * The shelf's size: all of it (header, rows, button) when it fits, otherwise the geometry's cap and it scrolls.
     * Two extra rows in the geometry's count cover the header and the button, so only its cap can be smaller.
     */
    private fun expandedSizeNow(): local.critter.core.overlay.Size {
        val unit = unit()
        val count = sessions().size
        val capped = OverlayGeometry.expandedSize(
            count + 2, screen(), ColumnView.itemHeight(unit, density), width = ColumnView.widthFor(unit, density),
        )
        return local.critter.core.overlay.Size(capped.width, min(capped.height, ColumnView.fullHeight(count, unit, density)))
    }

    /** The clock of every critter view stops while the screen is off or locked (an overlay gets no visibility event). */
    private fun applyPaused() {
        val power = context.getSystemService(PowerManager::class.java)
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        val paused = !power.isInteractive || keyguard.isKeyguardLocked
        pile?.critters?.setPaused(paused)
        column?.critters?.setPaused(paused)
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // SCREEN_OFF arrives while the keyguard still reports itself as not locked; it is paused either way.
            if (intent.action == Intent.ACTION_SCREEN_OFF) {
                pile?.critters?.setPaused(true)
                column?.critters?.setPaused(true)
            } else {
                applyPaused()
            }
            noteSight()
        }
    }

    private fun render() {
        val library = repo.skins.library.value
        if (expanded) {
            column?.render(sessions(), library, dim(), cardRequests(body))
        } else {
            pile?.render(sessions(), library, dim(), online && body != null, skinName())
            // With nothing to show and "hide when empty" on, applyVisibility hides it.
        }
        applyVisibility()
    }

    private fun hiding() = PileHiding(
        boardUp = hiddenForBoard,
        sinkingForBoard = sinkingForBoard,
        fullscreen = hiddenForFullscreen && settings.overlayHideInFullscreen,
        emptyAndAutoHide = settings.overlayAutoHide && online && sessions().isEmpty(),
    )

    private fun contentShown(): Boolean = hiding().shown

    /**
     * Hidden content stays measured (so insets keep coming, to show it again) but takes no touches and no clock.
     * The hidden window is also fully transparent: Android 12+ blocks touches that pass through an untrusted
     * FLAG_NOT_TOUCHABLE overlay unless it is (nearly) see-through, so at alpha 1 it would still eat the touches
     * meant for the app below.
     */
    private fun applyVisibility() {
        if (!attached) return
        val shown = contentShown()
        root.visibility = View.VISIBLE
        for (i in 0 until root.childCount) root.getChildAt(i).visibility = if (shown) View.VISIBLE else View.INVISIBLE
        val flags = if (shown) FLAGS else FLAGS or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        val alpha = if (shown) 1f else 0f
        if (params.flags != flags || params.alpha != alpha) {
            params.flags = flags
            params.alpha = alpha
            if (added) windowManager.updateViewLayout(root, params)
        }
        noteSight()
    }

    // ---- position --------------------------------------------------------------------------------------

    /** The window is flush with its edge, its top clamped onto the screen; collapsed, the position is remembered. */
    private fun place() {
        val screen = screen()
        val (w, h) = size
        params.x = OverlayGeometry.xFor(edge, w, screen)
        params.y = OverlayGeometry.clampY(topY, h, screen)
        if (added) windowManager.updateViewLayout(root, params)
    }

    /** Where the window may go, in display coordinates: the screen, clear of the status and navigation bars. */
    private fun screen(): Rect {
        if (Build.VERSION.SDK_INT >= 30) {
            val metrics = windowManager.currentWindowMetrics
            val b = metrics.bounds
            val bars = metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            return Rect(b.left + bars.left, b.top + bars.top, b.right - bars.right, b.bottom - bars.bottom)
        }
        val m = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealMetrics(m)
        return Rect(0, 0, m.widthPixels, m.heightPixels)
    }

    private fun remember() {
        val screen = screen()
        repo.settingsStore.update { it.copy(overlayOnRight = edge == Edge.Right, overlayY = (topY - screen.top).toFloat() / screen.height) }
    }

    // ---- touch -----------------------------------------------------------------------------------------

    private fun tapSession(id: String) {
        collapse()
        SessionTap.handle(context, repo, id)
    }

    private val pileListener = object : CritterTouchListener {
        override fun onTap(sessionId: String) {
            // Offline there is nothing to open.
            if (online && body != null) expand()
        }

        override fun onDragStart(sessionId: String) {
            dragStartX = params.x
            dragStartY = params.y
        }

        override fun onDragBy(dxPx: Float, dyPx: Float) {
            params.x = dragStartX + dxPx.roundToInt()
            params.y = dragStartY + dyPx.roundToInt()
            if (added) windowManager.updateViewLayout(root, params)
        }

        override fun onLongDragEnd(sessionId: String) {
            val (w, h) = size
            val placement = OverlayGeometry.snap(params.x, params.y, w, h, screen())
            edge = placement.edge
            topY = placement.y
            // Snapped to the other side, maybe: the calm Critters look into the screen from there.
            pile?.faceInward(edge)
            place()
            remember()
        }
    }

    private companion object {
        const val FLAGS = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS

        /** dp per cell for small, medium, large. */
        val UNIT_DP = floatArrayOf(2f, 3f, 4f)

        // The shelf's transitions (design §7).
        const val EXPAND_MS = 240L
        const val COLLAPSE_MS = 200L
        const val FADE_MS = 150L
        const val HOP_STAGGER_MS = 55L

        /** The shelf's height while folded, as a share of its own. */
        const val SHELF_FOLDED = 0.3f
    }
}
