package local.critter.phone.overlay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.Gravity
import android.widget.FrameLayout
import androidx.compose.ui.graphics.toArgb
import local.critter.core.flock.FlockModel
import local.critter.core.overlay.Edge
import local.critter.core.protocol.BridgeSession
import local.critter.core.skin.SkinLibrary
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.CritterView
import local.critter.phone.critter.PileSlots
import local.critter.phone.ui.theme.LightCritterColors
import kotlin.math.max
import kotlin.math.min

/**
 * The collapsed floating pile (mockup "悬浮球 · 收起", design §8.4): the most urgent Critter in front, up to two
 * more dimmed behind it, standing on a soft two-layer shadow; above, a white stepped tag with a pixel icon and a
 * number per state ([pileCounts]); below, "n 个会话" on the same kind of tag. Offline it is one grey sleeping
 * Critter labelled "离线". One [CritterView] covers the whole view (the tags take no touches), so a press anywhere
 * is a press on the front Critter.
 */
class PileView(context: Context, private val unit: Int) : FrameLayout(context) {
    private val colors = context.critterColors()
    private val gap = context.px(GAP_DP)
    private val label = OverlayLook.text(context, 11.5f, 900, colors.ink.toArgb()).apply {
        background = OverlayLook.tag(context, colors)
        OverlayLook.padTag(this)
        gravity = Gravity.CENTER
    }
    private val tagHeight = OverlayLook.tagHeight(label)
    private val counts = CountsRow(context, colors, framed = true)

    /** Size in pixels; fixed for a given [unit], so the window can be positioned before it is measured. */
    val widthPx = max(EXTENT_CELLS * unit + 2 * max(context.px(4f), 2 * unit), context.px(MIN_WIDTH_DP))
    val heightPx = tagHeight + gap + (HEADROOM_CELLS + 10) * unit + unit + gap + tagHeight

    /** Where the front Critter's ground line is, in view pixels. */
    private val groundY = (tagHeight + gap + (HEADROOM_CELLS + 10) * unit).toFloat()

    /** The front Critter's left edge: the pile (its back rows included) is centered. */
    private val frontX = ((widthPx - EXTENT_CELLS * unit) / 2).toFloat()

    /** How far right the pile reaches: one Critter, or the back rows too. */
    private var reach = frontX + 18 * unit

    /** The soft shadow at the feet, the same over any app in either theme. */
    private val shadow = Paint().apply { color = LightCritterColors.ink.copy(alpha = 0.16f).toArgb() }

    val critters = CritterView(context).apply { claimAllTouches = true }

    /** The front Critter's id (the most urgent session), or null while offline or empty. */
    var leadId: String? = null
        private set

    init {
        setWillNotDraw(false)
        addView(critters, LayoutParams(widthPx, heightPx))
        addView(counts, LayoutParams(LayoutParams.WRAP_CONTENT, tagHeight, Gravity.TOP or Gravity.CENTER_HORIZONTAL))
        addView(label, LayoutParams(LayoutParams.WRAP_CONTENT, tagHeight, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
        label.maxWidth = widthPx
        label.isClickable = false
    }

    var listener: CritterTouchListener?
        get() = critters.listener
        set(value) { critters.listener = value }

    fun render(sessions: List<BridgeSession>, library: SkinLibrary, dim: Double, online: Boolean, offlineSkin: String) {
        val scale = unit.toFloat()
        if (!online || sessions.isEmpty()) {
            leadId = null
            counts.visibility = INVISIBLE
            label.text = if (online) "没有会话" else "离线"
            critters.setActors(listOf(PileSlots.offline(offlineSkin, library, dim, frontX, groundY, scale)))
            reachFor(1)
            return
        }
        leadId = FlockModel.merged(sessions).lead.id
        counts.visibility = VISIBLE
        counts.show(pileCounts(sessions), widthPx)
        label.text = "${sessions.size} 个会话"
        critters.setActors(PileSlots.build(sessions, library, dim, frontX, groundY, scale))
        reachFor(sessions.size)
    }

    /** The front Critter hops (a session just started waiting). */
    fun notice() {
        leadId?.let { critters.notice(it) }
    }

    /** Snapped to [edge]: the calm Critters look into the screen ([inwardGaze]) while nobody touches them. */
    fun faceInward(edge: Edge) {
        critters.restingGaze = inwardGaze(edge)
    }

    private fun reachFor(count: Int) {
        val r = frontX + (18 + BACK_REACH[min(count, 3) - 1]) * unit
        if (r != reach) {
            reach = r
            invalidate()
        }
    }

    /** Two layers, as on the mockup: a wide row under the feet and a narrower one behind them, 16% ink. */
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val u = unit.toFloat()
        canvas.drawRect(frontX - 2 * u, groundY, reach + 2 * u, groundY + u, shadow)
        canvas.drawRect(frontX + u, groundY - u + 1, reach - u, groundY + 1, shadow)
    }

    private companion object {
        /** The gap between the tags and the Critters. */
        const val GAP_DP = 4f

        /** Room for the tags, even when the Critters are small. */
        const val MIN_WIDTH_DP = 84f

        /** One Critter's base box and the pile's back rows. */
        const val EXTENT_CELLS = 18 + PileSlots.EXTRA_CELLS

        /** How far past the front Critter the pile reaches with one, two or three Critters, in cells. */
        val BACK_REACH = intArrayOf(0, 4, 7)

        /** Rows above the base box that the head marker and the badge can reach. */
        const val HEADROOM_CELLS = 9
    }
}
