package local.critter.phone.board

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import local.critter.core.board.BoardLayout
import local.critter.core.flock.FlockModel
import local.critter.core.logic.SessionOrder
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.RateWindow
import local.critter.core.skin.SkinLibrary
import local.critter.phone.critter.CritterSlot
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.CritterView
import local.critter.phone.critter.PileSlots
import local.critter.phone.ui.contextFraction
import local.critter.phone.ui.doingText
import local.critter.phone.ui.placeLine
import local.critter.phone.ui.stateColor
import local.critter.phone.ui.theme.WaitingOrange
import local.critter.phone.ui.agoText
import local.critter.phone.ui.board.BoardData
import java.time.Instant
import java.time.ZoneId
import kotlin.math.roundToInt

private val Dim = Color(0xFF8E8E93)
private val Faint = Color(0xFF636366)
private val Track = Color(0xFF2C2C2E)

/**
 * The board's Critter mode (mockup "Critter 模式"): enlarged Critters in one row, a bubble and state marker
 * above each, its name and "branch · source" below and a thin context line underneath; the clock at the top
 * left and the two limits at the top right. Too many sessions shrink the row, then merge the rest into a pile
 * (see [BoardLayout]). The Critters are one [CritterView]; the text around them is Compose.
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
    val dim = body?.prefs?.idleDim ?: 1.0
    val density = LocalDensity.current.density
    val (dx, dy) = shift.value

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black).offset(dx, dy)) {
        val w = maxWidth.value
        val h = maxHeight.value
        val layout = remember(sessions.size, w, h) { BoardLayout.place(sessions.size, w, h) }
        val scalePx = (layout.scale * density).roundToInt().coerceAtLeast(1).toFloat()
        val pileFrom = layout.pileFrom
        val shown = if (pileFrom == null) sessions else sessions.take(pileFrom)
        val pileSessions = if (pileFrom == null) emptyList() else sessions.drop(pileFrom)

        val slots = buildList {
            layout.slots.forEachIndexed { i, p ->
                val x = p.x.toFloat() * density
                val y = p.y.toFloat() * density
                if (i < shown.size) add(PileSlots.slot(shown[i], library, dim, x, y, scalePx))
                else addAll(PileSlots.build(pileSessions, library, dim, x, y, scalePx))
            }
        }
        // Compose-side change detection: setActors is only called when something visible changed.
        val key = slots.map { listOf(it.sessionId, it.state, it.activity, it.manifest.name, it.x, it.y, it.scale, it.dimStrength, it.seatRow) }
        val tapSession = onTap
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { CritterView(it) },
            update = { view ->
                view.listener = object : CritterTouchListener {
                    override fun onTap(sessionId: String) = tapSession(sessionId)
                    override fun onLongDragEnd(sessionId: String) {}
                }
                if (view.tag != key) {
                    view.tag = key
                    view.setActors(slots)
                }
            },
        )

        layout.slots.forEachIndexed { i, p ->
            if (i < shown.size) SessionTexts(shown[i], p.x.toFloat(), p.y.toFloat(), layout.scale, onTap)
            else PileTexts(pileSessions, p.x.toFloat(), p.y.toFloat(), layout.scale, onTap)
        }

        Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 14.dp), verticalAlignment = Alignment.Top) {
            Column {
                Text(clock(data.now), color = Color(0xFFAEAEB2), fontSize = 30.sp, fontWeight = FontWeight.Light)
                if (!data.connected) {
                    Text(
                        "未连接" + (data.updatedAt?.let { " · ${agoText(it, data.now)}" } ?: ""),
                        color = WaitingOrange, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            Box(Modifier.weight(1f))
            Column(Modifier.padding(end = 40.dp)) {
                MiniLimit("5h", body?.limits?.fiveHour)
                MiniLimit("7d", body?.limits?.sevenDay)
            }
        }
        if (sessions.isEmpty() && data.snapshot != null) {
            Text(
                if (data.connected) "电脑上还没有会话" else "还没有数据",
                color = Faint, fontSize = 14.sp, modifier = Modifier.align(Alignment.Center),
            )
        }
    }
}

private fun clock(nowMs: Long): String {
    val t = Instant.ofEpochMilli(nowMs).atZone(ZoneId.systemDefault())
    return "%02d:%02d".format(t.hour, t.minute)
}

@Composable
private fun MiniLimit(label: String, window: RateWindow?) {
    val percent = window?.usedPercentage
    Row(Modifier.padding(bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Dim, fontSize = 11.sp)
        Box(Modifier.padding(horizontal = 6.dp).width(54.dp).height(4.dp).clip(RoundedCornerShape(2.dp)).background(Track)) {
            if (percent != null) {
                Box(
                    Modifier.fillMaxHeight().width((54 * (percent / 100.0).coerceIn(0.0, 1.0)).dp)
                        .background(Dim, RoundedCornerShape(2.dp)),
                )
            }
        }
        Text(percent?.let { "${it.roundToInt()}%" } ?: "—", color = Dim, fontSize = 11.sp)
    }
}

/** The bubble above a Critter and the name, place and context line below it. */
@Composable
private fun SessionTexts(s: BridgeSession, x: Float, ground: Float, scale: Float, onTap: (String) -> Unit) {
    val boxW = 21 * scale
    val left = x - 1.5f * scale
    val tap = Modifier.clickable { onTap(s.id) }
    if (s.state != PetState.idle) {
        Box(Modifier.offset(left.dp, (ground - 21 * scale - 44).dp).width(boxW.dp).height(44.dp), contentAlignment = Alignment.BottomCenter) {
            Bubble(s, tap)
        }
    }
    Column(Modifier.offset(left.dp, (ground + 6).dp).width(boxW.dp).then(tap), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(s.name, color = Color(0xFFE5E5EA), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(
            placeLine(s),
            color = Faint, fontSize = 9.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
        s.context?.let { c ->
            Box(Modifier.padding(top = 6.dp).width((boxW * 0.7f).dp).height(2.dp).background(Track)) {
                Box(Modifier.fillMaxHeight().width((boxW * 0.7f * contextFraction(c)).dp).background(Dim))
            }
        }
    }
}

@Composable
private fun Bubble(s: BridgeSession, modifier: Modifier) {
    val color = stateColor(s.state)
    val title = when (s.state) {
        PetState.waiting -> "需要确认"
        PetState.done -> "做完了"
        PetState.error -> "出错"
        else -> null
    }
    val detail = doingText(s)
    Column(
        modifier.clip(RoundedCornerShape(8.dp)).background(color.copy(alpha = 0.16f)).padding(horizontal = 7.dp, vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (title != null) Text(title, color = color, fontSize = 10.sp, fontWeight = FontWeight.Bold)
        Text(
            if (title != null && detail == title) "" else detail,
            color = Color(0xFFE5E5EA), fontSize = 10.5.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
        )
    }
}

/** The pile's counts above and its "N 个会话" label below; a tap is the most urgent one's. */
@Composable
private fun PileTexts(pile: List<BridgeSession>, x: Float, ground: Float, scale: Float, onTap: (String) -> Unit) {
    val merged = FlockModel.merged(pile)
    val boxW = (18 + PileSlots.EXTRA_CELLS) * scale
    val tap = Modifier.clickable { onTap(merged.lead.id) }
    Row(
        Modifier.offset(x.dp, (ground - 21 * scale - 22).dp).width(boxW.dp).height(22.dp).then(tap),
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.Bottom,
    ) {
        for (c in merged.counts) {
            if (c.state == PetState.idle || c.state == PetState.running) continue
            val glyph = when (c.state) { PetState.waiting -> "?"; PetState.done -> "✓"; else -> "!" }
            Text(
                "$glyph${c.count}", color = Color.Black, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(stateColor(c.state)).padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
    }
    Column(Modifier.offset(x.dp, (ground + 6).dp).width(boxW.dp).then(tap), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("${merged.total} 个会话", color = Color(0xFFE5E5EA), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}
