package local.critter.phone.ui.board

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import local.critter.core.logic.LimitsText
import local.critter.core.logic.SessionOrder
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.PetState
import local.critter.core.protocol.RateWindow
import local.critter.core.protocol.SnapshotBody
import local.critter.core.skin.SkinLibrary
import local.critter.phone.critter.CritterPortrait
import local.critter.phone.ui.answer.permissionBody
import local.critter.phone.ui.contextPercentText
import local.critter.phone.ui.doingText
import local.critter.phone.ui.folderName
import local.critter.phone.ui.sourceLabel
import local.critter.phone.ui.theme.BoardColors
import local.critter.phone.ui.theme.ButtonKind
import local.critter.phone.ui.theme.ButtonSize
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelButton
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.Silkscreen
import local.critter.phone.ui.theme.StateChip
import local.critter.phone.ui.theme.percentText
import local.critter.phone.ui.theme.pixelSurface
import java.time.ZoneId

/** How many lines of a command the card shows; the answer sheet (a tap on the card) shows all of it. */
private const val SLIP_LINES = 4

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

/**
 * The pro board's two columns of cards. A card with a request is two rows tall and always heads the left column
 * (the mockup's `grid-row: span 2`); every other card, in order, goes to the shorter column, the left one on a
 * tie, so without requests they simply alternate.
 */
fun proColumns(sessions: List<BridgeSession>, requests: Map<String, CardRequest>): Pair<List<BridgeSession>, List<BridgeSession>> {
    val (asking, others) = sessions.partition { it.id in requests }
    val left = asking.toMutableList()
    val right = ArrayList<BridgeSession>()
    var leftRows = 2 * asking.size
    var rightRows = 0
    for (s in others) {
        if (leftRows <= rightRows) {
            left += s
            leftRows++
        } else {
            right += s
            rightRows++
        }
    }
    return left to right
}

/**
 * The landscape pro dashboard (mockup "看板 · 专业模式"): the clock, the date and two limit cards in a 212 dp
 * column on the left; the session cards in two columns on the right, each with its Critter standing still at the
 * top left (dimmed unless it is waiting). A lone permission request is answered on its card.
 */
@Composable
fun ProBoard(
    data: BoardData,
    library: SkinLibrary,
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
            .background(BoardColors.bg)
            .offset(dx, dy)
            .padding(start = 26.dp, end = 18.dp, top = 18.dp, bottom = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Column(Modifier.width(212.dp).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Column {
                Text(
                    boardClockText(data.now), color = BoardColors.clock, fontFamily = Silkscreen, fontSize = 44.sp, lineHeight = 44.sp,
                    maxLines = 1, modifier = Modifier.cssLine(44.sp),
                )
                Text(
                    boardDateText(data.now),
                    color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 13.sp, maxLines = 1,
                    modifier = Modifier.padding(start = 2.dp, top = 8.dp, bottom = 4.dp),
                )
                if (!data.connected) {
                    Text(
                        offlineText(data),
                        color = BoardColors.wait, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.sp, maxLines = 1,
                        modifier = Modifier.padding(start = 2.dp, bottom = 4.dp),
                    )
                }
            }
            Gauge("5 小时额度", body?.limits?.fiveHour, data.now)
            Gauge("7 天额度", body?.limits?.sevenDay, data.now)
            body?.limits?.let { LimitsText.staleness(it.updatedAt, data.now) }?.let {
                Text("更新于 $it", color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 11.sp)
            }
        }

        if (sessions.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                Text(
                    if (data.connected) "电脑上还没有会话" else "还没有数据",
                    color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 14.sp,
                )
            }
        } else {
            val (left, right) = proColumns(sessions, requests)
            // Two columns that scroll together; the right 44 dp stay clear for the mode button.
            Row(
                Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(end = 44.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                for (column in listOf(left, right)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        for (session in column) {
                            SessionCard(session, requests[session.id], library, data.connected, onAllow, onDeny, onOpen)
                        }
                    }
                }
            }
        }
    }
}

