package local.critter.core.skin

import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import local.critter.core.builtin
import local.critter.core.bundledSkin
import local.critter.core.bundledSkinJson
import local.critter.core.mutated
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val json = SkinJson

private fun argb(c: Int) = listOf((c shr 16) and 0xFF, (c shr 8) and 0xFF, c and 0xFF, (c ushr 24) and 0xFF)

class SkinTest {
    // MARK: - Manifest and decoding

    @Test
    fun bundledManifestIsTheDesignCopy() {
        val bundled = File("../../Skins/clawd/manifest.json").readBytes()
        val design = File("../../docs/superpowers/specs/2026-10-17-clawd-manifest-v2.json").readBytes()
        assertTrue(bundled.contentEquals(design))
        assertEquals(bundled.toString(Charsets.UTF_8), bundledSkinJson("clawd"))
    }

    @Test
    fun builtinIsValidSchema2() {
        val m = builtin()
        assertEquals(2, m.schema)
        assertEquals(60, m.tickMs)
        assertEquals(listOf(18, 10), m.grid)
        assertTrue(SkinValidator.validate(m).isEmpty())
    }

    @Test
    fun builtinSurvivesEncodeDecodeRoundTrip() {
        val m = builtin()
        val again = json.decodeFromString(SkinManifest.serializer(), json.encodeToString(SkinManifest.serializer(), m))
        assertEquals(m, again)
    }

    @Test
    fun titleIsOptional() {
        assertNull(builtin().title)
        val titled = bundledSkinJson("clawd").replace("\"name\": \"clawd\",", "\"name\": \"clawd\", \"title\": \"小芽 Sprig\",")
        val m = json.decodeFromString(SkinManifest.serializer(), titled)
        assertEquals("小芽 Sprig", m.title)
        assertTrue(SkinValidator.validate(m).isEmpty())
    }

    @Test
    fun clipKeyDecodesShortAndLongForms() {
        val text = """[["base",40],["base",10,0,-1],["base",1,0,-2,"dust"]]"""
        val serializer = ListSerializer(ClipKey.serializer())
        val keys = json.decodeFromString(serializer, text)
        assertEquals(
            listOf(
                ClipKey(pose = "base", ticks = 40, dx = 0, dy = 0, effect = null),
                ClipKey(pose = "base", ticks = 10, dx = 0, dy = -1, effect = null),
                ClipKey(pose = "base", ticks = 1, dx = 0, dy = -2, effect = "dust"),
            ),
            keys,
        )
        assertEquals(text, json.encodeToString(serializer, keys))
    }

    @Test
    fun clipKeyEncodesEffectWithZeroOffsetInFiveElements() {
        val key = ClipKey(pose = "shut", ticks = 25, dx = 0, dy = 0, effect = "zzz")
        assertEquals("""["shut",25,0,0,"zzz"]""", json.encodeToString(ClipKey.serializer(), key))
    }

    @Test
    fun clipKeyRejectsThreeElements() {
        assertFailsWith<SerializationException> {
            json.decodeFromString(ClipKey.serializer(), """["base",1,2]""")
        }
    }

    @Test
    fun spanDecodesNumberOrRange() {
        assertEquals(Span(5.0), json.decodeFromString(Span.serializer(), "5"))
        assertEquals(Span(3.0, 13.0), json.decodeFromString(Span.serializer(), "[3,13]"))
    }

    @Test
    fun spanEncodesNumberWhenCollapsed() {
        assertEquals("5", json.encodeToString(Span.serializer(), Span(5.0)))
        assertEquals("[3,13]", json.encodeToString(Span.serializer(), Span(3.0, 13.0)))
    }

    @Test
    fun weightedClipDecodesFromPair() {
        val w = json.decodeFromString(WeightedClip.serializer(), """["blink",6]""")
        assertEquals(WeightedClip(clip = "blink", weight = 6), w)
    }

    // MARK: - Rasterization

    @Test
    fun basePoseIsTheApprovedGridDoubled() {
        val old = listOf("...############...", "...##o######o##...", ".################.", "...############...", "....#.#....#.#....")
        val g = SkinRenderer.grid(builtin(), "base")!!
        for (y in 0 until 10) {
            for (x in 0 until 18) {
                val want = old[y / 2][x]
                assertEquals(if (want == '.') null else want, g.character(x, y))
            }
        }
    }

    @Test
    fun heldPoseHangsBelowGround() { // dangling legs reach row 10
        val g = SkinRenderer.grid(builtin(), "held_a")!!
        assertEquals(11, g.minY + g.height)
    }

    @Test
    fun laterPartsCoverEarlierOnes() {
        val g = SkinRenderer.grid(builtin(), "base")!!
        assertEquals('o', g.character(5, 2)) // eyes over body
    }

