package local.critter.core.skin

import local.critter.core.builtin
import local.critter.core.bundledSkinJson
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotSame
import kotlin.test.assertSame

/**
 * A new library is built whenever a skin arrives from the Mac (or the clock or forced skin changes). The screens
 * rebuild a Critter whose manifest is another object, so a manifest whose source has not changed must be the same
 * object in the new library.
 */
class SkinLibraryTest {
    private val reader = { path: String ->
        path.takeIf { it.startsWith("skins/") }?.let { runCatching { bundledSkinJson(it.split('/')[1]) }.getOrNull() }
    }

    private fun json(m: SkinManifest) = SkinJson.encodeToString(SkinManifest.serializer(), m)
    private val custom = json(builtin().copy(name = "custom"))
    private val newcomer = json(builtin().copy(name = "newcomer"))

    @Test
    fun rebuiltLibraryKeepsUnchangedManifests() {
        val lib1 = SkinLibrary(reader, pushed = mapOf("custom" to custom), clockSkin = "sprig")
        val sprig = lib1.manifest("sprig")
        val pushed = lib1.manifest("custom")

        val lib2 = SkinLibrary(reader, pushed = mapOf("custom" to custom, "newcomer" to newcomer), clockSkin = "sprig", reuse = lib1)
        assertSame(sprig, lib2.manifest("sprig"), "bundled, unchanged")
        assertSame(pushed, lib2.manifest("custom"), "pushed before, same JSON")
        assertEquals("newcomer", lib2.manifest("newcomer").name)

        // Taken over again by the library after that, even what lib2 itself only decoded.
        val lib3 = SkinLibrary(reader, pushed = mapOf("custom" to custom, "newcomer" to newcomer), clockSkin = "sprig", reuse = lib2)
        assertSame(sprig, lib3.manifest("sprig"))
        assertSame(lib2.manifest("newcomer"), lib3.manifest("newcomer"))
    }

    @Test
    fun aChangedPushedManifestIsANewObject() {
        val lib1 = SkinLibrary(reader, pushed = mapOf("custom" to custom))
        val before = lib1.manifest("custom")
        val changed = json(builtin().copy(name = "custom", title = "新的"))
        val lib2 = SkinLibrary(reader, pushed = mapOf("custom" to changed), reuse = lib1)
        assertNotSame(before, lib2.manifest("custom"))
        assertEquals("新的", lib2.manifest("custom").title)
    }

    /** A new clock skin on another tick: the row's skins are drawn as it now, not as they were. */
    @Test
    fun aNewClockSkinIsNotTakenOver() {
        val slow = json(builtin().copy(name = "slow", tickMs = 100))
        val lib1 = SkinLibrary(reader, pushed = mapOf("slow" to slow), clockSkin = "sprig")
        val sprig = lib1.manifest("sprig")
        val lib2 = SkinLibrary(reader, pushed = mapOf("slow" to slow), clockSkin = "slow", reuse = lib1)
        assertNotSame(sprig, lib2.manifest("sprig"))
        assertEquals("slow", lib2.manifest("sprig").name)
        // Back on the 60 ms clock, sprig is the very manifest it was.
        val lib3 = SkinLibrary(reader, pushed = mapOf("slow" to slow), clockSkin = "mochi", reuse = lib2)
        assertSame(sprig, lib3.manifest("sprig"))
    }
}
