package local.critter.phone.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Critter's orange, the same accent the desktop pet uses for buttons. */
val CritterOrange = Color(0xFFD97757)

/** The ring around a card that has a request waiting for you. */
val WaitingOrange = Color(0xFFFF9F0A)

private val Light = lightColorScheme(
    primary = CritterOrange,
    onPrimary = Color.White,
    background = Color(0xFFF5F5F7),
    surface = Color.White,
    surfaceVariant = Color(0xFFE9E9EE),
)

private val Dark = darkColorScheme(
    primary = CritterOrange,
    onPrimary = Color.White,
    background = Color(0xFF1D1D1F),
    surface = Color(0xFF2D2D2F),
    surfaceVariant = Color(0xFF3A3A3C),
)

@Composable
fun CritterTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) Dark else Light, content = content)
}
