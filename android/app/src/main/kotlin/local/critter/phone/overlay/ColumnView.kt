package local.critter.phone.overlay

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import androidx.compose.ui.graphics.toArgb
import local.critter.core.overlay.Edge
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinLibrary
import local.critter.phone.critter.CritterSlot
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.CritterView
import local.critter.phone.critter.PileSlots
import local.critter.phone.ui.board.CardRequest
import local.critter.phone.ui.doingText
import local.critter.phone.ui.look.PixelDrawable
import local.critter.phone.ui.sourceLabel
import local.critter.phone.ui.theme.state
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The expanded floating pile (mockup "悬浮球 · 展开", design §8.4): a stepped shelf along the snapped edge (the
 * surface at 94%, a 4 dp shade row at the bottom), scrollable. On top, the counts and "点宠物打开"; then one row
 * per session with the Critter on the outer side, its "name · source" under it and its bubble facing the screen
 * (an orange one with "点我回答" while it waits for you); at the bottom a small 「收起」 button. One [CritterView]
 * draws all the Critters, so it is one clock for the whole shelf.
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
    private val colors = context.critterColors()
    private val outer = context.px(6f)
    private val inner = context.px(10f)
    private val gap = context.px(6f)
    private val petW = petWidth(unit, density)
    private val headerH = headerHeight(density)

    /** One row's height in pixels: the Critter with room for its marker and hop, and the label under it. */
    val itemHeight = itemHeight(unit, density)

    val critters = CritterView(context)
    private val content = FrameLayout(context)

    /** The sessions in the order they are shown, top to bottom (the hops go in this order). */
    var sessionIds: List<String> = emptyList()
        private set

    init {
        isVerticalScrollBarEnabled = false
        overScrollMode = OVER_SCROLL_NEVER
        background = PixelDrawable(
            colors.surface.copy(alpha = 0.94f).toArgb(), context.px(5f), context.px(LIP_DP), colors.shade.toArgb(),
        )
        // The rows scroll above the shade row, not over it.
        setPadding(0, 0, 0, context.px(LIP_DP))
        clipToPadding = true
        addView(content, LayoutParams(widthPx, LayoutParams.WRAP_CONTENT))
        critters.listener = object : CritterTouchListener {
            override fun onTap(sessionId: String) = onTapSession(sessionId)
            override fun onLongDragEnd(sessionId: String) {}
        }
    }

    fun render(sessions: List<BridgeSession>, library: SkinLibrary, dim: Double, requests: Map<String, CardRequest>) {
        content.removeAllViews()
        sessionIds = sessions.map { it.id }
        addHeader(sessions)
        content.addView(critters, FrameLayout.LayoutParams(widthPx, sessions.size * itemHeight).apply { topMargin = headerH })
        val petX = if (edge == Edge.Right) widthPx - outer - petW else outer
        val critterX = petX + (petW - 18 * unit) / 2
        val slots = ArrayList<CritterSlot>(sessions.size)
        sessions.forEachIndexed { i, s ->
            val top = headerH + i * itemHeight
            slots += PileSlots.slot(s, library, dim, critterX.toFloat(), (top + GROUND_CELLS * unit).toFloat(), unit.toFloat())
            addRow(s, requests[s.id], top, petX)
        }
        critters.setActors(slots)
        content.addView(
            closeButton(),
            FrameLayout.LayoutParams(context.px(CLOSE_W_DP), context.px(CLOSE_H_DP), Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
                topMargin = headerH + sessions.size * itemHeight + context.px(CLOSE_GAP_DP)
            },
        )
        content.minimumHeight = headerH + sessions.size * itemHeight + footerHeight(density)
    }

    /** The counts on the left and "点宠物打开" on the right. */
    private fun addHeader(sessions: List<BridgeSession>) {
        val hint = OverlayLook.text(context, 11f, 800, colors.ink2.toArgb()).apply {
            text = "点宠物打开"
            gravity = Gravity.CENTER_VERTICAL
        }
        val top = context.px(HEADER_TOP_DP)
        val row = headerH - top - context.px(HEADER_BOTTOM_DP)
        hint.measure(MeasureSpec.UNSPECIFIED, MeasureSpec.UNSPECIFIED)
        val counts = CountsRow(context, colors, framed = false)
        counts.show(pileCounts(sessions), widthPx - 2 * context.px(12f) - hint.measuredWidth - gap)
        content.addView(counts, FrameLayout.LayoutParams(LayoutParams.WRAP_CONTENT, row).apply {
            leftMargin = context.px(12f)
            topMargin = top
        })
        content.addView(hint, FrameLayout.LayoutParams(LayoutParams.WRAP_CONTENT, row, Gravity.TOP or Gravity.END).apply {
            rightMargin = context.px(12f)
            topMargin = top
        })
    }

    /** One row over the shared Critter view: the bubble, centered on the row, and the label under the Critter. */
    private fun addRow(s: BridgeSession, request: CardRequest?, top: Int, petX: Int) {
        val row = FrameLayout(context)
        content.addView(row, FrameLayout.LayoutParams(widthPx, itemHeight).apply { topMargin = top })
        if (s.state != PetState.idle) {
            val side = outer + petW + gap
            val bubble = bubble(s, request, widthPx - side - inner)
            row.addView(
                bubble,
                FrameLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                    gravity = Gravity.CENTER_VERTICAL or (if (edge == Edge.Right) Gravity.END else Gravity.START)
                    if (edge == Edge.Right) rightMargin = side else leftMargin = side
                },
            )
        }
        val labelW = petW + 2 * outer
        val label = OverlayLook.text(context, 10f, 800, colors.ink2.toArgb()).apply {
            text = "${s.name} · ${sourceLabel(s.source)}"
            gravity = Gravity.CENTER
            setOnClickListener { onTapSession(s.id) }
        }
        row.addView(
            label,
            FrameLayout.LayoutParams(labelW, labelHeight(density)).apply {
                leftMargin = (petX - outer).coerceIn(0, max(0, widthPx - labelW))
                topMargin = LABEL_CELLS * unit
            },
        )
    }

    /**
     * What the session is doing on a stepped bubble ([room] wide at most, and 150 dp): surface2 with a shade row; a
     * waiting one is solid orange with what it wants and, below, "点我回答".
     */
    private fun bubble(s: BridgeSession, request: CardRequest?, room: Int): View {
        val waiting = s.state == PetState.waiting
        val ink = (if (waiting) colors.state(PetState.waiting).fg else colors.ink).toArgb()
        val box = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = PixelDrawable(
                (if (waiting) colors.wait else colors.surface2).toArgb(), context.px(3f), context.px(2f),
                (if (waiting) colors.waitDeep else colors.shade).toArgb(),
            )
            setPadding(context.px(9f), context.px(6f), context.px(9f), context.px(8f))
            setOnClickListener { onTapSession(s.id) }
        }
        val textMax = minOf(room, context.px(BUBBLE_MAX_DP)) - box.paddingLeft - box.paddingRight
        box.addView(
            OverlayLook.text(context, 12f, 700, ink).apply {
                text = if (waiting) request?.what ?: doingText(s) else doingText(s)
                maxLines = 2
                maxWidth = textMax
            },
        )
        if (waiting) {
            box.addView(
                OverlayLook.text(context, 10.5f, 900, ink).apply {
                    text = "点我回答"
                    alpha = 0.75f
                },
            )
        }
        return box
    }

    /** A small secondary pixel button: 「收起」 with the up chevron; pressed, it sinks 3 dp in one step. */
    private fun closeButton(): View {
        val up = PixelDrawable(colors.surface2.toArgb(), context.px(3f), context.px(3f), colors.shade.toArgb())
        val down = PixelDrawable(colors.surface2.toArgb(), context.px(3f), context.px(1f), colors.shade.toArgb())
        val sink = context.px(3f).toFloat()
        return object : LinearLayout(context) {
            override fun setPressed(pressed: Boolean) {
                super.setPressed(pressed)
                background = if (pressed) down else up
                translationY = if (pressed) sink else 0f
            }
        }.apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            background = up
            setPadding(0, 0, 0, context.px(3f))
            addView(ImageView(context).apply { setImageBitmap(OverlayLook.icon("chevU", colors.ink.toArgb(), context.px(2f))) })
            addView(
                OverlayLook.text(context, 13.5f, 900, colors.ink.toArgb()).apply { text = "收起" },
                LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginStart = context.px(8f) },
            )
            setOnClickListener { onCollapse() }
        }
    }

    companion object {
        private const val LIP_DP = 4f
        private const val BUBBLE_MAX_DP = 150f
        private const val HEADER_TOP_DP = 10f
        private const val HEADER_ROW_DP = 20f
        private const val HEADER_BOTTOM_DP = 6f
        private const val CLOSE_W_DP = 120f
        private const val CLOSE_H_DP = 34f
        private const val CLOSE_GAP_DP = 6f
        private const val CLOSE_BOTTOM_DP = 12f

        /** The Critter stands this many cells below the row's top (room for its marker and the hop). */
        private const val GROUND_CELLS = 19

        /** The label starts this many cells below the row's top. */
        private const val LABEL_CELLS = 21

        private fun px(dp: Float, density: Float): Int = max(1, (dp * density).roundToInt())

        private fun labelHeight(density: Float): Int = px(16f, density)

        /** The Critter's column: its base box, but at least 64 dp (the mockup's). */
        private fun petWidth(unit: Int, density: Float): Int = max(18 * unit, px(64f, density))

        private fun headerHeight(density: Float): Int = px(HEADER_TOP_DP + HEADER_ROW_DP + HEADER_BOTTOM_DP, density)

        private fun footerHeight(density: Float): Int = px(CLOSE_GAP_DP + CLOSE_H_DP + CLOSE_BOTTOM_DP, density)

        /** An item's height in pixels at [unit] pixels per cell and the given density. */
        fun itemHeight(unit: Int, density: Float): Int = LABEL_CELLS * unit + px(22f, density)

        /** The shelf's width: the inner padding, a bubble, the gap, the Critter and the outer padding. */
        fun widthFor(unit: Int, density: Float): Int = px(10f + BUBBLE_MAX_DP + 6f + 6f, density) + petWidth(unit, density)

        /** The whole shelf for [count] sessions, unscrolled: header, rows, the button and the shade row. */
        fun fullHeight(count: Int, unit: Int, density: Float): Int =
            headerHeight(density) + count * itemHeight(unit, density) + footerHeight(density) + px(LIP_DP, density)
    }
}
