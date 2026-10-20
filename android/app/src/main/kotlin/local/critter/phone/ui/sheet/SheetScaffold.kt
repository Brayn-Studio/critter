package local.critter.phone.ui.sheet

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinManifest
import local.critter.phone.critter.CritterRenderer.Companion.BASE_COLUMNS
import local.critter.phone.critter.CritterSlot
import local.critter.phone.critter.CritterView
import local.critter.phone.ui.PlaceRow
import local.critter.phone.ui.look.SkyTime
import local.critter.phone.ui.look.skyColors
import local.critter.phone.ui.meadow.STAGE_PET
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.LocalDarkTheme
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.rememberReduceMotion
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

// The bottom sheet the answer card and the session details share (design §7, §8.5, §8.6).

/** Slides up with a slight overshoot at the end, then settles. */
private val SheetEnter = CubicBezierEasing(0.18f, 0.9f, 0.28f, 1.08f)
private const val ENTER_MS = 300
private const val EXIT_MS = 200

/** Under reduce motion every sheet transition is this long a fade. */
private const val FADE_MS = 150

/**
 * How far past its resting place the enter curve carries the sheet, as a share of its height (the curve peaks at
 * about 1.7 %): the surface is painted that much further down, so the overshoot never opens a gap under it.
 */
private const val OVERSHOOT = 0.02f

/** Room above the sheet, below the status bar, where the scrim always shows. */
private val TopRoom = 24.dp

/** Where the grabber sits, and where the content starts under it (the mockups' 10 dp padding + 2 dp margins). */
private val GrabberTop = 12.dp
private val ContentTop = 31.dp

/** The grabber over a meadow: lower and light, on the sky. */
private val GrabberTopOnMeadow = 8.dp

/**
 * A bottom sheet over a full-screen [scrim][local.critter.phone.ui.theme.CritterColors.scrim]: a surface with
 * 6 dp stepped top corners and a 40×5 grabber. It slides up in 300 ms with a slight overshoot and calls
 * [onSettled] once when it has come to rest; with [visible] false it slides down in 200 ms and then calls
 * [onHidden]. Under reduce motion both are 150 ms fades. A tap on the scrim or Back calls [onDismiss]; taps on
 * the sheet itself stay on it. The sheet rises with the keyboard and keeps clear of the navigation bar.
 *
 * The [content] starts under the grabber; with [meadowTop] it starts at the very top (it begins with a meadow,
 * the details sheet) and the grabber is drawn light over it.
 */
@Composable
fun SheetScaffold(
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    visible: Boolean = true,
    onSettled: () -> Unit = {},
    onHidden: () -> Unit = {},
    meadowTop: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    val c = Critter.colors
    val reduce = rememberReduceMotion()
    val shown = remember { MutableTransitionState(false) }
    shown.targetState = visible
    val settled by rememberUpdatedState(onSettled)
    val hidden by rememberUpdatedState(onHidden)
    var hasSettled by remember { mutableStateOf(false) }
    // At rest: shown (once) or gone. Dismissed while still coming up, it goes straight back down and is gone too.
    LaunchedEffect(shown.isIdle, shown.currentState) {
        if (!shown.isIdle) return@LaunchedEffect
        if (!shown.currentState) {
            hidden()
        } else if (!hasSettled) {
            hasSettled = true
            settled()
        }
    }
    BackHandler(enabled = visible, onBack = onDismiss)

    val scrimIn = fadeIn(tween(if (reduce) FADE_MS else ENTER_MS))
    val scrimOut = fadeOut(tween(if (reduce) FADE_MS else EXIT_MS))
    val sheetIn = if (reduce) fadeIn(tween(FADE_MS)) else slideInVertically(tween(ENTER_MS, easing = SheetEnter)) { it }
    val sheetOut = if (reduce) fadeOut(tween(FADE_MS)) else slideOutVertically(tween(EXIT_MS, easing = FastOutLinearInEasing)) { it }

    AnimatedVisibility(shown, modifier.fillMaxSize(), enter = EnterTransition.None, exit = ExitTransition.None) {
        Box(Modifier.fillMaxSize()) {
            Box(
                Modifier
                    .fillMaxSize()
                    .animateEnterExit(enter = scrimIn, exit = scrimOut)
                    .background(c.scrim)
                    .clickable(interactionSource = null, indication = null, enabled = visible, onClickLabel = "关闭", onClick = onDismiss),
            )
            Box(
                Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .padding(top = TopRoom),
                contentAlignment = Alignment.BottomCenter,
            ) {
                Box(
                    Modifier
                        .animateEnterExit(enter = sheetIn, exit = sheetOut)
                        .fillMaxWidth()
                        .imePadding()
                        .drawBehind {
                            val below = ceil(size.height * OVERSHOOT)
                            drawRect(c.surface, Offset(0f, size.height), Size(size.width, below))
                        }
                        .clip(PixelShape(6.dp, topOnly = true))
                        .background(c.surface)
                        // Taps on the sheet itself must not fall through to the scrim.
                        .pointerInput(Unit) { detectTapGestures { } }
                        .navigationBarsPadding(),
                ) {
                    // Outside a Surface the default text color is black, unreadable on the dark sheet.
                    CompositionLocalProvider(LocalContentColor provides c.ink) {
                        Column(Modifier.fillMaxWidth().padding(top = if (meadowTop) 0.dp else ContentTop), content = content)
                    }
                    Grabber(
                        onMeadow = meadowTop,
                        modifier = Modifier.align(Alignment.TopCenter).padding(top = if (meadowTop) GrabberTopOnMeadow else GrabberTop),
                    )
                }
            }
        }
    }
}

