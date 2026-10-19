package local.critter.phone.ui.detail

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import local.critter.core.net.ConnState
import local.critter.core.protocol.BridgeContext
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.ServerMessage
import local.critter.core.skin.SkinManifest
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.critter.CritterView
import local.critter.phone.repository
import local.critter.phone.ui.agoText
import local.critter.phone.ui.doingText
import local.critter.phone.ui.meadow.MeadowBackdrop
import local.critter.phone.ui.meadow.STAGE_PET
import local.critter.phone.ui.meadow.currentSkyTime
import local.critter.phone.ui.sheet.LookAtYouCue
import local.critter.phone.ui.sheet.SheetMessage
import local.critter.phone.ui.sheet.SheetPet
import local.critter.phone.ui.sheet.SheetScaffold
import local.critter.phone.ui.sourceIcon
import local.critter.phone.ui.sourceLabel
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.CritterTheme
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelField
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.SegmentMeter
import local.critter.phone.ui.theme.Silkscreen
import local.critter.phone.ui.theme.StateChip
import local.critter.phone.ui.theme.pixelSurface
import local.critter.phone.ui.theme.rememberReduceMotion
import local.critter.phone.ui.theme.wholePx
import local.critter.phone.ui.withKeyguardDismissed
import kotlin.math.roundToInt

/** The longest message "发一句" sends. */
const val MAX_SAY_LENGTH = 4000

/** What the sheet tells the user about the Mac's receipt for a message (spec §6.4). */
fun sayFeedback(result: ServerMessage.Result): String = when {
    result.ok -> "已发送"
    result.reason == ResultReason.unavailable -> "这个会话收不到消息（可能是启动得太早，重启会话后可用）"
    else -> result.message?.takeIf { it.isNotBlank() } ?: "发送失败"
}

/** How long "这个会话已经结束" stays before the sheet closes by itself. */
private const val ENDED_CLOSE_MS = 1_500L

/** The meadow at the top of the sheet; lower while the keyboard is up, to leave room for the field. */
private val StageHeight = 150.dp
private val StageHeightTyping = 118.dp

/** The Critter's feet above the bottom of the meadow, its cell, and where it stands: a quarter of the way in. */
private val StageGround = 22.dp
private val StageCell = 4.dp
private const val STAGE_CENTER = 0.25f

/** A Critter's base box is 18 cells wide; the letter lands 14 cells above its feet, over its head. */
private const val BASE_COLUMNS = 18
private const val HEAD_ROWS = 14

/** The letter moves one step per tick of the pet's beat. */
private const val LETTER_STEP_MS = 60L

/**
 * One session's details and "发一句" (spec §8.4, design §8.5): a bottom sheet over whatever app is behind, like
 * the answer card. An activity rather than an overlay so the keyboard can come up.
 */
