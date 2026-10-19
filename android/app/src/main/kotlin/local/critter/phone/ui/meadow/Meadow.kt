package local.critter.phone.ui.meadow

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import local.critter.core.board.BoardLayout
import local.critter.core.flock.FlockModel
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinLibrary
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.CritterView
import local.critter.phone.critter.PileSlots
import local.critter.phone.ui.look.SkyColors
import local.critter.phone.ui.look.SkyTime
import local.critter.phone.ui.look.skyColors
import local.critter.phone.ui.stateIcon
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.Silkscreen
import local.critter.phone.ui.theme.pixelSurface
import local.critter.phone.ui.theme.state
import local.critter.phone.ui.theme.wholePx
import kotlin.math.min

/** dp per cell on the meadow (design §8.3). */
private const val SCALE = 3f
private const val MARGIN_DP = 12f
private const val MAX_PER_ROW = 5

/** A Critter's base box is 18 cells wide; the pile is [PileSlots.EXTRA_CELLS] wider. */
private const val BASE_CELLS = 18

/** The opening: one Critter after another pops up out of the grass, this far apart (design §7). */
private const val OPENING_STAGGER_MS = 80L

/** The clear space kept between two neighbours' name tags. */
private const val TAG_GAP_DP = 4f

/** Tags, bubbles and counts may reach this close to the meadow's sides (the Critters keep [MARGIN_DP]). */
private const val EDGE_DP = 4f

/** Only the pile states that need a look are counted above it (as on the board). */
private val COUNTED = setOf(PetState.waiting, PetState.error, PetState.done)

/**
 * The home screen's meadow (mockup "首页"): [height] of sky and grass, the ground [ground] from the top, and the
 * sessions standing on it in one row ([BoardLayout.placeRow]) at 3 dp a cell, in one live [CritterView]. Each has
 * its name on a tag at its feet; one in [bubbles] wears an orange bubble with that text above its head. More than
 * fit merge into a pile with "n 个会话" below and the counts that need a look above. [asleep] (offline) puts them
 * all to sleep, greyed like idle ones. With [opening], the first time there are Critters they pop up one by one.
 * A tap on a Critter is [onTap] with its session id. [modifier] gives it its width.
 */
@Composable
fun Meadow(
    sessions: List<BridgeSession>,
    library: SkinLibrary,
    dim: Double,
    time: SkyTime,
    onTap: (String) -> Unit,
    modifier: Modifier,
    height: Dp = 236.dp,
    ground: Dp = 200.dp,
    asleep: Boolean = false,
    bubbles: Map<String, String> = emptyMap(),
    opening: Boolean = false,
) {
    BoxWithConstraints(modifier.height(height)) {
        val density = LocalDensity.current
        val widthDp = maxWidth.value
        val groundDp = ground.value
        val layout = remember(sessions.size, widthDp, groundDp) {
            BoardLayout.placeRow(sessions.size, widthDp, groundDp, SCALE, MARGIN_DP, MAX_PER_ROW)
        }
        val pileFrom = layout.pileFrom
        val shown = if (pileFrom == null) sessions else sessions.take(pileFrom)
        val pile = if (pileFrom == null) emptyList() else sessions.drop(pileFrom)

        // Whole pixels: a cell, each Critter's left edge and the ground line.
        val u = with(density) { wholePx(SCALE.dp) }
        val groundPx = with(density) { ground.roundToPx() }.toFloat()
        val slots = buildList {
            layout.slots.forEachIndexed { i, p ->
                val x = with(density) { p.x.toFloat().dp.roundToPx() }.toFloat()
                if (i < shown.size) add(PileSlots.slot(shown[i], library, dim, x, groundPx, u))
                else addAll(PileSlots.build(pile, library, dim, x, groundPx, u))
            }
        }.map { if (asleep) it.copy(state = PetState.idle, activity = null, sleeping = true) else it }
        // setActors only when something visible changed (the manifests compare by name here).
        val key = slots.map { listOf(it.sessionId, it.state, it.activity, it.manifest.name, it.x, it.y, it.scale, it.dimStrength, it.seatRow, it.sleeping) }
        val tap by rememberUpdatedState(onTap)
        val rise = remember { RiseOnce() }

        MeadowBackdrop(time, ground, Modifier.matchParentSize())
        AndroidView(
            modifier = Modifier.matchParentSize(),
            factory = { context ->
                CritterView(context).apply {
                    carryOnDrag = true
                    listener = object : CritterTouchListener {
                        override fun onTap(sessionId: String) = tap(sessionId)
                        override fun onLongDragEnd(sessionId: String) {}
                    }
                }
            },
            update = { view ->
                if (view.tag != key) {
                    view.tag = key
                    view.setActors(slots)
                }
                // Before the first frame, so they never stand there before popping up.
                if (opening && !rise.done && slots.isNotEmpty()) {
                    rise.done = true
                    view.riseAll(OPENING_STAGGER_MS)
                }
            },
        )

        val sky = skyColors(time)
        val centers = layout.slots.mapIndexed { i, p ->
            p.x.toFloat() + (if (i == pileFrom) (BASE_CELLS + PileSlots.EXTRA_CELLS) / 2f else BASE_CELLS / 2f) * SCALE
        }
        val headTop = groundDp - 21 * SCALE
        val counts = if (pile.isEmpty()) emptyList() else FlockModel.merged(pile).counts.filter { it.state in COUNTED }
        // What stands above the heads: a bubble, or the pile's counts.
        val above = layout.slots.indices.map { i -> if (i < shown.size) bubbles[shown[i].id] != null else counts.isNotEmpty() }
        layout.slots.indices.forEach { i ->
            val tagRoom = labelRoom(centers, i, widthDp, TAG_GAP_DP) { true }
            val aboveRoom = labelRoom(centers, i, widthDp, 0f) { above[it] }
            val tagAt = Modifier.offset((centers[i] - tagRoom / 2).dp, ground + 5.dp).width(tagRoom.dp)
            val aboveAt = Modifier.offset(x = (centers[i] - aboveRoom / 2).dp).width(aboveRoom.dp)
            if (i < shown.size) {
                val s = shown[i]
                Box(tagAt, contentAlignment = Alignment.TopCenter) { MeadowTag(s.name, sky) }
                bubbles[s.id]?.let { text ->
                    // The tail's tip stays 5 dp below the head line; a larger font grows the bubble upwards.
                    Box(aboveAt.height((headTop + 5).dp), contentAlignment = Alignment.BottomCenter) { MeadowBubble(text) }
                }
            } else {
                Box(tagAt, contentAlignment = Alignment.TopCenter) { MeadowTag("${pile.size} 个会话", sky) }
                if (counts.isNotEmpty()) {
                    Box(aboveAt.height(headTop.dp), contentAlignment = Alignment.BottomCenter) {
                        PileCounts(counts.map { it.state to it.count }, sky)
                    }
                }
            }
        }
    }
}

