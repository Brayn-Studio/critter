package local.critter.phone.critter

import android.graphics.Bitmap
import android.graphics.Color
import local.critter.core.skin.PixelGrid
import local.critter.core.skin.SkinManifest
import local.critter.core.skin.SkinRenderer

/**
 * A skin's bitmaps, built once and reused: each pose plain and dimmed (with the pixel grid that says where
 * it sits in the base box) and each glyph per color. One bitmap pixel per cell; the renderer scales them up
 * with nearest-neighbour filtering, so one bitmap serves every scale and nothing is allocated per frame.
 * The dimming strength is fixed for the atlas's life. Main thread only.
 */
class SpriteAtlas(val skin: SkinManifest, val dimStrength: Double) {
    class Pose(val bitmap: Bitmap, val grid: PixelGrid)

    // `null` entries remember unknown or empty poses and glyphs, so they are not retried on every draw.
    private val plain = HashMap<String, Pose?>()
    private val dimmed = HashMap<String, Pose?>()
    private val glyphs = HashMap<String, HashMap<String, Bitmap?>>()

    /** [name]'s bitmap (dimmed for the `dim` tint) and its grid, or null for an unknown pose. */
    fun pose(name: String, dim: Boolean): Pose? {
        val cache = if (dim) dimmed else plain
        if (cache.containsKey(name)) return cache[name]
        val pose = SkinRenderer.grid(skin, name)?.let { grid -> poseBitmap(grid, dim)?.let { Pose(it, grid) } }
        cache[name] = pose
        return pose
    }

    /** The glyph [name] drawn in [color] (`#RRGGBB`), or null for an unknown glyph. */
    fun glyph(name: String, color: String): Bitmap? {
        val byColor = glyphs.getOrPut(name) { HashMap() }
        if (byColor.containsKey(color)) return byColor[color]
        val rgb = parseHex(color)
        val rows = skin.glyphs[name]
        val bitmap = if (rgb == null || rows == null) null else bitmap(rows) { ch -> if (ch == '#') rgb else null }
        byColor[color] = bitmap
        return bitmap
    }

    /** A glyph's width and height in cells (0 for an unknown glyph). */
    fun glyphWidth(name: String): Int = skin.glyphs[name]?.firstOrNull()?.length ?: 0
    fun glyphHeight(name: String): Int = skin.glyphs[name]?.size ?: 0

    private fun poseBitmap(grid: PixelGrid, dim: Boolean): Bitmap? {
        val strength = if (dim) dimStrength else 0.0
        return bitmap(grid.rows) { ch ->
            skin.palette[ch.toString()]?.let(::parseHex)?.let { SkinRenderer.dim(it, strength) }
        }
    }

    private fun bitmap(rows: List<String>, color: (Char) -> Int?): Bitmap? {
        val height = rows.size
        val width = rows.firstOrNull()?.length ?: 0
        if (height == 0 || width == 0) return null
        val pixels = IntArray(width * height)
        for ((r, line) in rows.withIndex()) {
            for (c in 0 until minOf(width, line.length)) {
                val ch = line[c]
                if (ch != '.') pixels[r * width + c] = color(ch) ?: 0
            }
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }

    /** `#RRGGBB` as an opaque ARGB int; null if it is not that. */
    private fun parseHex(hex: String): Int? {
        if (hex.length != 7 || hex[0] != '#') return null
        return try {
            Color.parseColor(hex)
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}

/** Atlases shared by every [CritterView] (the pile and the column draw the same skins), keyed by skin name and dimming. */
object AtlasPool {
    private val atlases = HashMap<String, SpriteAtlas>()

    fun get(skin: SkinManifest, dimStrength: Double): SpriteAtlas {
        // Quantized to 0.05, so a slider drag does not leave an atlas behind for every value.
        val dim = Math.round(dimStrength.coerceIn(0.0, 1.0) * 20) / 20.0
        val key = "${skin.name}@$dim"
        val found = atlases[key]
        if (found != null && found.skin === skin) return found
        return SpriteAtlas(skin, dim).also { atlases[key] = it }
    }
}
