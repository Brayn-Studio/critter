package local.critter.phone.ui.board

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import local.critter.core.logic.LimitsText
import local.critter.core.logic.SessionOrder
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.RateWindow
import local.critter.core.protocol.SnapshotBody
import local.critter.phone.ui.agoText
import local.critter.phone.ui.answer.permissionBody
import local.critter.phone.ui.branchAndFolder
import local.critter.phone.ui.contextFraction
import local.critter.phone.ui.contextPercentText
import local.critter.phone.ui.doingText
import local.critter.phone.ui.sourceLabel
import local.critter.phone.ui.stateColor
import local.critter.phone.ui.stateGlyph
import local.critter.phone.ui.stateLabel
import local.critter.phone.ui.theme.WaitingOrange
import java.time.Instant
import java.time.ZoneId

private val CardBg = Color(0xFF0E0E10)
private val Track = Color(0xFF1C1C1E)
private val Dim = Color(0xFF8E8E93)
private val Faint = Color(0xFF636366)
private val Bright = Color(0xFFF2F2F7)
private val CritterButton = Color(0xFFD97757)

/** What the board shows: the latest data and how fresh it is. */
data class BoardData(
    val snapshot: SnapshotBody?,
    val connected: Boolean,
    val updatedAt: Long?,
    val now: Long,
)

/**
 * What a session card says about its requests: the oldest one ([request]), what it wants and its command or path,
 * and how many more wait behind it. Only a lone permission request is answered right on the card; with more than
 * one, or for a question or plan, the card opens the answer sheet, so a button never acts on a request the card
 * does not show.
 */
data class CardRequest(val request: BridgePending, val what: String, val detail: String?, val more: Int) {
    val inline: Boolean get() = more == 0 && request.kind == PendingKind.permission
}

/** Every session's [CardRequest], by session id. */
fun cardRequests(body: SnapshotBody?): Map<String, CardRequest> =
    body?.pending.orEmpty().groupBy { it.sessionId }.mapValues { (_, requests) ->
        val oldest = requests.minBy { it.createdAt }
        val summary = oldest.summary?.takeIf { it.isNotBlank() } ?: oldest.toolName?.takeIf { it.isNotBlank() }
        val what = when (oldest.kind) {
            PendingKind.permission -> summary?.let { "想 $it" } ?: "想执行一个操作"
            PendingKind.question -> summary?.let { "问：$it" } ?: "有问题要问你"
            PendingKind.plan -> "计划等你批准"
            PendingKind.unknown -> "需要你"
        }
        val detail = if (oldest.kind == PendingKind.permission) permissionBody(oldest.input) else null
        CardRequest(oldest, what, detail, requests.size - 1)
    }