    @Test
    fun portraitIsTheBasePoseOrElseLookCenter() {
        val m = builtin()
        assertEquals(SkinRenderer.grid(m, "base"), SkinRenderer.portrait(m))
        m.poses.remove("base")
        m.interactions.lookCenter = "look_l"
        assertEquals(SkinRenderer.grid(m, "look_l"), SkinRenderer.portrait(m))
    }

    @Test
    fun unknownPoseHasNoGrid() {
        assertNull(SkinRenderer.grid(builtin(), "nope"))
    }

    @Test
    fun croppingKeepsTheBaseBox() {
        val g = SkinRenderer.grid(builtin(), "held_a")!!.cropped(minX = 0, minY = 0, width = 18, height = 10)
        assertEquals(10, g.rows.size)
        assertTrue(g.rows.all { it.length == 18 })
        assertNull(g.character(5, 10))
    }

    @Test
    fun dimImageMixesHalfWithGrey() {
        val color = 0xFFD97757.toInt()
        assertEquals(listOf(172, 123, 107, 217), argb(SkinRenderer.dim(color, 1.0)))
        assertEquals(listOf(217, 119, 87, 255), argb(SkinRenderer.dim(color, 0.0)))
    }

    @Test
    fun dimStrengthScalesTheTint() {
        // "空闲淡化": 1 is today's tint, 0 the plain color, 0.5 halfway (mixed 25%, alpha × 0.925).
        val color = 0xFFD97757.toInt()
        assertEquals(listOf(172, 123, 107, 217), argb(SkinRenderer.dim(color, 1.0)))
        assertEquals(listOf(217, 119, 87, 255), argb(SkinRenderer.dim(color, 0.0)))
        assertEquals(listOf(195, 121, 97, 236), argb(SkinRenderer.dim(color, 0.5)))
        // out-of-range strengths are clamped
        assertEquals(argb(SkinRenderer.dim(color, 1.0)), argb(SkinRenderer.dim(color, 7.0)))
        assertEquals(argb(SkinRenderer.dim(color, 0.0)), argb(SkinRenderer.dim(color, -1.0)))
    }

    @Test
    fun imageIsGridSized() {
        // The Swift test sizes the CGImage; here the grid a bitmap is built from.
        val g = SkinRenderer.grid(builtin(), "base")!!
        assertEquals(g.height, g.rows.size)
        assertTrue(g.rows.all { it.length == g.width })
    }

    @Test
    fun glyphImageDrawsHashesOnly() {
        // The Swift test draws a glyph bitmap; here the plain (undimmed) color it is drawn with.
        assertEquals(listOf(0x34, 0xC7, 0x59, 255), argb(SkinRenderer.dim(0xFF34C759.toInt(), 0.0)))
    }

    // MARK: - Validator

    @Test fun validatorRejectsSchema1() = assertFalse(mutated { it.schema = 1 }.isEmpty())

    @Test fun validatorCatchesMissingState() = assertFalse(mutated { it.states.remove("waiting") }.isEmpty())

    @Test
    fun validatorCatchesUnknownPoseInClip() =
        assertFalse(mutated { it.clips["idle"] = listOf(ClipKey(pose = "nope", ticks = 1)) }.isEmpty())

    @Test
    fun validatorCatchesZeroTickKey() =
        assertFalse(mutated { it.clips["idle"] = listOf(ClipKey(pose = "base", ticks = 0)) }.isEmpty())

    @Test
    fun validatorCatchesUnknownEffect() =
        assertFalse(mutated { it.clips["idle"] = listOf(ClipKey(pose = "base", ticks = 1, effect = "nope")) }.isEmpty())

    @Test
    fun validatorReportsReservedEffectNameAsUnknown() {
        assertFalse(mutated { it.clips["idle"] = listOf(ClipKey(pose = "base", ticks = 1, effect = "@seat")) }.isEmpty())
        assertFalse(mutated { it.effects["@seat"] = it.effects["dust"]!! }.isEmpty())
    }

    @Test
    fun validatorCatchesUnknownPartInPose() =
        assertFalse(mutated { it.poses["base"] = listOf("body", "nope") }.isEmpty())

    @Test
    fun validatorCatchesRaggedPartRows() =
        assertFalse(mutated { it.parts["body"]!!.rows = listOf("####", "##") }.isEmpty())

    @Test
    fun validatorCatchesCharacterNotInPalette() = assertFalse(mutated { it.palette.remove("o") }.isEmpty())

    @Test
    fun validatorCatchesMissingVariantLoop() =
        assertFalse(mutated { it.states["running"]!!.variants!!["think"]!!.loop = "nope" }.isEmpty())

    @Test
    fun validatorCatchesUnknownInteractionClip() = assertFalse(mutated { it.interactions.notice = "nope" }.isEmpty())

    @Test
    fun validatorCatchesUnknownGlyphInEffect() =
        assertFalse(mutated { it.effects["dust"]!!.particles!![0].glyph = "nope" }.isEmpty())

