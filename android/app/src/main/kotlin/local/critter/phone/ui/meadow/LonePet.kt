package local.critter.phone.ui.meadow

import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinManifest
import local.critter.phone.critter.CritterRenderer.Companion.BASE_COLUMNS
import local.critter.phone.critter.CritterSlot
import local.critter.phone.critter.CritterView
import kotlin.math.max

/**
 * One live Critter with no meadow behind it, [columns] × [rows] cells of [cell] (whole pixels), standing centered
 * on the bottom edge and never dimmed. Decorative: hidden from screen readers. [onView] hands over the view once
 * it exists; its Critter is [STAGE_PET].
 */
@Composable
fun LonePet(
    manifest: SkinManifest,
    state: PetState,
    modifier: Modifier = Modifier,
    cell: Dp = 3.dp,
    columns: Int = 22,
    rows: Int = 21,
    onView: (CritterView) -> Unit = {},
) {
    val density = LocalDensity.current
    val u = with(density) { max(1, cell.roundToPx()) }
    val slot = remember(manifest, state, u, columns, rows) {
        CritterSlot(
            STAGE_PET, manifest, state, null, dimStrength = 0.0,
            x = ((columns - BASE_COLUMNS) * u / 2).toFloat(), y = (rows * u).toFloat(), scale = u.toFloat(),
        )
    }
    AndroidView(
        factory = { context -> CritterView(context).also(onView) },
        modifier = modifier
            .size(with(density) { (columns * u).toDp() }, with(density) { (rows * u).toDp() })
            .clearAndSetSemantics {},
        update = { it.setActors(listOf(slot)) },
    )
}
