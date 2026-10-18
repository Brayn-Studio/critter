package local.critter.core.board

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BoardLayoutTest {
    private fun assertInside(layout: BoardLayout.Layout, w: Float, h: Float) {
        for ((i, p) in layout.slots.withIndex()) {
            val cells = if (i == layout.pileFrom) 25 else 18 // the pile's back rows reach 7 cells further
            assertTrue(p.x >= 0 && p.x + cells * layout.scale <= w, "slot x=${p.x} scale=${layout.scale} outside width $w")
            assertTrue(p.y >= 0.0 && p.y <= h, "ground y=${p.y} outside height $h")
        }
    }

    @Test fun zeroSessionsHaveNoSlots() {
        val l = BoardLayout.place(0, 740f, 360f)
        assertEquals(0, l.slots.size)
        assertNull(l.pileFrom)
    }

    @Test fun oneSessionIsBigAndCentred() {
        val l = BoardLayout.place(1, 740f, 360f)
        assertEquals(1, l.slots.size)
        assertEquals(5f, l.scale)
        assertNull(l.pileFrom)
        assertInside(l, 740f, 360f)
        assertEquals(740.0 / 2, l.slots[0].x + 9 * l.scale, 0.5)
    }

    @Test fun sixSessionsFitWithoutAPile() {
        for (w in listOf(740f, 800f, 915f)) {
            val l = BoardLayout.place(6, w, 360f)
            assertEquals(6, l.slots.size)
            assertNull(l.pileFrom)
            assertTrue(l.scale in 3f..5f)
            assertInside(l, w, 360f)
        }
    }

    @Test fun sevenSessionsMergeFromTheSixthSlot() {
        val l = BoardLayout.place(7, 800f, 360f)
        assertEquals(6, l.slots.size)
        assertEquals(5, l.pileFrom)
        assertInside(l, 800f, 360f)
    }

    @Test fun twelveSessionsStayInside() {
        val l = BoardLayout.place(12, 800f, 360f)
        assertEquals(6, l.slots.size)
        assertEquals(5, l.pileFrom)
        assertInside(l, 800f, 360f)
    }

    @Test fun aNarrowScreenPilesEarlierInsteadOfOverflowing() {
        val l = BoardLayout.place(6, 300f, 360f)
        assertTrue(l.slots.size < 6)
        assertEquals(l.slots.size - 1, l.pileFrom)
        assertInside(l, 300f, 360f)
    }

    @Test fun scaleShrinksFromFiveToThreeAsTheRowFills() {
        val few = BoardLayout.place(2, 800f, 360f).scale
        val many = BoardLayout.place(6, 800f, 360f).scale
        assertTrue(few >= many)
        assertEquals(3f, BoardLayout.place(6, 450f, 360f).scale)
    }
}
