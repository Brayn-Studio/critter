package local.critter.core.skin

/**
 * A rasterized pose: `rows[0]` is row `minY` of the base box, `.` is transparent. Its frame is
 * the bounding box of the pixels actually drawn, so it can extend outside the 18x10 base box
 * (raised arms, dangling legs).
 */
data class PixelGrid(
    val minX: Int,
    val minY: Int,
    val width: Int,
    val height: Int,
    val rows: List<String>,
) {
    /** The palette character at base-box coordinates, or null if transparent or outside. */
    fun character(atX: Int, y: Int): Char? {
        if (atX < minX || atX >= minX + width || y < minY || y >= minY + height) return null
        val ch = rows[y - minY][atX - minX]
        return if (ch == '.') null else ch
    }

    /** The same pixels re-framed to the given box: pixels outside are dropped, gaps are transparent. */
    fun cropped(minX: Int, minY: Int, width: Int, height: Int): PixelGrid {
        val rows = (minY until minY + height).map { y ->
            (minX until minX + width).map { x -> character(x, y) ?: '.' }.joinToString("")
        }
        return PixelGrid(minX, minY, width, height, rows)
    }
}

/** Skin poses (grids of palette characters) and the idle-dim tint applied when they are drawn. */
object SkinRenderer {
    /**
     * Composites `pose`'s parts in order (later parts cover earlier ones) and returns the
     * bounding box of the drawn pixels, or null for an unknown or empty pose.
     */
    fun grid(manifest: SkinManifest, pose: String): PixelGrid? {
        val partNames = manifest.poses[pose] ?: return null
        val pixels = HashMap<Int, HashMap<Int, Char>>() // y -> x -> char
        for (name in partNames) {
            val part = manifest.parts[name] ?: continue
            if (part.at.size != 2) continue
            for ((r, line) in part.rows.withIndex()) {
                for ((c, ch) in line.withIndex()) {
                    if (ch != '.') pixels.getOrPut(part.at[1] + r) { HashMap() }[part.at[0] + c] = ch
                }
            }
        }
        if (pixels.isEmpty()) return null
        val minY = pixels.keys.min()
        val maxY = pixels.keys.max()
        val xs = pixels.values.flatMap { it.keys }
        val minX = xs.min()
        val maxX = xs.max()
        val rows = (minY..maxY).map { y ->
            (minX..maxX).map { x -> pixels[y]?.get(x) ?: '.' }.joinToString("")
        }
        return PixelGrid(minX, minY, maxX - minX + 1, maxY - minY + 1, rows)
    }

    /**
     * The skin standing still: its `base` pose, or the one it looks straight ahead with
     * (`interactions.lookCenter`, which every valid skin has) if it has no `base`.
     */
    fun portrait(manifest: SkinManifest): PixelGrid? =
        grid(manifest, "base") ?: grid(manifest, manifest.interactions.lookCenter)

    /**
     * `color` (ARGB) with the `dim` tint at `strength` (0…1): mixed `0.5 × strength` with mid
     * grey and its alpha multiplied by `1 − 0.15 × strength`. Strength 0 is the plain color at
     * full opacity ("空闲淡化" in settings).
     */
    fun dim(color: Int, strength: Double): Int {
        val s = strength.coerceIn(0.0, 1.0)
        val r = (color shr 16) and 0xFF
        val g = (color shr 8) and 0xFF
        val b = color and 0xFF
        if (s <= 0.0) return (0xFF shl 24) or (r shl 16) or (g shl 8) or b
        val mid = 127.5
        val grey = 0.5 * s
        fun mix(c: Int): Int = Math.round(c * (1 - grey) + mid * grey).toInt()
        val a = Math.round(255 * (1 - 0.15 * s)).toInt()
        return (a shl 24) or (mix(r) shl 16) or (mix(g) shl 8) or mix(b)
    }
}
