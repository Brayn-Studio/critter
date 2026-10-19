package local.critter.phone.ui.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import local.critter.phone.ui.look.Wordmark
import local.critter.phone.ui.look.WordmarkCell

/** Sprig's two greens, the sprout that dots the `i` (design §6). */
private val SproutLeaf = Color(0xFF6BCB5F)
private val SproutStem = Color(0xFF3F9442)

/** The pixel "Critter", [cell] (whole pixels) a cell: a [shade] copy one cell lower, then the letters in [ink]. */
@Composable
fun WordmarkImage(cell: Dp, ink: Color, shade: Color, modifier: Modifier = Modifier) {
    val density = LocalDensity.current
    val c = with(density) { wholePx(cell) }
    val width = with(density) { (Wordmark.WIDTH * c).toDp() }
    val height = with(density) { ((Wordmark.HEIGHT + 1) * c).toDp() }
    val cells = Wordmark.cells()
    Canvas(modifier.size(width, height).semantics { contentDescription = "Critter" }) {
        val px = Size(c, c)
        for (p in cells) if (p.kind == WordmarkCell.Kind.Ink) drawRect(shade, Offset(p.x * c, (p.y + 1) * c), px)
        for (p in cells) {
            val color = when (p.kind) {
                WordmarkCell.Kind.Ink -> ink
                WordmarkCell.Kind.Leaf -> SproutLeaf
                WordmarkCell.Kind.Stem -> SproutStem
            }
            drawRect(color, Offset(p.x * c, p.y * c), px)
        }
    }
}
