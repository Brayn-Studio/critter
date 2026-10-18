package local.critter.phone.overlay

import android.app.KeyguardManager
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.core.view.WindowInsetsCompat
import local.critter.core.flock.FlockModel
import local.critter.core.logic.SessionOrder
import local.critter.core.overlay.Edge
import local.critter.core.overlay.OverlayGeometry
import local.critter.core.overlay.Rect
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SnapshotBody
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.SessionTap
import local.critter.phone.data.PhoneSettings
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
    private var hiddenForFullscreen = false
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
    ).apply { gravity = Gravity.TOP or Gravity.START }

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

    /** Whether the user can see the pile right now: shown, not hidden, screen on and unlocked. */
    val isVisible: Boolean
        get() {
            if (!attached || !contentShown()) return false
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
        topY = (settings.overlayY * screen().height).roundToInt()
        rebuild()
        windowManager.addView(root, params)
        added = true
        return true
    }

    fun hide() {
        if (!attached) return
        attached = false
        expanded = false
        pile?.critters?.setActors(emptyList())
        root.removeAllViews()
        pile = null
        column = null
        windowManager.removeView(root)
        added = false
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
        if (!attached) return
        if (resized || pile == null) rebuild() else render()
        if (newlyWaiting && !expanded) pile?.notice()
    }

    fun expand() {
        if (expanded || !attached || body == null || !online) return
        expanded = true
        rebuild()
    }

    fun collapse() {
        if (!expanded) return
        expanded = false
        rebuild()
    }

    /** The screen changed (rotation, split screen, fold): put the window back inside it. */
    fun onConfigurationChanged() {
        if (!attached) return
        place()
    }

    // ---- content ---------------------------------------------------------------------------------------

    private fun unit(): Int = (UNIT_DP[settings.overlaySize.coerceIn(1, 3) - 1] * density).roundToInt().coerceAtLeast(1)

    private fun sessions(): List<BridgeSession> = body?.let { SessionOrder.forBoard(it) }.orEmpty()

    private fun dim(): Double = settings.overlayIdleDim?.toDouble() ?: body?.prefs?.idleDim ?: 1.0

    private fun skinName(): String = body?.prefs?.skin ?: "clawd"

    /** Builds the collapsed or expanded content from scratch (a size, an edge or the mode changed). */
    private fun rebuild() {
        pile?.critters?.setActors(emptyList())
        column?.critters?.setActors(emptyList())
        root.removeAllViews()
        pile = null
        column = null
        val unit = unit()
        if (expanded) {
            val screen = screen()
            val sessions = sessions()
            val itemHeight = ColumnView.itemHeight(unit, density)
            val s = OverlayGeometry.expandedSize(sessions.size, screen, itemHeight, width = (18 * unit + 150 * density).toInt())
            val view = ColumnView(context, unit, edge, s.width, s.height, ::tapSession, ::collapse)
            column = view
            size = s.width to s.height
            root.addView(view, FrameLayout.LayoutParams(s.width, s.height))
        } else {
            val view = PileView(context, unit)
            view.listener = pileListener
            pile = view
            size = view.widthPx to view.heightPx
            root.addView(view, FrameLayout.LayoutParams(view.widthPx, view.heightPx))
        }
        render()
        place()
        applyVisibility()
    }

    private fun render() {
        val library = repo.skins.library.value
        if (expanded) {
            column?.render(sessions(), library, dim())
        } else {
            pile?.render(sessions(), library, dim(), online && body != null, skinName())
            // With nothing to show and "hide when empty" on, applyVisibility hides it.
        }
        applyVisibility()
    }

    private fun contentShown(): Boolean {
        if (hiddenForFullscreen && settings.overlayHideInFullscreen) return false
        if (settings.overlayAutoHide && online && sessions().isEmpty()) return false
        return true
    }

    /** Hidden content stays measured (so insets keep coming, to show it again) but takes no touches and no clock. */
    private fun applyVisibility() {
        if (!attached) return
        val shown = contentShown()
        root.visibility = View.VISIBLE
        for (i in 0 until root.childCount) root.getChildAt(i).visibility = if (shown) View.VISIBLE else View.INVISIBLE
        val flags = if (shown) FLAGS else FLAGS or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        if (params.flags != flags) {
            params.flags = flags
            if (added) windowManager.updateViewLayout(root, params)
        }
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

    private fun screen(): Rect {
        if (Build.VERSION.SDK_INT >= 30) {
            val b = windowManager.currentWindowMetrics.bounds
            return Rect(b.left, b.top, b.right, b.bottom)
        }
        val m = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealMetrics(m)
        return Rect(0, 0, m.widthPixels, m.heightPixels)
    }

    private fun remember() {
        val screen = screen()
        repo.settingsStore.update { it.copy(overlayOnRight = edge == Edge.Right, overlayY = topY.toFloat() / screen.height) }
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
    }
}