/** The landscape pro dashboard (mockup "专业看板"): clock and limits on the left, session cards on the right. */
@Composable
fun ProBoard(
    data: BoardData,
    shift: State<Pair<Dp, Dp>>,
    onAllow: (BridgePending) -> Unit,
    onDeny: (BridgePending) -> Unit,
    onOpen: (BridgePending) -> Unit,
) {
    val body = data.snapshot
    val sessions = body?.let { SessionOrder.forBoard(it) }.orEmpty()
    val requests = cardRequests(body)
    val (dx, dy) = shift.value

    Row(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .offset(dx, dy)
            .padding(horizontal = 18.dp, vertical = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Column(Modifier.width(178.dp).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            if (!data.connected) {
                Text(
                    "未连接" + (data.updatedAt?.let { " · ${agoText(it, data.now)}" } ?: ""),
                    color = WaitingOrange,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Text(clockText(data.now), color = Color(0xFFAEAEB2), fontSize = 40.sp, fontWeight = FontWeight.Light)
            Gauge("5 小时额度", body?.limits?.fiveHour, data.now)
            Gauge("7 天额度", body?.limits?.sevenDay, data.now)
            body?.limits?.let { LimitsText.staleness(it.updatedAt, data.now) }?.let {
                Text("更新于 $it", color = Faint, fontSize = 10.5.sp)
            }
        }

        if (sessions.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                Text(if (data.connected) "电脑上还没有会话" else "还没有数据", color = Faint, fontSize = 14.sp)
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                modifier = Modifier.weight(1f).fillMaxHeight(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(sessions, key = { it.id }) { session ->
                    SessionCard(session, requests[session.id], data.connected, onAllow, onDeny, onOpen)
                }
            }
        }
    }
}

private fun clockText(nowMs: Long): String {
    val t = Instant.ofEpochMilli(nowMs).atZone(ZoneId.systemDefault())
    return "%02d:%02d".format(t.hour, t.minute)
}

private fun gaugeColor(percent: Double): Color = when {
    percent < 60 -> Color(0xFF34C759)
    percent < 85 -> Color(0xFFFF9F0A)
    else -> Color(0xFFFF3B30)
}

@Composable
private fun Gauge(title: String, window: RateWindow?, now: Long) {
    Column(Modifier.fillMaxWidth().background(CardBg, RoundedCornerShape(14.dp)).padding(horizontal = 12.dp, vertical = 11.dp)) {
        Text(title, color = Dim, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        Text(LimitsText.percent(window), color = Bright, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Box(Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(Track)) {
            if (window != null) {
                Box(
                    Modifier
                        .fillMaxWidth((window.usedPercentage / 100.0).toFloat().coerceIn(0f, 1f))
                        .fillMaxHeight()
                        .background(gaugeColor(window.usedPercentage), RoundedCornerShape(3.dp)),
                )
            }
        }
        Text(
            LimitsText.resets(window, now, ZoneId.systemDefault()),
            color = Faint,
            fontSize = 10.5.sp,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

@Composable
private fun SessionCard(
    session: BridgeSession,
    card: CardRequest?,
    online: Boolean,
    onAllow: (BridgePending) -> Unit,
    onDeny: (BridgePending) -> Unit,
    onOpen: (BridgePending) -> Unit,
) {
    val request = card?.request
    val shape = RoundedCornerShape(14.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(CardBg)
            .then(if (request != null) Modifier.border(BorderStroke(1.5.dp, WaitingOrange), shape) else Modifier)
            .then(if (request != null) Modifier.clickable { onOpen(request) } else Modifier)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier.size(34.dp).background(stateColor(session.state).copy(alpha = 0.22f), RoundedCornerShape(9.dp)),
            contentAlignment = Alignment.Center,
        ) { Text(stateGlyph(session.state), color = stateColor(session.state), fontSize = 16.sp, fontWeight = FontWeight.Bold) }

        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    session.name,
                    color = Bright,
                    fontSize = 12.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    stateLabel(session.state),
                    color = stateColor(session.state),
                    fontSize = 9.5.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.background(stateColor(session.state).copy(alpha = 0.18f), RoundedCornerShape(6.dp))
                        .padding(horizontal = 6.dp, vertical = 3.dp),
                )
            }
            Text(
                doingText(session),
                color = Color(0xFFC7C7CC),
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 4.dp, bottom = 5.dp),
            )
            Text(
                "${branchAndFolder(session)} · ${sourceLabel(session.source)}",
                color = Faint,
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            session.context?.let { c ->
                Row(Modifier.padding(top = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f).height(4.dp).clip(RoundedCornerShape(2.dp)).background(Track)) {
                        Box(Modifier.fillMaxWidth(contextFraction(c)).fillMaxHeight().background(Dim, RoundedCornerShape(2.dp)))
                    }
                    Text("  ${contextPercentText(c)}", color = Dim, fontSize = 10.sp)
                }
            }
            if (card != null && request != null) {
                // The request the buttons act on, in full: what it wants and the command or path.
                Text(
                    card.what,
                    color = Bright,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 7.dp),
                )
                card.detail?.let {
                    Text(
                        it,
                        color = Color(0xFFC7C7CC),
                        fontSize = 10.sp,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier
                            .padding(top = 4.dp)
                            .fillMaxWidth()
                            .background(Track, RoundedCornerShape(6.dp))
                            .padding(horizontal = 6.dp, vertical = 4.dp),
                    )
                }
                if (card.more > 0) {
                    Text("还有 ${card.more} 个", color = WaitingOrange, fontSize = 10.sp, modifier = Modifier.padding(top = 4.dp))
                }
                Row(Modifier.padding(top = 7.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (card.inline) {
                        CardButton("拒绝", false, online) { onDeny(request) }
                        CardButton("允许", true, online) { onAllow(request) }
                    } else {
                        CardButton("打开", true, true) { onOpen(request) }
                    }
                }
            }
        }
    }
}

@Composable
private fun RowScope.CardButton(text: String, primary: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Text(
        text,
        color = if (primary) Color.White else Color(0xFFE5E5EA),
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        textAlign = TextAlign.Center,
        modifier = Modifier
            .weight(1f)
            .clip(RoundedCornerShape(7.dp))
            .background(if (primary) CritterButton else Track)
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = 5.dp)
            .alpha(if (enabled) 1f else 0.4f),
    )
}
