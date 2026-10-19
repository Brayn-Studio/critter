package local.critter.phone.board

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateSetOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import local.critter.core.board.BoardLayout
import local.critter.core.flock.FlockModel
import local.critter.core.logic.LimitsText
import local.critter.core.logic.SessionOrder
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.RateWindow
import local.critter.core.skin.SkinLibrary
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.CritterView
import local.critter.phone.critter.PileSlots
import local.critter.phone.overlay.countIconColor
import local.critter.phone.overlay.fitCounts
import local.critter.phone.overlay.pileCounts
import local.critter.phone.ui.board.BoardData
import local.critter.phone.ui.board.BoardMeter
import local.critter.phone.ui.board.CardRequest
import local.critter.phone.ui.board.boardClockText
import local.critter.phone.ui.board.boardDateText
import local.critter.phone.ui.board.boardPercent
import local.critter.phone.ui.board.cardRequests
import local.critter.phone.ui.board.offlineText
import local.critter.phone.ui.doingText
import local.critter.phone.ui.folderBranch
import local.critter.phone.ui.look.PixelIcons
import local.critter.phone.ui.theme.BoardColors
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.Silkscreen
import local.critter.phone.ui.theme.pixelSurface
import local.critter.phone.ui.theme.wholePx
import kotlin.math.max
import kotlin.math.roundToInt

/** The room under the horizon for the name, the place and the context meter (the mockup's 360 − 276). */
private const val BELOW_GROUND_DP = 84f

/** A slot's width in cells (a Critter's 18 and the 4-cell gap), which its texts share with nobody. */
private const val PITCH_CELLS = 22

/** Bubbles stand this many cells above the ground, over the Critter's head. */
private const val BUBBLE_CELLS = 20

private const val BUBBLE_MAX_DP = 150f

/** How wide the pile's count tag may be, in cells: the pile (25) and the gap beside it (4). */
private const val PILE_TAG_CELLS = 18 + PileSlots.EXTRA_CELLS + 4

// The pile's count tag: icon cells, the gaps and the number style.
private val TAG_CELL = 2.dp
private val TAG_INNER = 3.dp
private val TAG_BETWEEN = 8.dp
private val TAG_PAD = 8.dp
private val CountStyle = TextStyle(fontFamily = Silkscreen, fontSize = 12.sp)

/** How wide a count tag with [entries] is, in pixels (padding, icons, numbers and the gaps between them). */
private fun Density.countTagWidth(entries: List<Pair<String, Int>>, measurer: TextMeasurer): Float {
    val cell = wholePx(TAG_CELL)
    var w = 2 * TAG_PAD.toPx() + TAG_BETWEEN.toPx() * (entries.size - 1).coerceAtLeast(0)
    for ((icon, n) in entries) {
        val cols = PixelIcons.rows[icon]?.firstOrNull()?.length ?: 0
        w += cols * cell + TAG_INNER.toPx() + measurer.measure("$n", CountStyle, density = this).size.width
    }
    return w
}

/**
 * The board's Critter mode (mockup "看板 · 宠物模式", design §8.7): the Critters standing on a dim horizon with
 * sparse dark grass; a dark bubble over the running and waiting ones; the name and "folder · branch" under each
 * with a thin context meter. The Silkscreen clock and the date at the top left, the two limits at the top right.
 * Too many sessions shrink the row, then merge into a pile ([BoardLayout]). The Critters are one [CritterView];
 * one can be carried sideways and walks back home after it is let go, its name staying put as its home and its
 * bubble hidden until it is back.
 */
