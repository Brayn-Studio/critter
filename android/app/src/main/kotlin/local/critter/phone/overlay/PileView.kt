package local.critter.phone.overlay

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.ui.graphics.toArgb
import local.critter.core.flock.FlockModel
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinLibrary
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.CritterView
import local.critter.phone.critter.PileSlots
import local.critter.phone.ui.stateColor

/**
 * The collapsed floating pile (mockup "收起"): the most urgent Critter in front, up to two more dimmed behind
 * it, the counts per state above (`?n`, `✓n`, `!n`) and "N 个会话" below. A single session is just that one.
 * Offline it is one grey sleeping Critter labelled "离线". One [CritterView] covers the whole view (the
 * counts and the label do not take touches), so a press anywhere is a press on the front Critter.
 */
class PileView(context: Context, private val unit: Int) : FrameLayout(context) {
    private val density = resources.displayMetrics.density
    private val chipsHeight = (CHIPS_DP * density).toInt()
    private val labelHeight = (LABEL_DP * density).toInt()
    private val pad = (PAD_DP * density).toInt()

    /** Size in pixels; fixed for a given [unit], so the window can be positioned before it is measured. */
    val widthPx = (18 + PileSlots.EXTRA_CELLS) * unit + 2 * pad
    val heightPx = chipsHeight + HEADROOM_CELLS * unit + 10 * unit + 3 * unit + labelHeight

    /** Where the front Critter's ground line is, in view pixels. */
    private val groundY = (chipsHeight + (HEADROOM_CELLS + 10) * unit).toFloat()

    val critters = CritterView(context).apply { claimAllTouches = true }
    private val chips = LinearLayout(context).apply { gravity = Gravity.CENTER; orientation = LinearLayout.HORIZONTAL }
    private val label = TextView(context).apply {
        textSize = 10f
        setTextColor(Color.WHITE)
        gravity = Gravity.CENTER
        setPadding((6 * density).toInt(), 0, (6 * density).toInt(), 0)
        background = GradientDrawable().apply { setColor(0x99000000.toInt()); cornerRadius = 8 * density }
    }

    /** The front Critter's id (the most urgent session), or null while offline or empty. */
    var leadId: String? = null
        private set

    init {
        addView(critters, LayoutParams(widthPx, heightPx))
        addView(chips, LayoutParams(widthPx, chipsHeight, Gravity.TOP))
        addView(label, LayoutParams(LayoutParams.WRAP_CONTENT, labelHeight, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
        chips.isClickable = false
        label.isClickable = false
    }

    var listener: CritterTouchListener?
        get() = critters.listener
        set(value) { critters.listener = value }

    fun render(sessions: List<BridgeSession>, library: SkinLibrary, dim: Double, online: Boolean, offlineSkin: String) {
        val x = pad.toFloat()
        val scale = unit.toFloat()
        chips.removeAllViews()
        if (!online || sessions.isEmpty()) {
            leadId = null
            label.text = if (online) "没有会话" else "离线"
            critters.setActors(listOf(PileSlots.offline(offlineSkin, library, dim, x, groundY, scale)))
            return
        }
        val merged = FlockModel.merged(sessions)
        leadId = merged.lead.id
        label.text = "${sessions.size} 个会话"
        if (sessions.size > 1) {
            for (c in merged.counts) {
                val glyph = when (c.state) {
                    PetState.waiting -> "?"
                    PetState.done -> "✓"
                    PetState.error -> "!"
                    else -> continue
                }
                chips.addView(chip("$glyph${c.count}", stateColor(c.state).toArgb()))
            }
        }
        critters.setActors(PileSlots.build(sessions, library, dim, x, groundY, scale))
    }

    /** The front Critter hops (a session just started waiting). */
    fun notice() {
        leadId?.let { critters.notice(it) }
    }

    private fun chip(text: String, color: Int) = TextView(context).apply {
        this.text = text
        textSize = 10f
        typeface = Typeface.DEFAULT_BOLD
        setTextColor(Color.BLACK)
        setPadding((5 * density).toInt(), 0, (5 * density).toInt(), 0)
        background = GradientDrawable().apply { setColor(color); cornerRadius = 8 * density }
        layoutParams = LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, (14 * density).toInt()).apply {
            marginStart = (2 * density).toInt()
            marginEnd = (2 * density).toInt()
        }
        gravity = Gravity.CENTER
        visibility = View.VISIBLE
    }

    private companion object {
        const val CHIPS_DP = 18
        const val LABEL_DP = 16
        const val PAD_DP = 4
        /** Rows above the base box that the head marker and the badge can reach. */
        const val HEADROOM_CELLS = 9
    }
}
