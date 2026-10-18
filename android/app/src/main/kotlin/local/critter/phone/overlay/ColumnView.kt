package local.critter.phone.overlay

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.compose.ui.graphics.toArgb
import local.critter.core.overlay.Edge
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinLibrary
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.CritterView
import local.critter.phone.critter.PileSlots
import local.critter.phone.ui.doingText
import local.critter.phone.ui.sourceLabel
import local.critter.phone.ui.stateColor

/**
 * The expanded floating pile (mockup "2 · B"): one column along the snapped edge, scrollable. Each item is a
 * bubble (on the side facing the screen), the Critter and a label (name · source); the last row is the
 * "收起" handle. One [CritterView] draws all the Critters, so it is one clock for the whole column.
 */
class ColumnView(
    context: Context,
    private val unit: Int,
    private val edge: Edge,
    val widthPx: Int,
    val heightPx: Int,
    private val onTapSession: (String) -> Unit,
    private val onCollapse: () -> Unit,
) : ScrollView(context) {
    private val density = resources.displayMetrics.density
    private val pad = (6 * density).toInt()
    private val labelHeight = (16 * density).toInt()

    /** One item's height in pixels: the Critter with room for its marker, and the label under it. */
    val itemHeight = itemHeight(unit, density)

    val critters = CritterView(context)
    private val content = FrameLayout(context)

    init {
        isVerticalScrollBarEnabled = false
        overScrollMode = OVER_SCROLL_NEVER
        background = GradientDrawable().apply { setColor(0xB3101012.toInt()); cornerRadius = 14 * density }
        addView(content, LayoutParams(widthPx, LayoutParams.WRAP_CONTENT))
        critters.listener = object : CritterTouchListener {
            override fun onTap(sessionId: String) = onTapSession(sessionId)
            override fun onLongDragEnd(sessionId: String) {}
        }
    }

    fun render(sessions: List<BridgeSession>, library: SkinLibrary, dim: Double) {
        content.removeAllViews()
        val total = (sessions.size + 1) * itemHeight // the handle is the last row
        content.addView(critters, FrameLayout.LayoutParams(widthPx, sessions.size * itemHeight))
        val critterW = 18 * unit
        val critterX = if (edge == Edge.Right) widthPx - pad - critterW else pad
        val slots = ArrayList<local.critter.phone.critter.CritterSlot>(sessions.size)
        sessions.forEachIndexed { i, s ->
            val top = i * itemHeight
            val ground = top + 19 * unit
            slots += PileSlots.slot(s, library, dim, critterX.toFloat(), ground.toFloat(), unit.toFloat())
            if (s.state != PetState.idle) addBubble(s, top, critterX, critterW)
            addLabel(s, top + 21 * unit)
        }
        critters.setActors(slots)
        content.addView(
            handle(),
            FrameLayout.LayoutParams(widthPx, itemHeight).apply { topMargin = sessions.size * itemHeight },
        )
        content.minimumHeight = total
    }

    private fun addBubble(s: BridgeSession, top: Int, critterX: Int, critterW: Int) {
        val color = stateColor(s.state).toArgb()
        val title = when (s.state) {
            PetState.waiting -> "需要确认"
            PetState.done -> "做完了"
            PetState.error -> "出错"
            else -> null
        }
        val doing = doingText(s)
        val bubble = TextView(context).apply {
            text = if (title != null && doing != title) "$title\n$doing" else doing
            textSize = 11f
            setTextColor(Color.WHITE)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setPadding((8 * density).toInt(), (4 * density).toInt(), (8 * density).toInt(), (4 * density).toInt())
            background = GradientDrawable().apply { setColor((color and 0x00FFFFFF) or 0x40000000); cornerRadius = 10 * density }
            setOnClickListener { onTapSession(s.id) }
        }
        val gap = (6 * density).toInt()
        val bubbleW = widthPx - 2 * pad - critterW - gap
        val x = if (edge == Edge.Right) pad else critterX + critterW + gap
        content.addView(
            bubble,
            FrameLayout.LayoutParams(bubbleW, FrameLayout.LayoutParams.WRAP_CONTENT).apply {
                leftMargin = x
                topMargin = top + 4 * unit
            },
        )
    }

    private fun addLabel(s: BridgeSession, top: Int) {
        val label = TextView(context).apply {
            text = "${s.name} · ${sourceLabel(s.source)}"
            textSize = 10f
            setTextColor(0xFFC7C7CC.toInt())
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            gravity = (if (edge == Edge.Right) Gravity.END else Gravity.START) or Gravity.CENTER_VERTICAL
            setOnClickListener { onTapSession(s.id) }
        }
        content.addView(
            label,
            FrameLayout.LayoutParams(widthPx - 2 * pad, labelHeight).apply {
                leftMargin = pad
                topMargin = top
            },
        )
    }

    private fun handle() = TextView(context).apply {
        text = if (edge == Edge.Right) "⇡ 收起" else "收起 ⇡"
        textSize = 12f
        setTextColor(0xFFAEAEB2.toInt())
        gravity = Gravity.CENTER
        setOnClickListener { onCollapse() }
    }

    companion object {
        /** An item's height in pixels at [unit] pixels per cell and the given density. */
        fun itemHeight(unit: Int, density: Float): Int = 21 * unit + (22 * density).toInt()
    }
}
