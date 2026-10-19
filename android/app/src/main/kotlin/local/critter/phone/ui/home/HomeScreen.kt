package local.critter.phone.ui.home

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.widget.Toast
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import local.critter.core.logic.LimitsText
import local.critter.core.logic.SessionOrder
import local.critter.core.net.ConnState
import local.critter.core.protocol.BridgeLimits
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.RateWindow
import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.SessionSource
import local.critter.core.skin.SkinLibrary
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.critter.CritterPortrait
import local.critter.phone.ui.agoText
import local.critter.phone.ui.board.CardRequest
import local.critter.phone.ui.board.cardRequests
import local.critter.phone.ui.connText
import local.critter.phone.ui.contextPercentText
import local.critter.phone.ui.doingText
import local.critter.phone.ui.folderName
import local.critter.phone.ui.look.SkyColors
import local.critter.phone.ui.look.SkyTime
import local.critter.phone.ui.look.skyColors
import local.critter.phone.ui.meadow.Meadow
import local.critter.phone.ui.meadow.MeadowTag
import local.critter.phone.ui.meadow.PetStage
import local.critter.phone.ui.meadow.currentSkyTime
import local.critter.phone.ui.rememberMinuteClock
import local.critter.phone.ui.sourceLabel
import local.critter.phone.ui.theme.ButtonKind
import local.critter.phone.ui.theme.ButtonSize
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.LocalDarkTheme
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelButton
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.SegmentMeter
import local.critter.phone.ui.theme.Silkscreen
import local.critter.phone.ui.theme.StateChip
import local.critter.phone.ui.theme.pixelSurface
import local.critter.phone.ui.theme.rememberReduceMotion
import local.critter.phone.ui.theme.state
import local.critter.phone.ui.theme.wholePx
import local.critter.phone.ui.withKeyguardDismissed
import java.time.LocalDate
import java.time.ZoneId

/** The meadow's height (to under the status bar) and its ground line, from the top (design §8.3). */
private val MeadowHeight = 236.dp
private val MeadowGround = 200.dp

/** The skin the empty meadow's sleeper wears when the phone has none of its own (the library applies the phone's). */
private const val EMPTY_SKIN = "sprig"

/** Offline, the numbers and cards below the status card fade back. */
private const val STALE_ALPHA = 0.6f

/** The longest command shown on a card; the answer card has all of it. */
private const val SLIP_LINES = 6

/**
 * The home screen (mockup "首页"): a meadow with every session's Critter, the Mac's name and connection over it
 * and the board and settings buttons; below it the limits and the session cards, the ones that need you first.
 * A lone permission request is answered right on its card; anything else opens the answer card, and a card or a
 * Critter without a request opens the details. Offline it is night, the Critters sleep, and a card says so.
 */
