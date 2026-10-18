package local.critter.core.overlay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class OverlayGeometryTest {
    private val portrait = Rect(0, 0, 1080, 2400)
    private val landscape = Rect(0, 0, 2400, 1080)

    @Test fun snapsToTheNearerEdge() {
        assertEquals(Placement(Edge.Left, 500), OverlayGeometry.snap(100, 500, 200, 240, portrait))
        assertEquals(Placement(Edge.Right, 500), OverlayGeometry.snap(700, 500, 200, 240, portrait))
        // Exactly in the middle goes right.
        assertEquals(Edge.Right, OverlayGeometry.snap(440, 500, 200, 240, portrait).edge)
    }

    @Test fun clampsAWindowDraggedOffScreen() {
        assertEquals(Placement(Edge.Left, 0), OverlayGeometry.snap(-300, -400, 200, 240, portrait))
        assertEquals(Placement(Edge.Right, 2400 - 240), OverlayGeometry.snap(2000, 5000, 200, 240, portrait))
    }

    @Test fun clampsAfterRotation() {
        // Resting low on the right edge of a portrait screen; the screen turns to landscape (only 1080 tall).
        val before = OverlayGeometry.snap(880, 2100, 200, 240, portrait)
        assertEquals(Placement(Edge.Right, 2100), before)
        // The controller keeps the edge (not the old x) and clamps the top back into the new screen.
        val x = OverlayGeometry.xFor(before.edge, 200, landscape)
        val y = OverlayGeometry.clampY(before.y, 240, landscape)
        assertEquals(2200, x)
        assertEquals(1080 - 240, y)
        assertEquals(Placement(Edge.Right, 840), OverlayGeometry.snap(x, y, 200, 240, landscape))
    }

    @Test fun xIsFlushWithTheEdge() {
        assertEquals(0, OverlayGeometry.xFor(Edge.Left, 200, portrait))
        assertEquals(880, OverlayGeometry.xFor(Edge.Right, 200, portrait))
    }

    @Test fun expandedHeightIsCappedAtSeventyPercentForTwelveSessions() {
        val size = OverlayGeometry.expandedSize(12, portrait, itemHeight = 240)
        assertEquals((2400 * 0.7).toInt(), size.height)
        assertTrue(size.width <= (1080 * 0.75).toInt())
    }

    @Test fun fewSessionsAreNotStretched() {
        val size = OverlayGeometry.expandedSize(2, portrait, itemHeight = 240)
        assertEquals(3 * 240, size.height) // two sessions and the collapse handle
        assertEquals(240, OverlayGeometry.expandedSize(0, portrait, itemHeight = 240).height)
    }

    @Test fun aShortScreenStillShowsAtLeastOneRow() {
        val size = OverlayGeometry.expandedSize(12, Rect(0, 0, 1000, 200), itemHeight = 240)
        assertEquals(240, size.height)
    }
}
