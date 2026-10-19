package local.critter.phone

import local.critter.core.protocol.PetState
import local.critter.phone.ui.look.MeterLevel
import local.critter.phone.ui.look.PixelIcons
import local.critter.phone.ui.look.Wordmark
import local.critter.phone.ui.look.WordmarkCell
import local.critter.phone.ui.look.litSegments
import local.critter.phone.ui.look.meterLevel
import local.critter.phone.ui.look.pixelOutline
import local.critter.phone.ui.look.steppedFraction
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

    @Test
    fun litSegmentsRoundsAndClamps() {
        assertEquals(1, litSegments(11.0, 10))
        assertEquals(6, litSegments(62.0, 10))
        assertEquals(10, litSegments(100.0, 10))
        assertEquals(10, litSegments(140.0, 10))
        assertEquals(0, litSegments(-5.0, 10))
        assertEquals(0, litSegments(null, 20))
        assertEquals(8, litSegments(32.0, 24))
    }

    @Test
    fun meterLevelsSplitAtSixtyAndEightyFive() {
        assertEquals(MeterLevel.Calm, meterLevel(59.9))
        assertEquals(MeterLevel.Busy, meterLevel(60.0))
        assertEquals(MeterLevel.Busy, meterLevel(84.9))
        assertEquals(MeterLevel.Hot, meterLevel(85.0))
        assertEquals(MeterLevel.Calm, meterLevel(null))
    }

    @Test
    fun steppedFractionMovesInThirds() {
        assertEquals(0f, steppedFraction(0.2f, 3))
        assertEquals(1 / 3f, steppedFraction(0.5f, 3))
        assertEquals(2 / 3f, steppedFraction(0.99f, 3))
        assertEquals(1f, steppedFraction(1f, 3))
    }

    @Test
    fun wordmarkIsFortyTwoByNine() {
        val cells = Wordmark.cells()
        assertTrue(cells.all { it.x in 0..41 && it.y in 0..8 })
        assertEquals(41, cells.maxOf { it.x })
        assertEquals(8, cells.maxOf { it.y })
        val sprout = cells.filter { it.kind != WordmarkCell.Kind.Ink }
        assertTrue(sprout.all { it.y in 0..1 && it.x in 13..16 })
        assertEquals(2, sprout.count { it.kind == WordmarkCell.Kind.Leaf })
        assertEquals(2, sprout.count { it.kind == WordmarkCell.Kind.Stem })
    }
}
