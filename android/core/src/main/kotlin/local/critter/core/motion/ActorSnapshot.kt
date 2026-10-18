package local.critter.core.motion

import kotlinx.serialization.Serializable
import local.critter.core.skin.Tint

/**
 * A glyph to draw: `x`, `y` are its top-left cell in base-box coordinates (y down, ground =
 * row 10), relative to the actor's anchor plus its follow offset, with lag, lift and (for
 * particles and props) the key's dx already applied.
 */
@Serializable
data class GlyphDraw(
    val glyph: String,
    val color: String,
    val x: Int,
    val y: Int,
    val alpha: Double,
)

/** Everything needed to draw one actor for one tick; equal snapshots draw identically. */
@Serializable
data class ActorSnapshot(
    val hidden: Boolean,
    val pose: String,
    /** Key dx + lag, in cells. */
    val bodyX: Int,
    /** Key dy + lift, in cells, up positive; decides the ground clipping. */
    val bodyY: Int,
    /** Follow offset in cells, up positive. */
    val offsetX: Int,
    val offsetY: Int,
    val tint: Tint?,
    val alpha: Double,
    val z: Int,
    /** Shadow width in cells; 0 = no shadow. */
    val shadowWidth: Int,
    val accessory: GlyphDraw?,
    val badge: GlyphDraw?,
    val particles: List<GlyphDraw>,
    val props: List<GlyphDraw>,
)
