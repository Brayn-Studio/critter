package local.critter.core.motion

import local.critter.core.skin.ClipKey
import local.critter.core.skin.InteractionNames
import local.critter.core.skin.MotionClip
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** Hopping from one place to another (expand, collapse, scoot) — design §4.8. */
object MotionTravel {
    /** Engine-internal effect on the last key of a hop into the pile: applies the seat. */
    internal const val SEAT_EFFECT = "@seat"

    /**
     * Keys that hop from (`fromDx`, `fromDy`) cells relative to the target back to
     * (0, `toDy`): wait `delay` ticks, then 4-tick hops of at most `hopLength` cells each,
     * then land (on the ground, or raised `toDy` rows onto the back of the pile).
     * A port of the preview's `travelKeys`.
     */
    fun keys(fromDx: Int, fromDy: Int, toDy: Int, delay: Int, hopLength: Int, names: InteractionNames): MotionClip {
        val keys = mutableListOf<ClipKey>()
        if (delay > 0) keys += ClipKey(pose = names.land, ticks = delay, dx = fromDx, dy = fromDy)
        val hops = max(1, ceil(abs(fromDx).toDouble() / max(1, hopLength).toDouble()).toInt())
        val n = hops * 4
        val arc = intArrayOf(2, 3, 2, 0)
        val poses = listOf(names.hop, names.hop, names.hop, names.land)
        for (i in 1..n) {
            val p = i.toDouble() / n.toDouble()
            val j = (i - 1) % 4
            keys += ClipKey(
                pose = poses[j], ticks = 1, dx = jsRound(fromDx.toDouble() * (1 - p)),
                dy = jsRound(fromDy.toDouble() * (1 - p) + toDy.toDouble() * p) + arc[j],
            )
        }
        if (toDy > 0) {
            keys += ClipKey(pose = names.land, ticks = 1, dx = 0, dy = toDy - 1, effect = names.landDust)
            keys += ClipKey(pose = names.land, ticks = 1, dx = 0, dy = toDy, effect = SEAT_EFFECT)
        } else {
            keys += ClipKey(pose = names.land, ticks = 2, dx = 0, dy = -2, effect = names.landDust)
            keys += ClipKey(pose = names.land, ticks = 1)
            keys += ClipKey(pose = names.blinkPose, ticks = 1)
        }
        return keys
    }
}

/** Where a Critter sits in the pile: `row` cells up (and 4·row right), dimmed to `alpha`, at layer `z`. */
data class Seat(val row: Int, val alpha: Double, val z: Int)

/** Seating the flock into the pile one by one as it collapses — design §4.9. */
object PileSeating {
    /** Rows behind the lead: at most 2. */
    fun backRows(total: Int): Int = max(0, min(2, total - 1))

    /**
     * Row per id: the lead stands in front (0); the others, in departure order, take the
     * farthest back row first (nb, nb − 1, …), then all sit in row 1.
     */
    fun seats(departureOrder: List<String>, lead: String, total: Int): Map<String, Int> {
        val nb = backRows(total)
        val out = mutableMapOf(lead to 0)
        var j = 0
        for (id in departureOrder) {
            if (id == lead) continue
            out[id] = if (j < nb) nb - j else 1
            j += 1
        }
        return out
    }

    fun seat(row: Int): Seat = Seat(row = row, alpha = if (row == 2) 0.55 else 0.75, z = 2 - row)

    /**
     * Who each back row of a still pile stands for (row → id, each id at most once), from the
     * Critters behind `lead` in `order`: whoever sat there when a collapse ended
     * (`occupants`) while still behind, else whoever a collapse in `order` would seat there
     * last, else anyone not shown yet (the last in `order` first) -- so no row is left without
     * someone of its own while there are enough Critters behind.
     */
    fun shown(order: List<String>, lead: String, total: Int, occupants: Map<Int, String>): Map<Int, String> {
        val rows = backRows(total)
        if (rows <= 0) return emptyMap()
        val behind = order.filter { it != lead }
        val seated = seats(departureOrder = behind, lead = lead, total = total)
        val out = mutableMapOf<Int, String>()
        fun free(id: String) = id !in out.values
        for (row in 1..rows) {
            val id = occupants[row]
            if (id != null && id in behind && free(id)) out[row] = id
        }
        for (row in 1..rows) {
            if (out[row] != null) continue
            behind.lastOrNull { seated[it] == row && free(it) }?.let { out[row] = it }
        }
        for (row in 1..rows) {
            if (out[row] != null) continue
            behind.lastOrNull { free(it) }?.let { out[row] = it }
        }
        return out
    }
}
