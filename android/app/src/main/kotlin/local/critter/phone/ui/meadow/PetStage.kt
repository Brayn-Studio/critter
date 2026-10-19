package local.critter.phone.ui.meadow

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinManifest
import local.critter.phone.critter.CritterSlot
import local.critter.phone.critter.CritterView
import local.critter.phone.ui.look.SkyTime
import kotlin.math.max

/** The session id of [PetStage]'s one Critter, for the [CritterView] calls made through `onView` (`lookAtYou`). */
const val STAGE_PET = "stage"

/** How much an idle or failed Critter is dimmed on a stage that is not [PetStage]'s `bright`. */
private const val STAGE_DIM = 0.5

/**
 * A patch of meadow with one live Critter standing in the middle, [groundInset] above the bottom edge, [cell]
 * (whole pixels) a cell; [modifier] gives it its size. Decorative pets are [bright]: no idle dimming
 * (design §8.2). [onView] hands over the view once it exists, for cues like "looks at you".
 */
@Composable
fun PetStage(
    manifest: SkinManifest,
    state: PetState,
    activity: String?,
    modifier: Modifier,
    cell: Dp = 4.dp,
    time: SkyTime = currentSkyTime(),
    groundInset: Dp = 22.dp,
    bright: Boolean = true,
    asleep: Boolean = false,
    onView: (CritterView) -> Unit = {},
) {
    BoxWithConstraints(modifier) {
        val density = LocalDensity.current
        val u = with(density) { max(1, cell.roundToPx()) }
        val groundPx = constraints.maxHeight - with(density) { groundInset.roundToPx() }
        MeadowBackdrop(time, with(density) { groundPx.toDp() }, Modifier.matchParentSize())
        val slot = CritterSlot(
            STAGE_PET, manifest, state, activity, dimStrength = if (bright) 0.0 else STAGE_DIM,
            x = ((constraints.maxWidth - BASE_COLUMNS * u) / 2).toFloat(), y = groundPx.toFloat(), scale = u.toFloat(),
            sleeping = asleep,
        )
        AndroidView(
            factory = { context -> CritterView(context).also(onView) },
            modifier = Modifier.matchParentSize(),
            update = { it.setActors(listOf(slot)) },
        )
    }
}

/** A Critter's base box is 18 cells wide. */
private const val BASE_COLUMNS = 18