    @Test
    fun validatorBoundsTheTitle() {
        assertEquals(listOf("title must be 1…40 characters"), mutated { it.title = "" })
        assertEquals(listOf("title must be 1…40 characters"), mutated { it.title = "芽".repeat(41) })
        assertTrue(mutated { it.title = "芽".repeat(40) }.isEmpty())
    }

    @Test
    fun validatorCatchesUnknownGazePose() {
        val m = bundledSkin("sprig")
        assertNotNull(m.states["done"]?.gaze)
        m.states["done"]!!.gaze!!.right = "nope"
        assertEquals(listOf("state done gaze references unknown pose nope"), SkinValidator.validate(m))
    }

    @Test
    fun validatorPinsTheGridTo18By10() {
        // The renderer, layout, hover and gaze all draw an 18×10 box with the ground on row 10.
        assertTrue(mutated { it.grid = listOf(20, 10) }.any { "grid" in it })
        assertTrue(mutated { it.grid = listOf(18, 12) }.any { "grid" in it })
        assertTrue(mutated { it.grid = listOf(18) }.any { "grid" in it })
    }

    @Test
    fun validatorBoundsEveryNumber() {
        // Each would overflow or hog the CPU at runtime; out of range, the skin is rejected
        // instead, so clawd is used.
        val cases: List<Pair<String, (SkinManifest) -> Unit>> = listOf(
            "tickMs" to { m -> m.tickMs = 1 },
            "tickMs" to { m -> m.tickMs = 100_000 },
            "part body at" to { m -> m.parts["body"]!!.at = listOf(Int.MAX_VALUE, 0) },
            "part body" to { m -> m.parts["body"]!!.rows = listOf("#".repeat(65)) },
            "glyph dot" to { m -> m.glyphs["dot"] = List(65) { "#" } },
            "clip idle key ticks" to { m -> m.clips["idle"] = listOf(ClipKey(pose = "base", ticks = Int.MAX_VALUE)) },
            "clip idle key dy" to { m -> m.clips["idle"] = listOf(ClipKey(pose = "base", ticks = 1, dx = 0, dy = Int.MIN_VALUE)) },
            "clip idle key dx" to { m -> m.clips["idle"] = listOf(ClipKey(pose = "base", ticks = 1, dx = 1_000, dy = 0)) },
            "particle life" to { m -> m.effects["dust"]!!.particles!![0].life = Span(1.0, 1e12) },
            "particle count" to { m -> m.effects["dust"]!!.particles!![0].count = 1_000_000 },
            "particle x" to { m -> m.effects["dust"]!!.particles!![0].x = Span(-1e300, 0.0) },
            "particle vy" to { m -> m.effects["dust"]!!.particles!![0].vy = Span(1e300) },
            "particle ay" to { m -> m.effects["dust"]!!.particles!![0].ay = Double.NaN },
            "particle sway" to { m -> m.effects["dust"]!!.particles!![0].sway = 1e9 },
            "accessory spinner box" to { m -> m.accessories["spinner"]!!.box = Int.MAX_VALUE },
            "accessory spinner periodMs" to { m -> m.accessories["spinner"]!!.periodMs = 0 },
            "accessory q bobEvery" to { m -> m.accessories["q"]!!.bobEvery = Int.MAX_VALUE },
            "accessory check twinkleEvery" to { m -> m.accessories["check"]!!.twinkleEvery = -1 },
            "fidget.every" to { m -> m.states["idle"]!!.fidget!!.every = listOf(1, Int.MAX_VALUE) },
            "fidget weight" to { m -> m.states["idle"]!!.fidget!!.pick[0].weight = Int.MAX_VALUE },
            "sleep.after" to { m -> m.states["idle"]!!.sleep!!.after = Int.MAX_VALUE },
            "impatient.after" to { m -> m.states["waiting"]!!.impatient!!.after = Int.MIN_VALUE },
            "badge x" to { m -> m.states["waiting"]!!.badge!!.x = Int.MAX_VALUE },
            "badge hopEvery" to { m -> m.states["waiting"]!!.badge!!.hopEvery = Int.MAX_VALUE },
            "badge impatientHopEvery" to { m -> m.states["waiting"]!!.badge!!.impatientHopEvery = 0 },
            "stillDy" to { m -> m.states["error"]!!.stillDy = Int.MIN_VALUE },
        )
        for ((field, change) in cases) {
            val problems = mutated(change)
            assertTrue(problems.any { field in it }, "$field: $problems")
        }
    }

    // MARK: - Loader

    @Test
    fun loaderFallsBackOnInvalidSkin() {
        val invalid = builtin()
        invalid.states.remove("waiting")
        assertNull(SkinLoader.decode(json.encodeToString(SkinManifest.serializer(), invalid)))
        assertNull(SkinLoader.decode("not json"))
    }

