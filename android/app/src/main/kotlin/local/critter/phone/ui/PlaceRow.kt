package local.critter.phone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import local.critter.core.protocol.BridgeSession
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelIcon

/** The widest the folder gets (icon included). */
private val FolderMax = 104.dp

/**
 * "proj · main · 终端" as three pieces, each with its pixel icon, on the home cards and in the sheets' header. The
 * branch is cut short first; a very long folder stops at [FolderMax], so the source stays in view.
 */
@Composable
fun PlaceRow(session: BridgeSession, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        PlacePiece("folder", folderName(session.cwd), Modifier.widthIn(max = FolderMax))
        session.branch?.takeIf { it.isNotBlank() }?.let { PlacePiece("branch", it, Modifier.weight(1f, fill = false)) }
        PlacePiece(sourceIcon(session.source), sourceLabel(session.source))
    }
}

@Composable
private fun PlacePiece(icon: String, text: String, modifier: Modifier = Modifier) {
    val c = Critter.colors
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
        PixelIcon(icon, tint = c.ink2)
        Text(
            text, color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}