@Composable
fun HomeScreen(
    repo: BridgeRepository,
    onOpenSettings: () -> Unit,
    onOpenBoard: () -> Unit,
    onOpenRequest: (requestId: String) -> Unit,
    onOpenDetail: (sessionId: String) -> Unit,
    onRepair: () -> Unit,
) {
    val context = LocalContext.current
    val state by repo.state.collectAsState()
    val snapshot by repo.snapshot.collectAsState()
    val pairing by repo.pairing.collectAsState()
    val updatedAt by repo.lastUpdated.collectAsState()
    val library by repo.skins.library.collectAsState()
    val now by rememberMinuteClock()

    val body = snapshot
    val sessions = body?.let { SessionOrder.forBoard(it) }.orEmpty()
    val requests = remember(body) { cardRequests(body) }
    val online = state is ConnState.Connected
    val offline = rememberOffline(state)
    val macName = pairing?.macName?.ifEmpty { null } ?: "Mac"
    val clockSky = currentSkyTime()
    val time = if (offline) SkyTime.Night else clockSky
    StatusBarIcons(darkIcons = time == SkyTime.Dawn || time == SkyTime.Day)

    // The opening plays once a day, the first time there are Critters to pop up.
    val today = remember { LocalDate.now().toEpochDay() }
    val opening = remember { openingDue(repo.settingsStore.settings.value.openingShownOn, today) }
    val hasSessions = sessions.isNotEmpty()
    LaunchedEffect(opening, hasSessions) {
        if (opening && hasSessions) repo.settingsStore.update { it.copy(openingShownOn = today) }
    }

    // Like a tap on a Critter anywhere (SessionTap): a request opens its card, by requestId; anything else the
    // details, and a finished session is marked seen on the way.
    fun open(session: BridgeSession) {
        val request = requests[session.id]
        if (request != null) {
            onOpenRequest(request.request.requestId)
        } else {
            if (session.state == PetState.done) repo.markSeen(session.id)
            onOpenDetail(session.id)
        }
    }

    // Nothing is sent from a locked phone (withKeyguardDismissed); a failure other than "already handled" says so.
    fun answer(request: BridgePending, allow: Boolean) {
        val activity = context.findActivity() ?: return
        activity.withKeyguardDismissed {
            repo.answerPermission(request, allow) { result ->
                if (!result.ok && result.reason != ResultReason.resolved) {
                    Toast.makeText(activity, result.message ?: "没有发送出去", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    Column(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxWidth().height(MeadowHeight)) {
            if (hasSessions) {
                Meadow(
                    sessions = sessions,
                    library = library,
                    dim = body?.prefs?.idleDim ?: 1.0,
                    time = time,
                    onTap = { id -> sessions.firstOrNull { it.id == id }?.let(::open) },
                    modifier = Modifier.fillMaxWidth(),
                    height = MeadowHeight,
                    ground = MeadowGround,
                    asleep = offline,
                    bubbles = if (offline) emptyMap() else sessions.filter { it.state == PetState.waiting }.associate { it.id to "等你确认" },
                    opening = opening,
                )
            } else {
                EmptyMeadow(library, time, offline)
            }
            MeadowHeader(
                macName = macName,
                connection = if (offline) "离线" + (updatedAt?.let { " · ${agoText(it, now)}" } ?: "") else connText(state),
                connected = online,
                sky = skyColors(time),
                onOpenBoard = onOpenBoard,
                onOpenSettings = onOpenSettings,
            )
        }

        val reduce = rememberReduceMotion()
        val insets = WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom).asPaddingValues()
        LazyColumn(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
            contentPadding = PaddingValues(top = 12.dp, bottom = insets.calculateBottomPadding() + 20.dp),
        ) {
            val down = state
            if (down is ConnState.NeedsRepair) {
                // Retrying cannot help (wrong certificate, revoked on the Mac): the way out is right here.
                item(key = "repair") {
                    StatusCard("连不上 $macName", down.reason, "重新配对", ButtonKind.Primary, onRepair)
                }
            } else if (offline) {
                item(key = "offline") {
                    val since = updatedAt?.let { agoText(it, now) }
                    val text = since?.let { "正在重试。下面是${if (it.first().isDigit()) " " else ""}${it}的样子。" } ?: "正在重试。"
                    StatusCard("连不上 $macName", text, "重试", ButtonKind.Secondary) { repo.ensureConnected() }
                }
            }
            item(key = "limits") {
                Limits(body?.limits, now, if (offline) Modifier.alpha(STALE_ALPHA) else Modifier)
            }
            if (!hasSessions) {
                item(key = "empty") { EmptyList(hasData = body != null || online) }
            } else {
                item(key = "head") { SectionHead(sessions.size) }
                items(sessions, key = { "session:${it.id}" }) { s ->
                    val request = requests[s.id]
                    SessionCard(
                        session = s,
                        request = request,
                        answer = inlineAnswer(request, online),
                        library = library,
                        offline = offline,
                        onOpen = { open(s) },
                        onOpenRequest = { onOpenRequest(it.requestId) },
                        onAnswer = ::answer,
                        modifier = reorder(reduce)
                            .padding(start = 14.dp, end = 14.dp, bottom = 10.dp)
                            .then(if (offline) Modifier.alpha(STALE_ALPHA) else Modifier),
                    )
                }
            }
        }
    }
}

/** Cards glide to their new place (one that starts needing you, to the top); under reduce motion they only fade. */
private fun LazyItemScope.reorder(reduce: Boolean): Modifier =
    if (reduce) Modifier.animateItem(fadeInSpec = tween(150), placementSpec = null, fadeOutSpec = tween(150))
    else Modifier.animateItem()

/**
 * Offline once an attempt has failed, until connected again: a retry's brief "connecting" stays offline (no flicker
 * between night and day), while the first connect after the app starts does not look offline.
 */
@Composable
private fun rememberOffline(state: ConnState): Boolean {
    var lost by remember { mutableStateOf(false) }
    val offline = when (state) {
        is ConnState.Connected -> false
        is ConnState.Offline, is ConnState.NeedsRepair -> true
        else -> lost
    }
    SideEffect { lost = offline }
    return offline
}

/** Dark status bar icons on the dawn and day skies, light ones at dusk and night; back as they were on leaving. */
@Composable
private fun StatusBarIcons(darkIcons: Boolean) {
    val view = LocalView.current
    DisposableEffect(view, darkIcons) {
        val window = view.context.findActivity()?.window
        val controller = window?.let { WindowCompat.getInsetsController(it, view) }
        val before = controller?.isAppearanceLightStatusBars
        controller?.isAppearanceLightStatusBars = darkIcons
        onDispose { if (before != null) controller.isAppearanceLightStatusBars = before }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

// ---- the meadow -------------------------------------------------------------------------------------------

/** The Mac's name and the connection on a tag at the top left, the board and settings buttons at the top right. */
@Composable
private fun MeadowHeader(
    macName: String,
    connection: String,
    connected: Boolean,
    sky: SkyColors,
    onOpenBoard: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))
            .padding(start = 18.dp, end = 14.dp, top = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                macName,
                color = Color(sky.onSky), fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 21.sp,
                letterSpacing = 0.01.em, lineHeight = 1.25.em, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            ConnectionTag(connection, connected, sky, Modifier.padding(top = 4.dp))
        }
        Spacer(Modifier.size(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            HeaderButton("board", "打开看板", onOpenBoard)
            HeaderButton("sliders", "设置", onOpenSettings)
        }
    }
}

/** A pixel dot (green with a faint ring while connected, grey otherwise) and the connection's words. */
@Composable
private fun ConnectionTag(text: String, connected: Boolean, sky: SkyColors, modifier: Modifier) {
    val c = Critter.colors
    Row(
        modifier
            .clip(PixelShape(2.dp))
            .drawBehind { drawRect(Color(sky.tag)) }
            .padding(start = 7.dp, end = 9.dp, top = 2.dp, bottom = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val dot = if (connected) c.doneGlyph else c.ink3
        Spacer(
            Modifier.size(8.dp).drawBehind {
                if (connected) {
                    val ring = wholePx(2.dp)
                    drawRect(dot.copy(alpha = 0.3f), Offset(-ring, -ring), Size(size.width + 2 * ring, size.height + 2 * ring))
                }
                drawRect(dot)
            },
        )
        Text(
            text,
            color = Color(sky.tagInk), fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 13.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** A 44 dp square pixel button with an icon; pressed, it sinks 3 dp and its bottom row shrinks, in one step. */
@Composable
private fun HeaderButton(icon: String, label: String, onClick: () -> Unit) {
    val c = Critter.colors
    val source = remember { MutableInteractionSource() }
    val down by source.collectIsPressedAsState()
    Box(
        Modifier
            .size(44.dp)
            .clickable(source, indication = null, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label }
            .graphicsLayer { translationY = if (down) wholePx(3.dp) else 0f }
            .pixelSurface(c.surface, step = 3.dp, lip = if (down) 1.dp else 4.dp, lipColor = c.shade)
            .padding(bottom = 3.dp),
        contentAlignment = Alignment.Center,
    ) {
        PixelIcon(icon, tint = c.ink)
    }
}

/** No sessions: one Critter asleep in the grass (the phone's own skin, or the sprout). */
@Composable
private fun EmptyMeadow(library: SkinLibrary, time: SkyTime, offline: Boolean) {
    Box(Modifier.fillMaxSize()) {
        PetStage(
            manifest = library.manifest(EMPTY_SKIN), state = PetState.idle, activity = null,
            modifier = Modifier.fillMaxSize(), cell = 3.dp, time = time,
            groundInset = MeadowHeight - MeadowGround, bright = !offline, asleep = true,
        )
        MeadowTag("睡着了", skyColors(time), Modifier.align(Alignment.TopCenter).offset(y = MeadowGround + 5.dp))
    }
}

// ---- the list ---------------------------------------------------------------------------------------------

/** "连不上 …": what is going on, in a card on top of the list, with the one thing to do about it. */
@Composable
private fun StatusCard(title: String, text: String, action: String, kind: ButtonKind, onAction: () -> Unit) {
    val c = Critter.colors
    Row(
        Modifier
            .padding(start = 14.dp, end = 14.dp, bottom = 12.dp)
            .fillMaxWidth()
            .pixelSurface(c.surface, step = 4.dp, lip = 4.dp, lipColor = c.shade)
            .padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PixelIcon("wifi", tint = c.ink3, cell = 3.dp)
        Column(Modifier.weight(1f)) {
            Text(title, color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 14.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(text, color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.5.sp)
        }
        PixelButton(action, onAction, kind = kind, size = ButtonSize.Small)
    }
}

/** The two limits side by side, and how old they are when the Mac has not refreshed them for a while. */
@Composable
private fun Limits(limits: BridgeLimits?, now: Long, modifier: Modifier) {
    Column(modifier.padding(horizontal = 14.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            LimitCard("5 小时额度", limits?.fiveHour, now, Modifier.weight(1f))
            LimitCard("7 天额度", limits?.sevenDay, now, Modifier.weight(1f))
        }
        limits?.let { LimitsText.staleness(it.updatedAt, now) }?.let {
            Text(
                "额度更新于 $it",
                color = Critter.colors.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 11.5.sp,
                modifier = Modifier.padding(start = 4.dp, top = 6.dp),
            )
        }
    }
}

@Composable
private fun LimitCard(title: String, window: RateWindow?, now: Long, modifier: Modifier) {
    val c = Critter.colors
    Column(
        modifier
            .pixelSurface(c.surface, step = 4.dp, lip = 4.dp, lipColor = c.shade)
            .padding(start = 13.dp, end = 13.dp, top = 11.dp, bottom = 14.dp),
    ) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                title,
                color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.sp,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).alignByBaseline(),
            )
            Text(
                percentText(LimitsText.percent(window), 17.sp),
                color = c.ink, fontFamily = Silkscreen, fontSize = 22.sp, lineHeight = 22.sp, maxLines = 1,
                modifier = Modifier.alignByBaseline(),
            )
        }
        SegmentMeter(window?.usedPercentage, 10, Modifier.padding(top = 8.dp))
        Text(
            LimitsText.resets(window, now, ZoneId.systemDefault()),
            color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 11.5.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp),
        )
    }
}

/** "会话 5". */
@Composable
private fun SectionHead(count: Int) {
    val c = Critter.colors
    Row(Modifier.padding(start = 18.dp, end = 18.dp, top = 18.dp, bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("会话", color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 14.sp, modifier = Modifier.alignByBaseline())
        Text("$count", color = c.ink2, fontFamily = Silkscreen, fontSize = 14.sp, modifier = Modifier.alignByBaseline())
    }
}

/** No sessions: the sprout, and what to do next. Before any data has come, just that there is none yet. */
@Composable
private fun EmptyList(hasData: Boolean) {
    val c = Critter.colors
    Column(
        Modifier.fillMaxWidth().padding(start = 36.dp, end = 36.dp, top = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PixelIcon("seedling", tint = c.doneGlyph, cell = 4.dp)
        Text(
            if (hasData) "电脑上还没有会话" else "还没有数据",
            color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 17.sp, textAlign = TextAlign.Center,
        )
        if (hasData) {
            Text(
                "在电脑上开一个 Claude Code 会话，它的宠物会从这片草地里钻出来。",
                color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 13.5.sp, lineHeight = 1.6.em,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/**
 * One session: its still Critter in a little patch of grass, the name and state, what it is doing, and
 * "folder · branch · source"; the context meter at the bottom. With a request it has an orange edge, the command
 * on a slip and the buttons [answer] allows.
 */
@Composable
private fun SessionCard(
    session: BridgeSession,
    request: CardRequest?,
    answer: InlineAnswer,
    library: SkinLibrary,
    offline: Boolean,
    onOpen: () -> Unit,
    onOpenRequest: (BridgePending) -> Unit,
    onAnswer: (BridgePending, Boolean) -> Unit,
    modifier: Modifier,
) {
    val c = Critter.colors
    val edge = if (request != null) 3.dp else 0.dp
    Column(
        modifier
            .fillMaxWidth()
            .pixelSurface(c.surface, step = 4.dp, lip = 4.dp, lipColor = c.shade, border = if (request != null) c.wait else null, borderWidth = 3.dp)
            .clickable(remember { MutableInteractionSource() }, indication = null, onClick = onOpen)
            .padding(start = 12.dp + edge, end = 12.dp + edge, top = 12.dp + edge, bottom = 15.dp + edge),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            GrassTile(session, library, offline)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        session.name,
                        color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 16.sp, letterSpacing = 0.01.em,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                    )
                    StateChip(session.state)
                }
                Text(
                    request?.what ?: doingText(session),
                    color = c.ink, fontFamily = Nunito, fontWeight = if (request != null) FontWeight.W800 else FontWeight.W600,
                    fontSize = 13.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                PlaceLine(session)
            }
        }
        if (request != null) Ask(request, answer, onOpenRequest, onAnswer)
        session.context?.let { ctx ->
            Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("上下文", color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 11.sp, maxLines = 1)
                SegmentMeter(ctx.usedPercent, 24, Modifier.weight(1f), height = 5.dp)
                Text(
                    percentText(contextPercentText(ctx), 11.5.sp),
                    color = c.ink2, fontFamily = Silkscreen, fontSize = 11.5.sp, textAlign = TextAlign.End, maxLines = 1,
                    modifier = Modifier.widthIn(min = 34.dp),
                )
            }
        }
    }
}

/** A 56 dp patch in the state's pale color with 7 dp of grass, the Critter standing in it, still. */
@Composable
private fun GrassTile(session: BridgeSession, library: SkinLibrary, offline: Boolean) {
    val c = Critter.colors
    val tile = if (session.state == PetState.waiting) c.waitBg else c.state(session.state).bg
    val grass = skyColors(if (LocalDarkTheme.current) SkyTime.Night else SkyTime.Day)
    Box(
        Modifier
            .size(56.dp)
            .clip(PixelShape(3.dp))
            .drawBehind {
                val band = wholePx(7.dp)
                drawRect(tile)
                drawRect(Color(grass.grass), Offset(0f, size.height - band), Size(size.width, band))
                drawRect(Color(grass.grassHi), Offset(0f, size.height - band), Size(size.width, wholePx(2.dp)))
            },
    ) {
        // Asleep offline, like the meadow (only an idle Critter can doze).
        CritterPortrait(
            library.manifest(session.skin),
            state = if (offline) PetState.idle else session.state,
            activity = if (offline) null else session.activity,
            cell = 2.dp,
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 6.dp),
            asleep = offline,
        )
    }
}

/** "proj · main · 终端" as three pieces, each with its pixel icon; the branch is cut short first. */
@Composable
private fun PlaceLine(s: BridgeSession) {
    Row(Modifier.clipToBounds(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        MetaPiece("folder", folderName(s.cwd))
        s.branch?.takeIf { it.isNotBlank() }?.let { MetaPiece("branch", it, Modifier.weight(1f, fill = false)) }
        MetaPiece(sourceIcon(s.source), sourceLabel(s.source))
    }
}

@Composable
private fun MetaPiece(icon: String, text: String, modifier: Modifier = Modifier) {
    val c = Critter.colors
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
        PixelIcon(icon, tint = c.ink2)
        Text(text, color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private fun sourceIcon(source: SessionSource): String = when (source) {
    SessionSource.terminal -> "term"
    SessionSource.vscode -> "editor"
    SessionSource.desktop, SessionSource.other -> "laptop"
}

/** The request on a card: the command on a terminal slip, then 「拒绝」「允许」 or 「打开回答」. */
@Composable
private fun Ask(
    card: CardRequest,
    answer: InlineAnswer,
    onOpenRequest: (BridgePending) -> Unit,
    onAnswer: (BridgePending, Boolean) -> Unit,
) {
    val c = Critter.colors
    Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        card.detail?.let { command ->
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = c.termDim)) { append("› ") }
                    append(command)
                },
                color = c.termInk, fontFamily = FontFamily.Monospace, fontSize = 12.5.sp, lineHeight = 1.55.em,
                maxLines = SLIP_LINES, overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(PixelShape(2.dp))
                    .drawBehind { drawRect(c.term) }
                    .padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 10.dp),
            )
        }
        when (answer) {
            InlineAnswer.AllowDeny, InlineAnswer.AllowDenyDisabled -> {
                val enabled = answer == InlineAnswer.AllowDeny
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PixelButton(
                        "拒绝", { onAnswer(card.request, false) }, Modifier.weight(1f),
                        kind = ButtonKind.Secondary, size = ButtonSize.Small, enabled = enabled,
                    )
                    PixelButton(
                        "允许", { onAnswer(card.request, true) }, Modifier.weight(1.4f),
                        kind = ButtonKind.Primary, size = ButtonSize.Small, enabled = enabled,
                    )
                }
                if (!enabled) {
                    Text(
                        "连上后才能作答",
                        color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 11.5.sp,
                        textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            InlineAnswer.Open -> PixelButton(
                "打开回答", { onOpenRequest(card.request) }, Modifier.fillMaxWidth(), kind = ButtonKind.Primary, size = ButtonSize.Small,
            )
            InlineAnswer.None -> Unit
        }
    }
}

/** A percentage with its digits in pixel type and the "%" (and "≈") in Nunito at [signSize] (design §6). */
private fun percentText(text: String, signSize: TextUnit): AnnotatedString = buildAnnotatedString {
    for (ch in text) {
        if (ch.isDigit()) append(ch) else withStyle(SpanStyle(fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = signSize)) { append(ch) }
    }
}
