package local.critter.phone.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import local.critter.core.protocol.PetState
import local.critter.phone.critter.CritterSlot
import local.critter.phone.critter.CritterView
import local.critter.phone.ui.look.SkyTime
import local.critter.phone.ui.look.skyColors
import local.critter.phone.ui.meadow.MeadowBackdrop
import local.critter.phone.ui.theme.ButtonSize
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.LocalDarkTheme
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelButton
import local.critter.phone.ui.theme.WordmarkImage
import kotlin.math.max
import kotlin.math.roundToInt

/** The five bundled skins, left to right. */
private val WELCOME_SKINS = listOf("clawd", "sprig", "mochi", "peep", "bristle")

/** The meadow is 470 of the mockup's 800 dp, less on a shorter screen; the pets stand 52 dp above its bottom. */
private const val MEADOW_SHARE = 470f / 800f
private val MEADOW_MAX = 470.dp
private val GROUND_INSET = 52.dp

/**
 * The first page (design §8.2): the five pets come up out of a morning meadow one after another (`join`, 260 ms
 * apart), the logo above them, what the app is for, and the way in. At night in the dark theme.
 */
@Composable
fun WelcomePage(onStart: () -> Unit) {
    val c = Critter.colors
    val dark = LocalDarkTheme.current
    val time = if (dark) SkyTime.Night else SkyTime.Dawn
    BoxWithConstraints(Modifier.fillMaxSize().background(c.bg)) {
        val meadowHeight = minOf(MEADOW_MAX, maxHeight * MEADOW_SHARE)
        Column(Modifier.fillMaxSize()) {
            WelcomeMeadow(time, meadowHeight)
            Column(Modifier.weight(1f).fillMaxWidth().navigationBarsPadding().padding(horizontal = 26.dp)) {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 26.dp, bottom = 12.dp)) {
                    StepTitle("电脑上的会话，在手机上也看得到", size = 21.sp)
                    Spacer(Modifier.height(8.dp))
                    StepBody("每个 Claude Code 会话都是一只宠物。它们在做什么、卡在哪、要不要你确认，拿起手机就知道，还能直接回答。")
                }
                PixelButton("开始配对", onStart, Modifier.fillMaxWidth(), size = ButtonSize.Large)
                Spacer(Modifier.height(12.dp))
                SkipNote("要先在 Mac 的 Critter 里打开「允许手机连接」")
                Spacer(Modifier.height(20.dp))
            }
        }
    }
}

@Composable
private fun WelcomeMeadow(time: SkyTime, height: Dp) {
    val c = Critter.colors
    val onSky = Color(skyColors(time).onSky)
    val shade = if (time == SkyTime.Night) c.shade.copy(alpha = 0.35f) else c.ink.copy(alpha = 0.22f)
    val skins = WELCOME_SKINS.map { bundledSkin(it) }
    BoxWithConstraints(Modifier.fillMaxWidth().height(height)) {
        val density = LocalDensity.current
        val ground = height - GROUND_INSET
        val widthPx = constraints.maxWidth
        val groundPx = with(density) { ground.roundToPx() }
        val u = with(density) { max(1, 3.dp.roundToPx()) }
        val pad = with(density) { 22.dp.toPx() }
        val slots = remember(widthPx, groundPx, u) {
            // The mockup's spread(22): each pet centered in its fifth of the width inside a 22 dp margin.
            skins.mapIndexed { i, manifest ->
                val center = pad + (widthPx - 2 * pad) / skins.size * (i + 0.5f)
                CritterSlot(
                    "welcome/${WELCOME_SKINS[i]}", manifest, PetState.idle, null, dimStrength = 0.0,
                    x = (center - BASE_COLUMNS * u / 2f).roundToInt().toFloat(), y = groundPx.toFloat(), scale = u.toFloat(),
                )
            }
        }
        Box(Modifier.matchParentSize()) {
            MeadowBackdrop(time, ground, Modifier.matchParentSize())
            AndroidView(
                factory = { context ->
                    // After the first update has placed them: under the ground, then up one after another.
                    CritterView(context).also { view -> view.post { view.riseAll(staggerMs = 260, join = true) } }
                },
                modifier = Modifier.matchParentSize().clearAndSetSemantics {},
                update = { it.setActors(slots) },
            )
            Column(
                Modifier.fillMaxWidth().statusBarsPadding().padding(top = 52.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                WordmarkImage(cell = 6.dp, ink = onSky, shade = shade)
                Spacer(Modifier.height(10.dp))
                Text("for Claude Code", color = onSky.copy(alpha = 0.8f), fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 14.sp)
            }
        }
    }
}

/** A Critter's base box is 18 cells wide. */
private const val BASE_COLUMNS = 18
