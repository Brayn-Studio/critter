package local.critter.phone.ui.theme

import android.content.Context
import android.graphics.Typeface
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.AndroidFont
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontLoadingStrategy
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import local.critter.core.protocol.PetState
import local.critter.phone.R

/** The app's colors (design §5), one set per theme; read them with [Critter.colors]. */
@Immutable
data class CritterColors(
    val bg: Color,
    val surface: Color,
    val surface2: Color,
    val shade: Color,
    val line: Color,
    val ink: Color,
    val ink2: Color,
    val ink3: Color,
    val brand: Color,
    val brandDeep: Color,
    val brandSoft: Color,
    val onBrand: Color,
    val knob: Color,
    val highlight: Color,
    val run: Color,
    val runBg: Color,
    val runGlyph: Color,
    val wait: Color,
    val waitDeep: Color,
    val waitInk: Color,
    val waitBg: Color,
    val done: Color,
    val doneBg: Color,
    val doneGlyph: Color,
    val err: Color,
    val errBg: Color,
    val errGlyph: Color,
    val idle: Color,
    val idleBg: Color,
    val term: Color,
    val termInk: Color,
    val termDim: Color,
    val scrim: Color,
)

val LightCritterColors = CritterColors(
    bg = Color(0xFFF4F2FA), surface = Color(0xFFFFFFFF), surface2 = Color(0xFFEFECF7),
    shade = Color(0xFFDED7F0), line = Color(0xFFE6E1F2),
    ink = Color(0xFF2A2140), ink2 = Color(0xFF625A7A), ink3 = Color(0xFF8C85A3),
    brand = Color(0xFF6346D6), brandDeep = Color(0xFF4A30B0), brandSoft = Color(0xFFECE7FF), onBrand = Color(0xFFFFFFFF),
    knob = Color(0xFFFFFFFF), highlight = Color(0x80FFFFFF),
    run = Color(0xFFA86B00), runBg = Color(0xFFFFF1CC), runGlyph = Color(0xFFE8A21E),
    wait = Color(0xFFFF9F0A), waitDeep = Color(0xFFD97F00), waitInk = Color(0xFF9A5600), waitBg = Color(0xFFFFE9CC),
    done = Color(0xFF1E7A3A), doneBg = Color(0xFFDFF5E4), doneGlyph = Color(0xFF2FB457),
    err = Color(0xFFC42A20), errBg = Color(0xFFFFE3E0), errGlyph = Color(0xFFF0453A),
    idle = Color(0xFF625A7A), idleBg = Color(0xFFECEAF3),
    term = Color(0xFF2A2140), termInk = Color(0xFFF3F0FC), termDim = Color(0xFFA89FC8),
    scrim = Color(0x6B1A1230),
)

val DarkCritterColors = CritterColors(
    bg = Color(0xFF17142A), surface = Color(0xFF221E36), surface2 = Color(0xFF1B1830),
    shade = Color(0xFF0E0B1C), line = Color(0xFF2F2A47),
    ink = Color(0xFFF3F0FC), ink2 = Color(0xFFADA6C6), ink3 = Color(0xFF7D7698),
    brand = Color(0xFF9C88FF), brandDeep = Color(0xFF6A54D8), brandSoft = Color(0xFF2E2752), onBrand = Color(0xFF160F2E),
    knob = Color(0xFFE9E5F7), highlight = Color(0x66FFFFFF),
    run = Color(0xFFFFC655), runBg = Color(0xFF3A2F14), runGlyph = Color(0xFFF2B33D),
    wait = Color(0xFFFF9F0A), waitDeep = Color(0xFFC27200), waitInk = Color(0xFFFFB54A), waitBg = Color(0xFF3D2A12),
    done = Color(0xFF5DD47E), doneBg = Color(0xFF173324), doneGlyph = Color(0xFF5DD47E),
    err = Color(0xFFFF7A70), errBg = Color(0xFF3D1A1C), errGlyph = Color(0xFFFF7A70),
    idle = Color(0xFFADA6C6), idleBg = Color(0xFF2A2640),
    term = Color(0xFF0E0B1C), termInk = Color(0xFFF3F0FC), termDim = Color(0xFF8E86AE),
    scrim = Color(0x9905030C),
)

/** Ink on the solid waiting orange, the same in both themes (7.4:1). */
private val InkOnWait = Color(0xFF2A2140)

val LocalCritterColors = staticCompositionLocalOf { LightCritterColors }

/** Whether [CritterTheme] is dark (the meadow is always night then). */
val LocalDarkTheme = staticCompositionLocalOf { false }

object Critter {
    val colors: CritterColors
        @Composable @ReadOnlyComposable get() = LocalCritterColors.current
}

/** A state's text, background and symbol colors (a chip, a tile, a meter). */
data class StateColors(val fg: Color, val bg: Color, val glyph: Color)

/** Waiting is the one loud state: a solid orange fill with ink on it. */
fun CritterColors.state(s: PetState): StateColors = when (s) {
    PetState.running -> StateColors(run, runBg, runGlyph)
    PetState.waiting -> StateColors(InkOnWait, wait, wait)
    PetState.done -> StateColors(done, doneBg, doneGlyph)
    PetState.error -> StateColors(err, errBg, errGlyph)
    PetState.idle, PetState.unknown -> StateColors(idle, idleBg, ink3)
}

