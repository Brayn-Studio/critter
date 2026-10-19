package local.critter.phone

import local.critter.core.protocol.PetState
import local.critter.phone.ui.look.PixelIcons
import local.critter.phone.ui.look.pixelOutline
import local.critter.phone.ui.stateIcon
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PixelLookTest {
    /** Twice the signed area (shoelace); positive for a clockwise outline in y-down coordinates. */
    private fun doubleArea(p: FloatArray): Float {
        var sum = 0f
        val n = p.size / 2
        for (i in 0 until n) {
            val j = (i + 1) % n
            sum += p[2 * i] * p[2 * j + 1] - p[2 * j] * p[2 * i + 1]
        }
        return sum
    }

    @Test
    fun fullOutlineHasTwentyCornersClockwise() {
        val p = pixelOutline(100f, 40f, 4f)
        assertEquals(40, p.size)
        assertEquals(listOf(0f, 8f, 4f, 8f, 4f, 4f, 8f, 4f, 8f, 0f), p.take(10))
        assertEquals(listOf(92f, 0f), p.slice(10..11))
        // Each corner cuts three step squares off the box.
        assertEquals(2 * (100f * 40f - 4 * 3 * 16f), doubleArea(p))
    }

    @Test
    fun topOnlyKeepsSquareBottom() {
        val p = pixelOutline(100f, 40f, 4f, topOnly = true)
        assertEquals(24, p.size)
        assertEquals(listOf(100f, 40f, 0f, 40f), p.takeLast(4))
        assertEquals(2 * (100f * 40f - 2 * 3 * 16f), doubleArea(p))
    }

    @Test
    fun stepIsClampedToAQuarterOfTheShortSide() {
        assertEquals(4f, pixelOutline(10f, 10f, 4f)[1])
    }

    @Test
    fun everyIconIsRectangular() {
        for ((name, rows) in PixelIcons.rows) {
            assertTrue(rows.isNotEmpty(), name)
            assertTrue(rows.all { it.length == rows[0].length }, name)
        }
        assertEquals(8, PixelIcons.rows.getValue("seed")[0].length)
        assertEquals(5 to 5, PixelIcons.rows.getValue("z").let { it[0].length to it.size })
    }

    @Test
    fun everyStateHasAnIcon() {
        for (s in PetState.entries) assertTrue(stateIcon(s) in PixelIcons.rows, s.name)
    }

    @Test
    fun runsCoverEveryPixelOnce() {
        for ((name, rows) in PixelIcons.rows) {
            val runs = PixelIcons.runs(rows)
            assertEquals(rows.sumOf { r -> r.count { it == '#' } }, runs.sumOf { it[2] }, name)
            val seen = HashSet<Pair<Int, Int>>()
            for ((x, y, length) in runs.map { it.toList() }) {
                for (cx in x until x + length) {
                    assertEquals('#', rows[y][cx], "$name ($cx, $y)")
                    assertTrue(seen.add(cx to y), "$name overlaps at ($cx, $y)")
                }
            }
        }
    }
}