/** A limit: its name and share in Silkscreen, a 20-cell meter, and when it resets. */
@Composable
private fun Gauge(title: String, window: RateWindow?, now: Long) {
    Column(
        Modifier
            .fillMaxWidth()
            .pixelSurface(BoardColors.card, step = 3.dp, lip = 0.dp, lipColor = Color.Transparent, border = BoardColors.edge, borderWidth = 1.dp)
            .padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                title, color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 11.5.sp,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).alignByBaseline(),
            )
            Text(
                percentText(LimitsText.percent(window), 17.sp),
                color = BoardColors.clock, fontFamily = Silkscreen, fontSize = 22.sp, lineHeight = 22.sp, maxLines = 1,
                modifier = Modifier.alignByBaseline().cssLine(22.sp),
            )
        }
        BoardMeter(window?.usedPercentage, 20, 7.dp, Modifier.padding(top = 8.dp, bottom = 6.dp))
        Text(
            LimitsText.resets(window, now, ZoneId.systemDefault()),
            color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 11.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * One session: its still Critter, the name and state chip, what it is doing (what it wants, with a request), the
 * folder, branch and source, and a 16-cell context meter. With a request the card has an orange edge; a lone
 * permission request shows its command and 「拒绝」「允许」, any other request 「打开」.
 */
@Composable
private fun SessionCard(
    session: BridgeSession,
    card: CardRequest?,
    library: SkinLibrary,
    online: Boolean,
    onAllow: (BridgePending) -> Unit,
    onDeny: (BridgePending) -> Unit,
    onOpen: (BridgePending) -> Unit,
) {
    val request = card?.request
    val edge = if (request != null) 2.dp else 1.dp
    Column(
        Modifier
            .fillMaxWidth()
            .pixelSurface(
                BoardColors.card, step = 3.dp, lip = 0.dp, lipColor = Color.Transparent,
                border = if (request != null) BoardColors.wait else BoardColors.edge, borderWidth = edge,
            )
            .then(
                if (request != null) Modifier.clickable(remember { MutableInteractionSource() }, indication = null) { onOpen(request) }
                else Modifier,
            )
            .padding(start = 11.dp, end = 11.dp, top = 10.dp, bottom = 11.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(44.dp, 40.dp), contentAlignment = Alignment.BottomCenter) {
                CritterPortrait(
                    library.manifest(session.skin), session.state, session.activity, cell = 2.dp,
                    dim = session.state != PetState.waiting,
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        session.name, color = BoardColors.name, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 14.sp,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                    )
                    StateChip(session.state)
                }
                Text(
                    card?.what ?: doingText(session),
                    color = if (request != null) BoardColors.waitInk else BoardColors.doing,
                    fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Meta(session)
            }
        }
        if (card != null && request != null) Ask(card, request, online, onAllow, onDeny, onOpen)
        session.context?.let { ctx ->
            Row(Modifier.padding(top = 5.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                BoardMeter(ctx.usedPercent, 16, 4.dp, Modifier.weight(1f))
                Text(
                    percentText(contextPercentText(ctx), 10.5.sp),
                    color = BoardColors.dim, fontFamily = Silkscreen, fontSize = 10.5.sp, textAlign = TextAlign.End, maxLines = 1,
                    modifier = Modifier.widthIn(min = 30.dp),
                )
            }
        }
    }
}

/** Folder and branch, each with its little icon, then the source. */
@Composable
private fun Meta(s: BridgeSession) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        MetaPiece("folder", folderName(s.cwd), Modifier.weight(1f, fill = false))
        s.branch?.takeIf { it.isNotBlank() }?.let { MetaPiece("branch", it, Modifier.weight(1f, fill = false)) }
        Text(sourceLabel(s.source), color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 10.5.sp, maxLines = 1)
    }
}

@Composable
private fun MetaPiece(icon: String, text: String, modifier: Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
        PixelIcon(icon, tint = BoardColors.dim, cell = 1.5.dp)
        Text(
            text, color = BoardColors.dim, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 10.5.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** The command on a dark slip and the buttons; [online] or the answer buttons are grey and do nothing. */
@Composable
private fun Ask(
    card: CardRequest,
    request: BridgePending,
    online: Boolean,
    onAllow: (BridgePending) -> Unit,
    onDeny: (BridgePending) -> Unit,
    onOpen: (BridgePending) -> Unit,
) {
    card.detail?.let { command ->
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = BoardColors.dim)) { append("› ") }
                append(command)
            },
            color = BoardColors.waitInk, fontFamily = FontFamily.Monospace, fontSize = 11.5.sp, lineHeight = 1.5.em,
            maxLines = SLIP_LINES, overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .padding(top = 6.dp)
                .fillMaxWidth()
                .clip(PixelShape(2.dp))
                .background(BoardColors.card2)
                .padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
    if (card.more > 0) {
        Text(
            "还有 ${card.more} 个", color = BoardColors.wait, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 11.sp,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
    Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (card.inline) {
            PixelButton(
                "拒绝", { onDeny(request) }, Modifier.weight(1f),
                kind = ButtonKind.Secondary, size = ButtonSize.Small, enabled = online,
            )
            PixelButton(
                "允许", { onAllow(request) }, Modifier.weight(1.3f),
                kind = ButtonKind.Primary, size = ButtonSize.Small, enabled = online,
            )
        } else {
            PixelButton("打开", { onOpen(request) }, Modifier.weight(1f), kind = ButtonKind.Primary, size = ButtonSize.Small)
        }
    }
}