@Composable
fun CritterBoard(
    data: BoardData,
    library: SkinLibrary,
    shift: State<Pair<Dp, Dp>>,
    onTap: (String) -> Unit,
) {
    val body = data.snapshot
    val sessions = body?.let { SessionOrder.forBoard(it) }.orEmpty()
    val requests = cardRequests(body)
    val dim = body?.prefs?.idleDim ?: 1.0
    val density = LocalDensity.current.density
    val (dx, dy) = shift.value
    // Carried away from their place (CritterTouchListener.onCarry), until they have walked back; a session that
    // ended meanwhile is dropped.
    val carried = remember { mutableStateSetOf<String>() }
    val liveIds = sessions.mapTo(HashSet()) { it.id }
    LaunchedEffect(liveIds) { carried.retainAll(liveIds) }

    BoxWithConstraints(Modifier.fillMaxSize().background(BoardColors.bg).offset(dx, dy)) {
        val w = maxWidth.value
        val h = maxHeight.value
        val ground = max(h * 0.6f, h - BELOW_GROUND_DP)
        val groundPx = (ground * density).roundToInt().toFloat()
        val layout = remember(sessions.size, w, h) { BoardLayout.place(sessions.size, w, h) }
        val scalePx = (layout.scale * density).roundToInt().coerceAtLeast(1).toFloat()
        val pileFrom = layout.pileFrom
        val shown = if (pileFrom == null) sessions else sessions.take(pileFrom)
        val pileSessions = if (pileFrom == null) emptyList() else sessions.drop(pileFrom)

        Horizon(ground)

        val slots = buildList {
            layout.slots.forEachIndexed { i, p ->
                val x = (p.x.toFloat() * density).roundToInt().toFloat()
                if (i < shown.size) add(PileSlots.slot(shown[i], library, dim, x, groundPx, scalePx))
                else addAll(PileSlots.build(pileSessions, library, dim, x, groundPx, scalePx))
            }
        }
        // Compose-side change detection: setActors is only called when something visible changed.
        val key = slots.map { listOf(it.sessionId, it.state, it.activity, it.manifest.name, it.x, it.y, it.scale, it.dimStrength, it.seatRow) }
        val tapSession = onTap
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { CritterView(it).apply { carryOnDrag = true } },
            update = { view ->
                view.listener = object : CritterTouchListener {
                    override fun onTap(sessionId: String) = tapSession(sessionId)
                    override fun onLongDragEnd(sessionId: String) {}
                    override fun onCarry(sessionId: String, away: Boolean) {
                        if (away) carried.add(sessionId) else carried.remove(sessionId)
                    }
                }
                if (view.tag != key) {
                    view.tag = key
                    view.setActors(slots)
                }
            },
        )

        val pitch = PITCH_CELLS * layout.scale
        layout.slots.forEachIndexed { i, p ->
            val x = p.x.toFloat()
            if (i < shown.size) {
                val s = shown[i]
                SessionTexts(s, requests[s.id], x, ground, layout.scale, pitch, w, bubble = s.id !in carried, onTap)
            } else {
                PileTexts(pileSessions, x, ground, layout.scale, onTap)
            }
        }

        Column(Modifier.padding(start = 30.dp, top = 20.dp)) {
            Text(boardClockText(data.now), color = BoardColors.clock, fontFamily = Silkscreen, fontSize = 52.sp, lineHeight = 52.sp, maxLines = 1)
            // The offline line shares the date's row: a two-line bubble at 6 dp a cell reaches up to just under it.
            Row(Modifier.padding(start = 2.dp, top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    boardDateText(data.now),
                    color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 13.sp, maxLines = 1,
                )
                if (!data.connected) {
                    Text(
                        offlineText(data),
                        color = BoardColors.wait, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.sp, maxLines = 1,
                        modifier = Modifier.padding(start = 10.dp),
                    )
                }
            }
        }
        Column(Modifier.align(Alignment.TopEnd).padding(top = 24.dp, end = 76.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            MiniLimit("5h", body?.limits?.fiveHour)
            MiniLimit("7d", body?.limits?.sevenDay)
        }
        if (sessions.isEmpty() && body != null) {
            Text(
                if (data.connected) "电脑上还没有会话" else "还没有数据",
                color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 14.sp,
                modifier = Modifier.align(Alignment.Center),
            )
        }
    }
}

/**
 * The horizon: a 2 dp line under the Critters' feet, 40 dp in from each side, with sparse 4 dp tufts of dark grass
 * on it. Painted once (it only changes with the size); it moves with the burn-in shift like everything else.
 */
@Composable
private fun Horizon(ground: Float) {
    Canvas(Modifier.fillMaxSize()) {
        val cell = max(1, 4.dp.roundToPx()).toFloat()
        val line = max(1, 2.dp.roundToPx()).toFloat()
        val y = (ground * density).roundToInt().toFloat()
        val inset = 40.dp.roundToPx().toFloat()
        drawRect(BoardColors.horizon, Offset(inset, y), Size(size.width - 2 * inset, line))
        val start = 46.dp.roundToPx().toFloat()
        var x = start
        var i = 0
        while (x < size.width - start) {
            // The mockup's sprinkle: a tuft every 9th and 23rd cell.
            if (i % 9 == 3 || i % 23 == 11) drawRect(BoardColors.grass, Offset(x, y - cell), Size(cell, cell))
            x += cell
            i++
        }
    }
}

/** "5h", a 10-cell meter and the share in Silkscreen. */
@Composable
private fun MiniLimit(label: String, window: RateWindow?) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            label, color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.sp,
            maxLines = 1, modifier = Modifier.widthIn(min = 16.dp),
        )
        BoardMeter(window?.usedPercentage, 10, 6.dp, Modifier.padding(start = 10.dp).width(120.dp))
        Text(
            boardPercent(LimitsText.percent(window), 11.sp),
            color = BoardColors.clock, fontFamily = Silkscreen, fontSize = 13.sp, textAlign = TextAlign.End, maxLines = 1,
            modifier = Modifier.padding(start = 10.dp).width(40.dp),
        )
    }
}

/**
 * The bubble over a Critter (while it is [bubble], i.e. at home) and, under the horizon, its name, the folder and
 * branch and the context meter. Everything stays inside the slot's [pitch], so long names end in "…" rather than
 * running into the neighbor; the bubble also stays inside the board ([width]).
 */