/** Whether the opening has played in this meadow. */
private class RiseOnce {
    var done = false
}

/**
 * How wide a label centred on slot [i] may be: up to [gap] short of halfway to the nearest neighbour on each side
 * that has a label at the same height ([taken]), or out to [EDGE_DP] from the side when none does. Labels never
 * overlap; a longer text is cut short.
 */
private fun labelRoom(centers: List<Float>, i: Int, widthDp: Float, gap: Float, taken: (Int) -> Boolean): Float {
    val c = centers[i]
    val left = (i - 1 downTo 0).firstOrNull(taken)?.let { (c - centers[it] - gap) / 2 } ?: (c - EDGE_DP)
    val right = (i + 1..centers.lastIndex).firstOrNull(taken)?.let { (centers[it] - c - gap) / 2 } ?: (widthDp - EDGE_DP - c)
    return (2 * min(left, right)).coerceAtLeast(0f)
}

/** A white name tag on the meadow (dark at night), one line, cut short when there is no room. */
@Composable
internal fun MeadowTag(text: String, sky: SkyColors, modifier: Modifier = Modifier) {
    Text(
        text,
        color = Color(sky.tagInk), fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 10.5.sp, lineHeight = 15.sp,
        maxLines = 1, overflow = TextOverflow.Ellipsis,
        modifier = modifier.background(Color(sky.tag), PixelShape(2.dp)).padding(horizontal = 6.dp),
    )
}

/** The orange bubble above a Critter that is waiting for you, with a stepped tail pointing down at it. */
@Composable
private fun MeadowBubble(text: String) {
    val c = Critter.colors
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text,
            color = c.state(PetState.waiting).fg, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 11.5.sp,
            lineHeight = 1.3.em, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .pixelSurface(c.wait, step = 3.dp, lip = 2.dp, lipColor = c.waitDeep)
                .padding(start = 9.dp, end = 9.dp, top = 4.dp, bottom = 6.dp),
        )
        StepTail(c.wait)
    }
}

/** The bubble's tail: a 3-cell row and the middle cell under it, cells 2 × 3 dp in whole pixels. */
@Composable
private fun StepTail(color: Color) {
    val density = LocalDensity.current
    val w = with(density) { wholePx(2.dp) }
    val h = with(density) { wholePx(3.dp) }
    Canvas(with(density) { Modifier.size((3 * w).toDp(), (2 * h).toDp()) }) {
        drawRect(color, Offset.Zero, Size(3 * w, h))
        drawRect(color, Offset(w, h), Size(w, h))
    }
}

/** The pile's counts above it: each state's mark in its color and the number in pixel digits. */
@Composable
private fun PileCounts(counts: List<Pair<PetState, Int>>, sky: SkyColors) {
    val c = Critter.colors
    Row(
        Modifier.background(Color(sky.tag), PixelShape(2.dp)).padding(start = 6.dp, end = 6.dp, top = 2.dp, bottom = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for ((state, n) in counts) {
            Row(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
                PixelIcon(stateIcon(state), tint = if (state == PetState.waiting) c.waitDeep else c.state(state).glyph)
                Text("$n", color = Color(sky.tagInk), fontFamily = Silkscreen, fontSize = 11.5.sp, lineHeight = 15.sp, maxLines = 1)
            }
        }
    }
}
