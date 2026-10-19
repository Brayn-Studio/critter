package local.critter.phone.ui.board

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import local.critter.phone.ui.agoText
import local.critter.phone.ui.theme.BoardColors
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.SegmentMeter
import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId

// The pieces both board modes share: the clock and date lines, the dim meters and the mode button (mockup "看板").

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

/** The 40 dp mode switch at the top right: [icon] is the mode it switches to (`grid` for pro, `paw` for Critters). */
@Composable
fun BoardModeButton(icon: String, contentDescription: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(44.dp)
            .clickable(remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(40.dp).clip(PixelShape(3.dp)).background(BoardColors.card2), contentAlignment = Alignment.Center) {
            PixelIcon(icon, tint = BoardColors.dim)
        }
    }
}
