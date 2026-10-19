package local.critter.phone.critter

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import local.critter.core.motion.MotionActor
import local.critter.core.motion.MotionRNG
import local.critter.core.motion.enterState
import local.critter.core.motion.setActivity
import local.critter.core.motion.sleepNow
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinManifest
import local.critter.core.skin.Tint
import kotlin.math.max

/**
 * Still pictures of a Critter in its state's representative pose (what reduce motion shows), for the places
 * where pets don't move: list tiles, the pro board, notifications. 20×20 cells: the base box starts at
 * column 1 and stands on the bottom row. Built once per look and kept in a small LRU. Main thread only.
 */
object Portraits {
    private const val CELLS = 20
    private const val CACHE_SIZE = 48

    private data class Key(
        val skin: String,
        val state: PetState,
        val activity: String?,
        val cellPx: Int,
        val asleep: Boolean,
        val dim: Boolean,
        val dimStrength: Double,
    )

    private class Entry(val manifest: SkinManifest, val bitmap: Bitmap)

    private val cache = object : LinkedHashMap<Key, Entry>(CACHE_SIZE, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, Entry>?) = size > CACHE_SIZE
    }
    private val renderer = CritterRenderer()

    fun still(
        manifest: SkinManifest,
        state: PetState,
        activity: String?,
        cellPx: Int,
        asleep: Boolean = false,
        dim: Boolean = false,
        dimStrength: Double = 0.5,
    ): Bitmap {
        val u = max(1, cellPx)
        val key = Key(manifest.name, state, activity, u, asleep, dim, dimStrength)
        cache[key]?.let { if (it.manifest === manifest) return it.bitmap }
        val actor = MotionActor(manifest, MotionRNG(seed = 1), reduceMotion = true)
        actor.setActivity(activity)
        actor.enterState(state, quiet = true)
        if (asleep) actor.sleepNow()
        actor.tint = if (dim) Tint.dim else null
        val bitmap = Bitmap.createBitmap(CELLS * u, CELLS * u, Bitmap.Config.ARGB_8888)
        val atlas = AtlasPool.get(manifest, dimStrength)
        renderer.draw(Canvas(bitmap), actor.snapshot(), atlas, gx = u.toFloat(), gy = (CELLS * u).toFloat(), u = u.toFloat(), seatRow = null)
        cache[key] = Entry(manifest, bitmap)
        return bitmap
    }
}

/** [Portraits.still] as an image, [cell] (whole pixels) a cell, scaled without smoothing. */
@Composable
fun CritterPortrait(
    manifest: SkinManifest,
    state: PetState,
    activity: String?,
    cell: Dp,
    modifier: Modifier = Modifier,
    asleep: Boolean = false,
    dim: Boolean = false,
) {
    val density = LocalDensity.current
    val cellPx = with(density) { max(1, cell.roundToPx()) }
    val image = remember(manifest, state, activity, cellPx, asleep, dim) {
        Portraits.still(manifest, state, activity, cellPx, asleep, dim).asImageBitmap()
    }
    val side = with(density) { (image.width).toDp() }
    Image(image, contentDescription = null, modifier = modifier.size(side), filterQuality = FilterQuality.None)
}
