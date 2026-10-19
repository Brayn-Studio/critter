package local.critter.phone

import local.critter.phone.ui.look.SkyTime
import local.critter.phone.ui.look.meadowCells
import local.critter.phone.ui.look.skyColors
import local.critter.phone.ui.look.skyTimeAt
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class SkyTest {
    @Test
    fun hoursMapToFourSkies() {
        val expected = mapOf(
            5 to SkyTime.Night, 6 to SkyTime.Dawn, 9 to SkyTime.Dawn, 10 to SkyTime.Day,
            16 to SkyTime.Day, 17 to SkyTime.Dusk, 19 to SkyTime.Dusk, 20 to SkyTime.Night,
        )
        for ((hour, sky) in expected) assertEquals(sky, skyTimeAt(hour, dark = false), "hour $hour")
        assertEquals(SkyTime.Night, skyTimeAt(12, dark = true))
    }

    @Test
    fun duskAndNightTextIsWhite() {
        assertEquals(0xFFFFFFFF, skyColors(SkyTime.Dusk).onSky)
        assertEquals(0xFFF3F0FC, skyColors(SkyTime.Night).onSky)
        assertEquals(0xFF2A2140, skyColors(SkyTime.Day).onSky)
    }

    @Test
    fun bandsSplitAtFortyTwoAndSeventyFourPercent() {
        val sky = skyColors(SkyTime.Day)
        val cells = meadowCells(360, 236, 200, 3, SkyTime.Day)
        assertTrue(cells.any { it.y == 0 && it.w == 360 && it.color == sky.top })
        assertTrue(cells.any { it.y == 84 && it.w == 360 && it.color == sky.middle })
        assertTrue(cells.any { it.y == 147 && it.w == 360 && it.color == sky.bottom })
    }

    @Test
    fun eachBandEdgeDithersOneRowEachWay() {
        val sky = skyColors(SkyTime.Day)
        val small = meadowCells(360, 236, 200, 3, SkyTime.Day).filter { it.w == 3 && it.h == 3 && it.y < 200 - 6 }
        // Below the edge at 84 every other cell keeps the top color; above it every fourth takes the middle one.
        assertEquals(60, small.count { it.y == 84 && it.color == sky.top })
        assertEquals(30, small.count { it.y == 81 && it.color == sky.middle })
        assertTrue(small.all { it.y in setOf(81, 84, 144, 147) })
    }

    @Test
    fun starsAndMoonOnlyAtNight() {
        fun hasStarColor(time: SkyTime) = meadowCells(360, 236, 200, 3, time).any { (it.color and 0xFFFFFF) == 0xFFF3C4L }
        assertTrue(!hasStarColor(SkyTime.Day))
        assertTrue(hasStarColor(SkyTime.Night))
    }

    @Test
    fun sameSeedSameMeadow() {
        assertEquals(meadowCells(360, 236, 200, 3, SkyTime.Day), meadowCells(360, 236, 200, 3, SkyTime.Day))
        assertNotEquals(meadowCells(360, 236, 200, 3, SkyTime.Day, seed = 7), meadowCells(360, 236, 200, 3, SkyTime.Day, seed = 8))
        assertNotEquals(meadowCells(360, 236, 200, 3, SkyTime.Night, seed = 7), meadowCells(360, 236, 200, 3, SkyTime.Night, seed = 8))
    }

    @Test
    fun grassStartsAtTheGround() {
        val sky = skyColors(SkyTime.Day)
        val cells = meadowCells(360, 236, 200, 3, SkyTime.Day)
        assertTrue(cells.any { it.color == sky.grass })
        assertTrue(cells.filter { it.color == sky.grass }.all { it.y >= 200 })
    }
}
