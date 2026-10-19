package local.critter.core.board

import local.critter.core.motion.Pt

/**
 * Where each Critter stands on the board's Critter mode (landscape, lengths in dp). One row of at most
 * [MAX_PER_ROW] Critters, each [CELLS] cells wide with a gap of 4 cells, drawn at 5 dp per cell, or smaller
 * (4, then 3) as the row fills. More Critters than fit are not squeezed further: the last slot becomes a
 * pile, and the sessions from [Layout.pileFrom] on merge into it (it needs room for the two back rows too).
 */
object BoardLayout {
    const val MAX_PER_ROW = 6
    const val MAX_SCALE = 5f
    const val MIN_SCALE = 3f
    private const val CELLS = 18
    private const val GAP_CELLS = 4
    private const val PILE_EXTRA_CELLS = 7
    private const val MARGIN_DP = 24f

    /** The room above a Critter's ground line (bubble, marker) and below it (name, branch, context line). */
    private const val GROUND_FRACTION = 0.6f

    /**
     * [scale] is dp per cell; [slots] are the top-left of each base box's column 0 as x, and the ground
     * line as y; [pileFrom] is the index of the first session in the pile (the last slot), or null.
     */
    data class Layout(val scale: Float, val slots: List<Pt>, val pileFrom: Int?)

    fun place(count: Int, widthDp: Float, heightDp: Float): Layout {
        if (count <= 0) return Layout(MAX_SCALE, emptyList(), null)
        // How many slots fit at the smallest scale (the pile counts for its extra width).
        var capacity = MAX_PER_ROW
        while (capacity > 1 && rowWidth(capacity, MIN_SCALE, pile = count > capacity) > widthDp) capacity--
        val slotCount = minOf(count, capacity)
        val pile = count > slotCount
        var scale = MAX_SCALE
        while (scale > MIN_SCALE && (rowWidth(slotCount, scale, pile) > widthDp || scale * 28 > heightDp * 0.7f)) scale--
        val total = rowWidth(slotCount, scale, pile) - 2 * MARGIN_DP
        val x0 = (widthDp - total) / 2
        val ground = heightDp * GROUND_FRACTION
        val pitch = (CELLS + GAP_CELLS) * scale
        val slots = List(slotCount) { Pt((x0 + it * pitch).toDouble(), ground.toDouble()) }
        return Layout(scale, slots, if (pile) slotCount - 1 else null)
    }

    /**
     * One row at a fixed [scale] (dp per cell), standing on [groundDp] (the home meadow): [place]'s rule without the
     * shrinking. At most [maxPerRow] slots, as many as fit between margins of [marginDp]; when there are more
     * Critters than that, the last slot becomes the pile. The row is centred, the pile's extra width included.
     */
    fun placeRow(count: Int, widthDp: Float, groundDp: Float, scale: Float, marginDp: Float, maxPerRow: Int): Layout {
        if (count <= 0) return Layout(scale, emptyList(), null)
        var capacity = maxPerRow
        while (capacity > 1 && rowWidth(capacity, scale, pile = count > capacity, marginDp) > widthDp) capacity--
        val slotCount = minOf(count, capacity)
        val pile = count > slotCount
        val x0 = (widthDp - rowWidth(slotCount, scale, pile, margin = 0f)) / 2
        val pitch = (CELLS + GAP_CELLS) * scale
        val slots = List(slotCount) { Pt((x0 + it * pitch).toDouble(), groundDp.toDouble()) }
        return Layout(scale, slots, if (pile) slotCount - 1 else null)
    }

    private fun rowWidth(n: Int, scale: Float, pile: Boolean, margin: Float = MARGIN_DP): Float =
        ((CELLS + GAP_CELLS) * n - GAP_CELLS + (if (pile) PILE_EXTRA_CELLS else 0)) * scale + 2 * margin
}
