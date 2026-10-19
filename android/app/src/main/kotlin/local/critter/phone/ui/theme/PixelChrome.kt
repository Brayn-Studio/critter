package local.critter.phone.ui.theme

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog

/** A 44 dp square pixel button with one [icon] (back, close); pressed, it sinks 3 dp like [PixelButton]. */
@Composable
fun PixelIconButton(icon: String, contentDescription: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val c = Critter.colors
    val source = remember { MutableInteractionSource() }
    val down = source.collectIsPressedAsState().value
    Box(
        modifier
            .size(44.dp)
            .clickable(source, indication = null, role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription }
            .graphicsLayer { translationY = if (down) wholePx(3.dp) else 0f }
            .pixelSurface(c.surface, step = 3.dp, lip = if (down) 1.dp else 4.dp, lipColor = c.shade)
            .padding(bottom = 3.dp),
        contentAlignment = Alignment.Center,
    ) {
        PixelIcon(icon, tint = c.ink)
    }
}

/**
 * A confirmation in the pixel material: [title], the [content] (body text in ink2 by default), then [dismissText]
 * and [confirmText] side by side, the confirm button a little wider. The content scrolls if it has to.
 */
@Composable
fun PixelDialog(
    title: String,
    confirmText: String,
    onConfirm: () -> Unit,
    dismissText: String,
    onDismiss: () -> Unit,
    confirmKind: ButtonKind = ButtonKind.Primary,
    content: @Composable ColumnScope.() -> Unit,
) {
    val c = Critter.colors
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
                .pixelSurface(c.surface, step = 5.dp, lip = 4.dp, lipColor = c.shade)
                .padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 22.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                title, color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 18.sp, lineHeight = 25.sp,
                modifier = Modifier.semantics { heading() },
            )
            Column(
                Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ProvideTextStyle(
                    TextStyle(color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 14.sp, lineHeight = 21.sp),
                ) { content() }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PixelButton(dismissText, onDismiss, Modifier.weight(1f), kind = ButtonKind.Secondary)
                PixelButton(confirmText, onConfirm, Modifier.weight(1.4f), kind = confirmKind)
            }
        }
    }
}
