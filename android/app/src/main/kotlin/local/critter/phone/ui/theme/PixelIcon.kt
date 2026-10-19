package local.critter.phone.ui.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import local.critter.phone.ui.look.PixelIcons

/** One of [PixelIcons], [cell] (whole pixels) a cell, in [tint] (the text color by default); nothing for an unknown name. */
@Composable
fun PixelIcon(name: String, modifier: Modifier = Modifier, tint: Color = LocalContentColor.current, cell: Dp = 2.dp) {
    val rows = PixelIcons.rows[name] ?: return
    val runs = remember(name) { PixelIcons.runs(rows) }
    val density = LocalDensity.current
    val c = with(density) { wholePx(cell) }
    val width = with(density) { (rows[0].length * c).toDp() }
    val height = with(density) { (rows.size * c).toDp() }
    Canvas(modifier.size(width, height)) {
        for (r in runs) drawRect(tint, Offset(r[0] * c, r[1] * c), Size(r[2] * c, c))
    }
}