/**
 * One weight of the variable Nunito. Loaded through a plain resource font, the 'wght' axis made the Latin letters
 * heavy but the typeface still said 400, so the system font that Chinese falls back to was always the regular
 * one. Here the font is told its weight and the typeface keeps that style for the fallback too.
 */
private class NunitoFont(override val weight: FontWeight) :
    AndroidFont(FontLoadingStrategy.Blocking, NunitoLoader, FontVariation.Settings()) {
    override val style: FontStyle = FontStyle.Normal
    override fun toString() = "Nunito(${weight.weight})"
}

private object NunitoLoader : AndroidFont.TypefaceLoader {
    override fun loadBlocking(context: Context, font: AndroidFont): Typeface = nunitoTypeface(context, font.weight.weight)

    override suspend fun awaitLoad(context: Context, font: AndroidFont): Typeface = loadBlocking(context, font)
}

/**
 * Nunito at [weight], with Chinese falling back to the system font at the same weight. Also for View code (the
 * floating pile): a TextView's own `fontVariationSettings` would rebuild the typeface and lose that fallback.
 */
fun nunitoTypeface(context: Context, weight: Int): Typeface {
    val nunito = android.graphics.fonts.Font.Builder(context.resources, R.font.nunito)
        .setWeight(weight)
        .setFontVariationSettings("'wght' $weight")
        .build()
    return Typeface.CustomFallbackBuilder(android.graphics.fonts.FontFamily.Builder(nunito).build())
        .setStyle(android.graphics.fonts.FontStyle(weight, android.graphics.fonts.FontStyle.FONT_SLANT_UPRIGHT))
        .setSystemFallback("sans-serif")
        .build()
}

/** Body text and titles (a variable font; Chinese falls back to the system font, at the same weight). */
val Nunito: FontFamily = FontFamily(listOf(400, 600, 700, 800, 900).map { NunitoFont(FontWeight(it)) })

/** Numbers: the clock, percentages, counts, the pairing code. */
val Silkscreen: FontFamily = FontFamily(
    Font(R.font.silkscreen_regular, FontWeight.Normal),
    Font(R.font.silkscreen_bold, FontWeight.Bold),
)

/**
 * A percentage for a [Silkscreen] text: its digits stay in pixel type, its "%" and "≈" are in Nunito at [signSize]
 * (Silkscreen's % reads as a z when small; design §6).
 */
fun percentText(text: String, signSize: TextUnit): AnnotatedString = buildAnnotatedString {
    for (ch in text) {
        if (ch.isDigit()) append(ch) else withStyle(SpanStyle(fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = signSize)) { append(ch) }
    }
}

private fun TextStyle.nunito() = copy(fontFamily = Nunito)

private val CritterTypography = Typography().run {
    Typography(
        displayLarge = displayLarge.nunito(), displayMedium = displayMedium.nunito(), displaySmall = displaySmall.nunito(),
        headlineLarge = headlineLarge.nunito(), headlineMedium = headlineMedium.nunito(), headlineSmall = headlineSmall.nunito(),
        titleLarge = titleLarge.nunito(), titleMedium = titleMedium.nunito(), titleSmall = titleSmall.nunito(),
        // bodyLarge is every plain Text's default style. Its line height is relative, 1.5 times the text's own size
        // as in the mockups' `.app { font: 15px/1.5 }`; M3's fixed 24 sp made 11–13 sp lines twice as tall.
        bodyLarge = bodyLarge.nunito().copy(lineHeight = 1.5.em), bodyMedium = bodyMedium.nunito(), bodySmall = bodySmall.nunito(),
        labelLarge = labelLarge.nunito(), labelMedium = labelMedium.nunito(), labelSmall = labelSmall.nunito(),
    )
}

private fun CritterColors.scheme(dark: Boolean) = if (dark) {
    darkColorScheme(
        primary = brand, onPrimary = onBrand, primaryContainer = brandSoft, onPrimaryContainer = ink,
        secondary = brandDeep, onSecondary = onBrand,
        background = bg, onBackground = ink, surface = surface, onSurface = ink,
        surfaceVariant = surface2, onSurfaceVariant = ink2, outline = line, outlineVariant = line,
        error = err, onError = bg, errorContainer = errBg, onErrorContainer = err, scrim = scrim,
    )
} else {
    lightColorScheme(
        primary = brand, onPrimary = onBrand, primaryContainer = brandSoft, onPrimaryContainer = ink,
        secondary = brandDeep, onSecondary = onBrand,
        background = bg, onBackground = ink, surface = surface, onSurface = ink,
        surfaceVariant = surface2, onSurfaceVariant = ink2, outline = line, outlineVariant = line,
        error = err, onError = surface, errorContainer = errBg, onErrorContainer = err, scrim = scrim,
    )
}

@Composable
fun CritterTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val colors = if (dark) DarkCritterColors else LightCritterColors
    CompositionLocalProvider(LocalCritterColors provides colors, LocalDarkTheme provides dark) {
        MaterialTheme(colorScheme = colors.scheme(dark), typography = CritterTypography, content = content)
    }
}
