package local.critter.phone.ui.board

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import local.critter.phone.ui.agoText
import local.critter.phone.ui.theme.BoardColors
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.SegmentMeter
import local.critter.phone.ui.theme.wholePx
import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId

// The pieces both board modes share: the clock and date lines, the dim meters and the mode button (mockup "看板").

/** The board's lines are 1.7 times their text: the mockup's board sits outside `.app` and keeps the page's 15px/1.7. */
const val BOARD_LINE = 1.7f

/** The board's default text style ([BOARD_LINE]); the app's own is 1.5 (`.app { font: 15px/1.5 }`). */
val BoardText = TextStyle(lineHeight = BOARD_LINE.em)

/**
 * One line of text [lineHeight] tall, with its glyphs where CSS puts them. The mockup's Silkscreen numbers are
 * `line-height: 1`, shorter than the font itself (1.28 em), and Compose keeps a single line at least as tall as
 * its font: the board's clock stood 8 dp low and pushed the date 15 dp down, into the first bubble. Here the text
 * keeps its own height and is centered in the line, sticking out evenly above and below, as CSS's half-leading does.
 */
fun Modifier.cssLine(lineHeight: TextUnit): Modifier = layout { measurable, constraints ->
    val text = measurable.measure(constraints.copy(minHeight = 0, maxHeight = Constraints.Infinity))
    val height = lineHeight.roundToPx()
    layout(text.width, height) { text.place(0, (height - text.height) / 2) }
}

/** "22:12". */
fun boardClockText(nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): String {
    val t = Instant.ofEpochMilli(nowMs).atZone(zone)
    return "%02d:%02d".format(t.hour, t.minute)
}

private val weekdays = mapOf(
    DayOfWeek.MONDAY to "星期一", DayOfWeek.TUESDAY to "星期二", DayOfWeek.WEDNESDAY to "星期三",
    DayOfWeek.THURSDAY to "星期四", DayOfWeek.FRIDAY to "星期五", DayOfWeek.SATURDAY to "星期六",
    DayOfWeek.SUNDAY to "星期日",
)

/** "10 月 19 日 星期日". */
fun boardDateText(nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): String {
    val d = Instant.ofEpochMilli(nowMs).atZone(zone)
    return "${d.monthValue} 月 ${d.dayOfMonth} 日 ${weekdays.getValue(d.dayOfWeek)}"
}

/** The orange line under the clock while the Mac is out of reach: "未连接 · 5 分钟前". */
fun offlineText(data: BoardData): String = "未连接" + (data.updatedAt?.let { " · ${agoText(it, data.now)}" } ?: "")

/** A number in Silkscreen with its "%" and "≈" in Nunito (Silkscreen's % reads as a z when small). */
fun boardPercent(text: String, signSize: TextUnit): AnnotatedString = buildAnnotatedString {
    for (ch in text) {
        if (ch.isDigit()) append(ch) else withStyle(SpanStyle(fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = signSize)) { append(ch) }
    }
}

/** A flat, dim meter in the board's colors. */
@Composable
fun BoardMeter(percent: Double?, segments: Int, height: Dp, modifier: Modifier = Modifier) {
    SegmentMeter(percent, segments, modifier, height = height, colors = BoardColors.meter)
}

/**
 * The 40 dp mode switch at the top right: [icon] is the mode it switches to (`grid` for pro, `paw` for Critters).
 * Pressed, it sinks 3 dp in one step, like the pixel buttons.
 */
@Composable
fun BoardModeButton(icon: String, contentDescription: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val source = remember { MutableInteractionSource() }
    val down = source.collectIsPressedAsState().value
    Box(
        modifier
            .size(44.dp)
            .clickable(source, indication = null, role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(40.dp)
                .graphicsLayer { translationY = if (down) wholePx(3.dp) else 0f }
                .clip(PixelShape(3.dp))
                .background(BoardColors.card2),
            contentAlignment = Alignment.Center,
        ) {
            PixelIcon(icon, tint = BoardColors.dim)
        }
    }
}