class DetailActivity : ComponentActivity() {
    /** The session shown; a tap on another Critter while the sheet is up (singleTop) switches it. */
    private var sessionId by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
        setContent { CritterTheme { Content(sessionId) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
    }

    override fun onStart() {
        super.onStart()
        // Opened from the floating pile or a notification, the connection may be down (a frozen process).
        repository.ensureConnected()
    }

    @Composable
    private fun Content(sessionId: String?) {
        val repo = repository
        val snapshot by repo.snapshot.collectAsState()
        val live by repo.live.collectAsState()
        val state by repo.state.collectAsState()
        val library by repo.skins.library.collectAsState()
        val session = snapshot?.sessions?.firstOrNull { it.id == sessionId }
        val now = System.currentTimeMillis()

        // The sheet slides away first; the activity finishes once it has gone.
        var shown by remember { mutableStateOf(true) }
        val cue = remember { LookAtYouCue() }

        // A session that is gone (it ended while the sheet was open): close after a moment. Missing from a cached
        // snapshot only counts once the live one had a chance to arrive.
        var waitedOut by remember(sessionId) { mutableStateOf(false) }
        LaunchedEffect(sessionId) {
            delay(BridgeRepository.LIVE_WAIT_MS)
            waitedOut = true
        }
        val gone = session == null && (live != null || waitedOut)
        LaunchedEffect(gone) {
            if (gone) {
                delay(ENDED_CLOSE_MS)
                shown = false
            }
        }

        SheetScaffold(
            onDismiss = { shown = false },
            visible = shown,
            onSettled = cue::onSettled,
            onHidden = ::finish,
            meadowTop = session != null,
        ) {
            if (session == null) {
                SheetMessage(if (gone) "这个会话已经结束" else "正在连接电脑…")
            } else {
                DetailSheet(session, library.manifest(session.skin), online = state is ConnState.Connected, now = now, cue = cue)
            }
        }
    }

    /** Where the letter takes off and where it lands, read from the layout when it is sent. */
    private class FlightMarks {
        var sheet: LayoutCoordinates? = null
        var send: LayoutCoordinates? = null
        var stage: LayoutCoordinates? = null
    }

    @Composable
    private fun DetailSheet(session: BridgeSession, manifest: SkinManifest, online: Boolean, now: Long, cue: LookAtYouCue) {
        val c = Critter.colors
        val density = LocalDensity.current
        val scope = rememberCoroutineScope()
        val reduce = rememberReduceMotion()
        var text by remember(session.id) { mutableStateOf("") }
        var busy by remember(session.id) { mutableStateOf(false) }
        var feedback by remember(session.id) { mutableStateOf<Pair<String, Boolean>?>(null) }
        var letter by remember { mutableStateOf<Offset?>(null) }
        val marks = remember { FlightMarks() }

        // With the keyboard up the meadow gets lower and the facts fold away, so the field stays in view.
        val ime = WindowInsets.ime
        val typing by remember(ime, density) { derivedStateOf { ime.getBottom(density) > 0 } }
        val stageHeight = if (typing) StageHeightTyping else StageHeight

        /** The letter flies from the send button to just over the Critter's head, then the Critter looks up at you. */
        fun flyLetter() {
            val sheet = marks.sheet?.takeIf { it.isAttached } ?: return
            val send = marks.send?.takeIf { it.isAttached } ?: return
            val stage = marks.stage?.takeIf { it.isAttached } ?: return
            with(density) {
                val cell = wholePx(2.dp)
                val half = Offset(LETTER_COLUMNS * cell / 2, LETTER_ROWS * cell / 2)
                val from = sheet.localPositionOf(send, Offset(send.size.width / 2f, send.size.height / 2f)) - half
                val u = wholePx(StageCell)
                val petLeft = (stage.size.width * STAGE_CENTER - BASE_COLUMNS * u / 2).roundToInt()
                val ground = stage.size.height - StageGround.roundToPx()
                val head = Offset(petLeft + BASE_COLUMNS * u / 2, ground - HEAD_ROWS * u)
                val to = sheet.localPositionOf(stage, head) - Offset(half.x, 0f)
                val path = letterPath(from.x to from.y, to.x to to.y, rise = 60.dp.toPx(), cell = wholePx(3.dp))
                scope.launch {
                    for ((x, y) in path) {
                        letter = Offset(x, y)
                        delay(LETTER_STEP_MS)
                    }
                    letter = null
                    cue.view?.lookAtYou(STAGE_PET)
                }
            }
        }

        fun send() {
            // Like an answer, nothing goes to the Mac from the lock screen before the phone is unlocked.
            withKeyguardDismissed {
                busy = true
                feedback = null
                scope.launch {
                    val result = repository.say(session.id, text.trim())
                    busy = false
                    feedback = sayFeedback(result) to result.ok
                    if (result.ok) {
                        text = ""
                        // Under reduce motion nothing flies: the green line says it.
                        if (!reduce) flyLetter()
                    }
                }
            }
        }

        Box(Modifier.fillMaxWidth().onGloballyPositioned { marks.sheet = it }) {
            Column {
                DetailStage(
                    session, manifest, stageHeight, cue::onView,
                    Modifier.onGloballyPositioned { marks.stage = it },
                )
                Column(
                    Modifier
                        .weight(1f, fill = false)
                        .verticalScroll(rememberScrollState())
                        .padding(start = 18.dp, end = 18.dp, top = if (typing) 12.dp else 14.dp, bottom = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(if (typing) 10.dp else 14.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            session.name, Modifier.weight(1f), color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W900,
                            fontSize = if (typing) 18.sp else 20.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                        StateChip(session.state)
                    }
                    if (!typing) Facts(session, now)

                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
                            PixelField(
                                value = text,
                                onValueChange = { text = it.take(MAX_SAY_LENGTH) },
                                placeholder = "发一句…",
                                modifier = Modifier.weight(1f),
                                enabled = !busy,
                                maxLines = 5,
                                contentDescription = "发一句",
                            )
                            SendButton(
                                enabled = online && !busy && text.isNotBlank(),
                                onClick = ::send,
                                modifier = Modifier.onGloballyPositioned { marks.send = it },
                            )
                        }
                        feedback?.let { (message, ok) -> Feedback(message, ok) }
                        Text(
                            "Claude 会把这句话当成另一个会话发来的消息，它不能用来批准任何东西",
                            color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 11.5.sp, lineHeight = 17.sp,
                        )
                    }
                }
            }
            letter?.let { p ->
                PixelIcon("letter", Modifier.offset { IntOffset(p.x.roundToInt(), p.y.roundToInt()) }, tint = c.brand)
            }
        }
    }