/** A sheet that only has something to say ("正在连接电脑…"). */
@Composable
fun SheetMessage(text: String) {
    Box(Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 6.dp, bottom = 30.dp), contentAlignment = Alignment.Center) {
        Text(text, color = Critter.colors.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 16.sp)
    }
}

/**
 * "Looks at you" (design §7) once both have happened, whichever comes last: the sheet has settled ([onSettled])
 * and its Critter's view exists ([onView]); once per sheet. [view] is that view, for the other cues.
 */
class LookAtYouCue {
    var view: CritterView? = null
        private set
    private var settled = false
    private var played = false

    fun onView(view: CritterView) {
        this.view = view
        // Called from the view's factory, before its Critter is set: look once that has happened.
        if (settled) view.post { play() }
    }

    fun onSettled() {
        settled = true
        play()
    }

    private fun play() {
        val v = view ?: return
        if (played) return
        played = true
        v.lookAtYou(STAGE_PET)
    }
}

/** 40×5: the line color with a darker bottom row; over a meadow, a light bar on the sky. */
@Composable
private fun Grabber(onMeadow: Boolean, modifier: Modifier) {
    val c = Critter.colors
    val bar = if (onMeadow) c.knob.copy(alpha = 0.7f) else c.line
    val lip = if (onMeadow) null else c.shade
    Box(
        modifier
            .size(40.dp, 5.dp)
            .drawBehind {
                drawRect(bar)
                if (lip != null) {
                    val h = max(1, 2.dp.roundToPx()).toFloat()
                    drawRect(lip, Offset(0f, size.height - h), Size(size.width, h))
                }
            },
    )
}

/**
 * The top of an answer card: a 72×64 tile of grass on the waiting color with the session's Critter on it (3 dp
 * cells), then the [title] in 18 sp and the place line (folder, branch, source). [onView] hands over the
 * Critter's view once it exists, for "looks at you" ([STAGE_PET] is its id).
 */
@Composable
fun SheetHeader(
    manifest: SkinManifest,
    state: PetState,
    activity: String?,
    title: String,
    session: BridgeSession?,
    onView: (CritterView) -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = Critter.colors
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        PetTile(manifest, state, activity, onView)
        Column(Modifier.weight(1f)) {
            Text(
                title, color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 18.sp, lineHeight = 23.sp,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            if (session != null) PlaceRow(session, Modifier.padding(top = 2.dp))
        }
    }
}

/** The 72×64 tile: [CritterColors.waitBg][local.critter.phone.ui.theme.CritterColors.waitBg], an 8 dp strip of grass, the Critter on it. */
@Composable
private fun PetTile(manifest: SkinManifest, state: PetState, activity: String?, onView: (CritterView) -> Unit) {
    val c = Critter.colors
    val grass = skyColors(if (LocalDarkTheme.current) SkyTime.Night else SkyTime.Day)
    val grassColor = Color(grass.grass)
    val grassTop = Color(grass.grassHi)
    Box(
        Modifier
            .size(72.dp, 64.dp)
            .clip(PixelShape(4.dp))
            .background(c.waitBg)
            .drawBehind {
                val strip = max(1, TileGrass.roundToPx()).toFloat()
                val top = max(1, 2.dp.roundToPx()).toFloat()
                drawRect(grassColor, Offset(0f, size.height - strip), Size(size.width, strip))
                drawRect(grassTop, Offset(0f, size.height - strip), Size(size.width, top))
            },
    ) {
        SheetPet(manifest, state, activity, Modifier.matchParentSize(), cell = 3.dp, groundInset = TileGrass, onView = onView)
    }
}

private val TileGrass = 8.dp

/**
 * One live Critter on a stage the size of [modifier], with no backdrop of its own (the caller paints the tile or
 * the meadow behind it): its base box centered at [centerX] of the width, its feet [groundInset] above the bottom,
 * [cell] (whole pixels) a cell, never dimmed. Its id is [STAGE_PET]; [onView] hands over the view once it exists.
 */
@Composable
internal fun SheetPet(
    manifest: SkinManifest,
    state: PetState,
    activity: String?,
    modifier: Modifier,
    cell: Dp,
    groundInset: Dp,
    centerX: Float = 0.5f,
    onView: (CritterView) -> Unit = {},
) {
    BoxWithConstraints(modifier) {
        val density = LocalDensity.current
        val u = with(density) { max(1, cell.roundToPx()) }
        val ground = (constraints.maxHeight - with(density) { groundInset.roundToPx() }).coerceAtLeast(0)
        val left = (constraints.maxWidth * centerX - BASE_COLUMNS * u / 2f).roundToInt()
        val slot = CritterSlot(
            STAGE_PET, manifest, state, activity, dimStrength = 0.0,
            x = left.toFloat(), y = ground.toFloat(), scale = u.toFloat(),
        )
        AndroidView(
            factory = { context -> CritterView(context).also(onView) },
            modifier = Modifier.matchParentSize(),
            update = { it.setActors(listOf(slot)) },
        )
    }
}
