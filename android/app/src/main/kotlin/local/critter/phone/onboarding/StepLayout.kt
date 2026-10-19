package local.critter.phone.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinManifest
import local.critter.phone.critter.CritterView
import local.critter.phone.repository
import local.critter.phone.ui.look.SkyTime
import local.critter.phone.ui.meadow.PetStage
import local.critter.phone.ui.meadow.currentSkyTime
import local.critter.phone.ui.theme.ButtonKind
import local.critter.phone.ui.theme.ButtonSize
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelButton
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.Silkscreen

// The look every onboarding step shares (the mockups' "首次引导与配对"), also used by the pairing screen and the
// local network gate in front of the app.

/** The side margin of a step page. */
val StepGutter = 24.dp

/** The six seeds (sprouted behind, a bud for this step, seeds ahead) and "n / 6" over a step. */
@Composable
fun SeedRow(position: StepPosition, modifier: Modifier = Modifier) {
    val c = Critter.colors
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clearAndSetSemantics { contentDescription = "第 ${position.number} 步，共 ${position.total} 步" },
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Bottom) {
            seeds(position.number - 1, position.total).forEach { s ->
                when (s) {
                    SeedState.Sprout -> PixelIcon("sprout", tint = c.doneGlyph, cell = 3.dp)
                    SeedState.Bud -> PixelIcon("bud", tint = c.brand, cell = 3.dp)
                    SeedState.Seed -> PixelIcon("seed", tint = c.ink3, cell = 3.dp)
                }
            }
        }
        Text("${position.number} / ${position.total}", color = c.ink2, fontFamily = Silkscreen, fontSize = 13.sp)
    }
}

/** A step's big title (24 sp black weight). */
@Composable
fun StepTitle(text: String, modifier: Modifier = Modifier, size: TextUnit = 24.sp, color: Color = Critter.colors.ink) {
    Text(
        text, color = color, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = size,
        lineHeight = size * 1.3f, letterSpacing = 0.01.em, modifier = modifier.semantics { heading() },
    )
}

/** A step's one sentence under the title. */
@Composable
fun StepBody(
    text: String,
    modifier: Modifier = Modifier,
    size: TextUnit = 14.5.sp,
    color: Color = Critter.colors.ink2,
    align: TextAlign = TextAlign.Start,
) {
    Text(
        text, color = color, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = size,
        lineHeight = size * 1.65f, textAlign = align, modifier = modifier,
    )
}

/** What skipping costs, in small centered type under the skip button. */
@Composable
fun SkipNote(text: String, modifier: Modifier = Modifier, color: Color = Critter.colors.ink2) {
    Text(
        text, color = color, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.sp, lineHeight = 18.sp,
        textAlign = TextAlign.Center, modifier = modifier.fillMaxWidth(),
    )
}

/**
 * One step: the seeds (when [position] is given), the [illustration], the title, the sentence and [extra], all of
 * which scroll when the type is large; then at the bottom the [primary] button, a [ghost] one (skip, or another
 * way out) and its [note]. Once [done] it says "已完成" and drops the ghost button and the note.
 */
@Composable
fun StepPage(
    position: StepPosition?,
    title: String,
    body: String,
    modifier: Modifier = Modifier,
    primary: String? = null,
    onPrimary: () -> Unit = {},
    ghost: String? = null,
    onGhost: () -> Unit = {},
    note: String? = null,
    done: Boolean = false,
    extra: @Composable ColumnScope.() -> Unit = {},
    illustration: @Composable () -> Unit,
) {
    val c = Critter.colors
    Column(modifier.fillMaxSize().background(c.bg).safeDrawingPadding().padding(horizontal = StepGutter)) {
        if (position != null) SeedRow(position, Modifier.padding(top = 8.dp))
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 12.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            illustration()
            Spacer(Modifier.height(14.dp))
            StepTitle(title)
            StepBody(body)
            if (done) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    PixelIcon("check", tint = c.done)
                    Text("已完成", color = c.done, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 14.sp)
                }
            }
            extra()
        }
        Column(
            Modifier.fillMaxWidth().padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (primary != null) PixelButton(primary, onPrimary, Modifier.fillMaxWidth(), size = ButtonSize.Large)
            if (!done && ghost != null) PixelButton(ghost, onGhost, kind = ButtonKind.Ghost)
            if (!done && note != null) SkipNote(note)
        }
    }
}

/** A bundled skin's manifest by name (the onboarding's pets are fixed, whatever skin the phone uses). */
@Composable
fun bundledSkin(name: String): SkinManifest {
    val skins = LocalContext.current.repository.skins
    return remember(name) { skins.previewLibrary.manifest(name) }
}

/** A step's picture: [skin] in [state] on a [height] patch of meadow with 6 dp steps; [overlay] sits on top. */
@Composable
fun StepStage(
    skin: String,
    state: PetState,
    modifier: Modifier = Modifier,
    height: Dp = 240.dp,
    time: SkyTime = currentSkyTime(),
    onView: (CritterView) -> Unit = {},
    overlay: @Composable BoxScope.() -> Unit = {},
) {
    Box(modifier.fillMaxWidth().height(height).clip(PixelShape(6.dp))) {
        PetStage(
            bundledSkin(skin), state, null, Modifier.matchParentSize(),
            cell = 5.dp, time = time, groundInset = 30.dp, onView = onView,
        )
        overlay()
    }
}
