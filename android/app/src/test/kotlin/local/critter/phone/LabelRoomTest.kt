package local.critter.phone

import local.critter.phone.ui.look.labelRoom
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LabelRoomTest {
    private val gap = 4f
    private val edge = 4f

    private fun rooms(centers: List<Float>, natural: List<Float>, width: Float, taken: (Int) -> Boolean = { true }) =
        centers.indices.map { labelRoom(centers, natural, it, width, gap, edge, taken) }

    /** Each label as drawn: centred, its natural width cut to its room. */
    private fun spans(centers: List<Float>, natural: List<Float>, rooms: List<Float>) =
        centers.indices.map { val w = minOf(natural[it], rooms[it]); centers[it] - w / 2 to centers[it] + w / 2 }

    private fun assertApart(spans: List<Pair<Float, Float>>, width: Float) {
        for (k in 1 until spans.size) {
            assertTrue(spans[k].first - spans[k - 1].second >= gap - 0.001f, "labels ${k - 1} and $k overlap: $spans")
        }
        assertTrue(spans.first().first >= edge - 0.001f && spans.last().second <= width - edge + 0.001f, "past an edge: $spans")
    }

    /** Two short neighbours each leave the other more than half the space between them. */
    @Test fun twoShortNeighboursShareTheSpace() {
        val centers = listOf(100f, 200f)
        val natural = listOf(40f, 40f)
        val r = rooms(centers, natural, 300f)
        // 96 dp between them less the other's 20 dp half, on both sides: 2 × 76.
        assertEquals(listOf(152f, 152f), r)
        assertApart(spans(centers, natural, r), 300f)
    }

    /** A long name between two short ones takes what they leave, and is cut short there; theirs stay whole. */
    @Test fun aLongNameBetweenShortOnesTakesWhatTheyLeave() {
        val centers = listOf(60f, 150f, 240f)
        val natural = listOf(30f, 300f, 30f)
        val r = rooms(centers, natural, 300f)
        // 86 dp to each neighbour, less its 15 dp half: 2 × 71.
        assertEquals(142f, r[1])
        // The short ones get only half the space towards the long one, which is still all they need.
        assertEquals(86f, r[0])
        assertEquals(86f, r[2])
        val s = spans(centers, natural, r)
        assertEquals(30f, s[0].second - s[0].first)
        assertEquals(142f, s[1].second - s[1].first)
        assertApart(s, 300f)
    }

    /** With no neighbour a label reaches 4 dp from the meadow's sides, from its centre: near a side it is narrow. */
    @Test fun theEdgesOfTheMeadow() {
        assertEquals(292f, rooms(listOf(150f), listOf(400f), 300f)[0])
        val centers = listOf(30f, 270f)
        val natural = listOf(200f, 200f)
        val r = rooms(centers, natural, 300f)
        assertEquals(listOf(52f, 52f), r)
        assertApart(spans(centers, natural, r), 300f)
        // A centre closer to the side than the edge leaves no room at all, rather than a negative one.
        assertEquals(0f, rooms(listOf(2f), listOf(50f), 300f)[0])
    }

    /** A neighbour with nothing at this height (no bubble) does not count: the next one, or the side, does. */
    @Test fun onlyNeighboursWithALabelAtThatHeightCount() {
        val centers = listOf(60f, 150f, 240f)
        val natural = listOf(200f, Float.MAX_VALUE, 200f)
        val r = rooms(centers, natural, 300f) { it != 1 }
        // Slot 0 looks past slot 1 to slot 2: 176 dp less half of it (88), against 56 dp to the side.
        assertEquals(112f, r[0])
        assertEquals(112f, r[2])
    }
}