    /**
     * The meadow at the top: the session's Critter a quarter of the way in, going on with what it does, and a bubble
     * beside it saying what that is (one line).
     */
    @Composable
    private fun DetailStage(session: BridgeSession, manifest: SkinManifest, height: Dp, onView: (CritterView) -> Unit, modifier: Modifier) {
        BoxWithConstraints(modifier.fillMaxWidth().height(height)) {
            val density = LocalDensity.current
            val groundPx = constraints.maxHeight - with(density) { StageGround.roundToPx() }
            val ground = with(density) { groundPx.toDp() }
            val u = with(density) { wholePx(StageCell) }
            val petRight = with(density) { ((constraints.maxWidth * STAGE_CENTER - BASE_COLUMNS * u / 2).roundToInt() + BASE_COLUMNS * u).toDp() }
            MeadowBackdrop(currentSkyTime(), ground, Modifier.matchParentSize())
            SheetPet(
                manifest, session.state, session.activity, Modifier.matchParentSize(),
                cell = StageCell, groundInset = StageGround, centerX = STAGE_CENTER, onView = onView,
            )
            val bubbleLeft = petRight + 18.dp
            SideBubble(
                doingText(session),
                Modifier
                    .offset(x = bubbleLeft, y = (ground - BubbleAboveGround).coerceAtLeast(4.dp))
                    .width((maxWidth - bubbleLeft - 12.dp).coerceAtLeast(0.dp)),
            )
        }
    }

    /** What the session is doing, in a bubble whose stepped tail points left at the Critter. */
    @Composable
    private fun SideBubble(text: String, modifier: Modifier) {
        val c = Critter.colors
        val step = with(LocalDensity.current) { wholePx(2.dp) }
        val tail = with(LocalDensity.current) { (4 * step).toDp() }
        Row(modifier, verticalAlignment = Alignment.Bottom) {
            Spacer(
                Modifier
                    .padding(bottom = 4.dp)
                    .size(tail)
                    .drawBehind {
                        // Four rows, each one step wider to the left: a staircase down to the bubble's corner.
                        for (row in 0 until 4) {
                            val x = (3 - row) * step
                            drawRect(c.surface, Offset(x, row * step), Size(size.width - x, step))
                        }
                    },
            )
            Text(
                text,
                Modifier
                    .pixelSurface(c.surface, step = 3.dp, lip = 2.dp, lipColor = c.shade)
                    .padding(start = 9.dp, end = 9.dp, top = 4.dp, bottom = 6.dp),
                color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.sp, lineHeight = 16.sp,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
    }

    /** One fact: [path] is shown in monospace and cut in the middle, so both ends of it stay readable. */
    private data class FactItem(val icon: String, val label: String, val value: String, val path: Boolean = false)

    /** Two columns of facts, each with its icon; the context share takes a whole row. */
    @Composable
    private fun Facts(session: BridgeSession, now: Long) {
        val pairs = buildList {
            add(FactItem("folder", "目录", session.cwd, path = true))
            session.branch?.takeIf { it.isNotBlank() }?.let { add(FactItem("branch", "分支", it)) }
            add(FactItem(sourceIcon(session.source), "来源", sourceLabel(session.source)))
            session.model?.takeIf { it.isNotBlank() }?.let { add(FactItem("spark", "模型", it)) }
        }.chunked(2)
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            pairs.forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    row.forEach { Fact(it, Modifier.weight(1f)) }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
            // An estimated context share (the Mac could not read the real one) is marked with ≈.
            session.context?.let { ContextFact(it) }
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Fact(FactItem("dot", "最后更新", agoText(session.eventTime, now)), Modifier.weight(1f))
                Spacer(Modifier.weight(1f))
            }
        }
    }