    @Test
    fun loaderFindsValidSkin() {
        val custom = builtin()
        custom.name = "custom"
        val loaded = SkinLoader.decode(json.encodeToString(SkinManifest.serializer(), custom))
        assertEquals("custom", loaded?.name)
    }

    @Test
    fun loaderFirstValidSourceWins() {
        // The Swift test searches two directories; here the library's sources: a pushed manifest
        // that is invalid is skipped for the valid bundled one.
        val invalid = builtin()
        invalid.states.remove("waiting")
        val library = SkinLibrary(
            assetReader = { if (it == "skins/clawd/manifest.json") bundledSkinJson("clawd") else null },
            pushed = mapOf("clawd" to json.encodeToString(SkinManifest.serializer(), invalid)),
        )
        assertEquals("clawd", library.manifest("clawd").name)
        val valid = builtin()
        valid.name = "second-wins"
        val pushedFirst = SkinLibrary(
            assetReader = { bundledSkinJson("clawd") },
            pushed = mapOf("clawd" to json.encodeToString(SkinManifest.serializer(), valid)),
        )
        assertEquals("second-wins", pushedFirst.manifest("clawd").name)
    }

    // MARK: - Library

    @Test
    fun forcedSkinAnswersForEveryName() {
        val reader = { path: String -> path.takeIf { it.startsWith("skins/") }?.let { runCatching { bundledSkinJson(it.split('/')[1]) }.getOrNull() } }
        val mochi = SkinLibrary(reader, forced = "mochi")
        assertEquals("mochi", mochi.manifest("sprig").name)
        assertEquals("mochi", mochi.manifest("not-on-this-phone").name)
        assertEquals("clawd", SkinLibrary(reader, forced = "nope").manifest("sprig").name)
        assertEquals("sprig", SkinLibrary(reader).manifest("sprig").name)
    }

    /** The desktop's rule (random-pets spec): one clock per row, at the default skin's tick; others don't join. */
    @Test
    fun onlySkinsOnTheClockSkinsTickJoinTheRow() {
        val slow = builtin().apply { name = "slow"; tickMs = 100 }
        val slowJson = json.encodeToString(SkinManifest.serializer(), slow)
        val reader = { path: String -> path.takeIf { it.startsWith("skins/") }?.let { runCatching { bundledSkinJson(it.split('/')[1]) }.getOrNull() } }

        // The Mac's default runs at 60 ms: a 100 ms skin is drawn as the default instead.
        val fast = SkinLibrary(reader, pushed = mapOf("slow" to slowJson), clockSkin = "sprig")
        assertEquals("sprig", fast.manifest("slow").name)
        assertEquals("mochi", fast.manifest("mochi").name)
        assertEquals(60, fast.manifest("clawd").tickMs)

        // The default runs at 100 ms: the 60 ms skins don't join, it does.
        val slowRow = SkinLibrary(reader, pushed = mapOf("slow" to slowJson), clockSkin = "slow")
        assertEquals("slow", slowRow.manifest("slow").name)
        assertEquals("slow", slowRow.manifest("sprig").name)
        assertEquals(100, slowRow.manifest("not-on-this-phone").tickMs)

        // A forced skin answers for everything anyway; no clock skin, no rule.
        assertEquals("slow", SkinLibrary(reader, pushed = mapOf("slow" to slowJson), forced = "slow", clockSkin = "sprig").manifest("mochi").name)
        assertEquals("slow", SkinLibrary(reader, pushed = mapOf("slow" to slowJson)).manifest("slow").name)
    }

    @Test
    fun unknownOrInvalidSkinFallsBackToClawd() {
        val broken = builtin()
        broken.states.remove("waiting")
        val library = SkinLibrary(
            assetReader = { path -> path.takeIf { it.startsWith("skins/") }?.let { runCatching { bundledSkinJson(it.split('/')[1]) }.getOrNull() } },
            pushed = mapOf("broken" to json.encodeToString(SkinManifest.serializer(), broken), "garbage" to "{"),
        )
        assertEquals("clawd", library.manifest("nope").name)
        assertEquals("clawd", library.manifest("broken").name)
        assertEquals("clawd", library.manifest("garbage").name)
        assertEquals("clawd", library.manifest("../clawd").name)
        assertEquals("sprig", library.manifest("sprig").name)
    }

    @Test
    fun bundledSkinsAllValidate() {
        val names = listOf("bristle", "clawd", "mochi", "peep", "sprig")
        val dirs = File("../../Skins").listFiles { f -> f.isDirectory }!!.map { it.name }.sorted()
        assertEquals(names, dirs)
        for (name in dirs) {
            val m = SkinLoader.decode(bundledSkinJson(name))
            assertNotNull(m, name)
            assertEquals(name, m.name)
        }
    }
}