@Composable
private fun SessionTexts(
    s: BridgeSession,
    card: CardRequest?,
    x: Float,
    ground: Float,
    scale: Float,
    pitch: Float,
    width: Float,
    bubble: Boolean,
    onTap: (String) -> Unit,
) {
    val center = x + 9 * scale
    val textW = pitch - 6
    val tap = Modifier.clickable(remember { MutableInteractionSource() }, indication = null) { onTap(s.id) }
    if (bubble && (s.state == PetState.running || s.state == PetState.waiting)) {
        val bubbleW = minOf(BUBBLE_MAX_DP, textW)
        val left = (center - bubbleW / 2).coerceIn(4f, max(4f, width - bubbleW - 4))
        Box(
            Modifier.offset(left.dp, 0.dp).width(bubbleW.dp).height((ground - BUBBLE_CELLS * scale).coerceAtLeast(0f).dp),
            contentAlignment = Alignment.BottomCenter,
        ) {
            Bubble(s, card, tap)
        }
    }
    Column(
        Modifier.offset((center - textW / 2).dp, (ground + 10).dp).width(textW.dp).then(tap),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            s.name, color = BoardColors.name, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 14.sp,
            letterSpacing = 0.01.em, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Text(
            folderBranch(s), color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 11.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        s.context?.let { BoardMeter(it.usedPercent, 14, 3.dp, Modifier.padding(top = 6.dp).width(84.dp)) }
    }
}

/**
 * A dark stepped bubble, two lines at most: what a running session is doing; for a waiting one, what it wants
 * ("想 …") and, in orange, "点我回答", inside a 2 dp orange edge.
 */
@Composable
private fun Bubble(s: BridgeSession, card: CardRequest?, modifier: Modifier) {
    val waiting = s.state == PetState.waiting
    Column(
        modifier
            .pixelSurface(
                BoardColors.card2, step = 3.dp, lip = 0.dp, lipColor = Color.Transparent,
                border = if (waiting) BoardColors.wait else BoardColors.edge, borderWidth = if (waiting) 2.dp else 1.5.dp,
            )
            .padding(start = 10.dp, end = 10.dp, top = 6.dp, bottom = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (waiting) {
            Text(
                card?.what ?: "等你确认", color = BoardColors.waitInk, fontFamily = Nunito, fontWeight = FontWeight.W700,
                fontSize = 12.sp, lineHeight = 1.35.em, textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Text(
                "点我回答", color = BoardColors.wait, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 11.sp,
                lineHeight = 1.35.em, maxLines = 1,
            )
        } else {
            Text(
                doingText(s), color = BoardColors.name, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 12.sp,
                lineHeight = 1.35.em, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * The pile's counts (icon and number per state, [pileCounts]) above it and "N 个会话" below; a tap is the most
 * urgent one's. The count tag is as wide as its content, centered over the pile and never squeezed; it may reach
 * into the gap next to the pile but no further ([PILE_TAG_CELLS]), so on a crowded board the least urgent states
 * are left out ([fitCounts]) instead of running into the neighbor's bubble.
 */
@Composable
private fun PileTexts(pile: List<BridgeSession>, x: Float, ground: Float, scale: Float, onTap: (String) -> Unit) {
    val merged = FlockModel.merged(pile)
    val boxW = (18 + PileSlots.EXTRA_CELLS) * scale
    val tap = Modifier.clickable(remember { MutableInteractionSource() }, indication = null) { onTap(merged.lead.id) }
    val density = LocalDensity.current
    val measurer = rememberTextMeasurer()
    val counts = pileCounts(pile)
    val maxPx = with(density) { (PILE_TAG_CELLS * scale).dp.toPx() }
    val shown = remember(counts, maxPx, density) {
        fitCounts(counts, maxPx) { entries -> with(density) { countTagWidth(entries, measurer) } }
    }
    Box(
        Modifier.offset(x.dp, 0.dp).width(boxW.dp).height((ground - BUBBLE_CELLS * scale).coerceAtLeast(0f).dp),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Row(
            tap
                .wrapContentWidth(Alignment.CenterHorizontally, unbounded = true)
                .pixelSurface(BoardColors.card2, step = 2.dp, lip = 0.dp, lipColor = Color.Transparent, border = BoardColors.edge, borderWidth = 1.5.dp)
                .padding(horizontal = TAG_PAD, vertical = 5.dp),
            horizontalArrangement = Arrangement.spacedBy(TAG_BETWEEN),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            for ((icon, n) in shown) {
                Row(horizontalArrangement = Arrangement.spacedBy(TAG_INNER), verticalAlignment = Alignment.CenterVertically) {
                    PixelIcon(icon, tint = countIconColor(icon, Critter.colors), cell = TAG_CELL)
                    Text("$n", style = CountStyle, color = BoardColors.name, maxLines = 1, softWrap = false)
                }
            }
        }
    }
    Column(Modifier.offset(x.dp, (ground + 10).dp).width(boxW.dp).then(tap), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            "${merged.total} 个会话", color = BoardColors.name, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 14.sp,
            maxLines = 1,
        )
    }
}