    @Composable
    private fun Fact(fact: FactItem, modifier: Modifier) {
        val c = Critter.colors
        Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            FactLabel(fact.icon, fact.label)
            Text(
                fact.value, color = c.ink, fontFamily = if (fact.path) FontFamily.Monospace else Nunito,
                fontWeight = FontWeight.Bold, fontSize = if (fact.path) 13.sp else 14.sp,
                maxLines = 1, overflow = if (fact.path) TextOverflow.MiddleEllipsis else TextOverflow.Ellipsis,
            )
        }
    }

    @Composable
    private fun FactLabel(icon: String, label: String, modifier: Modifier = Modifier) {
        val c = Critter.colors
        Row(modifier, horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
            PixelIcon(icon, tint = c.ink2)
            Text(label, color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 11.5.sp)
        }
    }

    /** "上下文" and its share ("≈32%": the digits in Silkscreen, the marks in Nunito) over a 24-cell meter. */
    @Composable
    private fun ContextFact(context: BridgeContext) {
        val c = Critter.colors
        Column(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                FactLabel("battery", "上下文")
                Text(
                    buildAnnotatedString {
                        if (context.estimated) append("≈")
                        withStyle(SpanStyle(fontFamily = Silkscreen, fontWeight = FontWeight.Normal)) {
                            append("${context.usedPercent.roundToInt()}")
                        }
                        append("%")
                    },
                    color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 13.sp,
                )
            }
            SegmentMeter(context.usedPercent, segments = 24, modifier = Modifier.padding(top = 6.dp))
        }
    }

    /** The Mac's receipt: green with a check when it was sent, red otherwise (the text stays in the field). */
    @Composable
    private fun Feedback(message: String, ok: Boolean) {
        val c = Critter.colors
        val color = if (ok) c.done else c.err
        Row(
            Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PixelIcon(if (ok) "check" else "bang", tint = color)
            Text(message, color = color, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.5.sp)
        }
    }

    /**
     * The 48 dp send button: a primary pixel button with only the `send` icon. Pressed, it sinks 3 dp and its bottom
     * row shrinks to 1 dp, in one step.
     */
    @Composable
    private fun SendButton(enabled: Boolean, onClick: () -> Unit, modifier: Modifier) {
        val c = Critter.colors
        val source = remember { MutableInteractionSource() }
        val down = source.collectIsPressedAsState().value && enabled
        Box(
            modifier
                .clickable(source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
                .semantics { contentDescription = "发送" }
                .size(48.dp, 44.dp)
                .graphicsLayer { translationY = if (down) wholePx(3.dp) else 0f }
                .pixelSurface(
                    if (enabled) c.brand else c.surface2, step = 3.dp, lip = if (down) 1.dp else 4.dp,
                    lipColor = if (enabled) c.brandDeep else c.line, highlight = if (enabled) c.highlight else null,
                )
                .padding(bottom = 4.dp),
            contentAlignment = Alignment.Center,
        ) {
            PixelIcon("send", tint = if (enabled) c.onBrand else c.ink3)
        }
    }

    companion object {
        const val EXTRA_SESSION_ID = "sessionId"

        /** The `letter` icon is 9 × 6 cells. */
        private const val LETTER_COLUMNS = 9
        private const val LETTER_ROWS = 6

        /** The bubble's top sits this far above the Critter's feet (44 dp from the top of the 150 dp meadow). */
        private val BubbleAboveGround = 84.dp

        fun intent(context: Context, sessionId: String): Intent =
            Intent(context, DetailActivity::class.java).putExtra(EXTRA_SESSION_ID, sessionId)
    }
}
