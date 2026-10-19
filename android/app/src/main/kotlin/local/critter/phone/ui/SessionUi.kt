package local.critter.phone.ui

import androidx.compose.ui.graphics.Color
import local.critter.core.net.ConnState
import local.critter.core.protocol.BridgeContext
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SessionSource
import kotlin.math.roundToInt

// How a session is described on screen. Shared by the home list, the board and the notifications.

/** State names as on the desktop. */
fun stateLabel(state: PetState): String = when (state) {
    PetState.idle -> "空闲"
    PetState.running -> "运行中"
    PetState.waiting -> "等你确认"
    PetState.done -> "做完了"
    PetState.error -> "出错"
    PetState.unknown -> "未知"
}

/** A state's symbol color (design §5), for the View code; Compose screens use `Critter.colors.state()`. */
fun stateColor(state: PetState): Color = when (state) {
    PetState.running -> Color(0xFFE8A21E)
    PetState.waiting -> Color(0xFFFF9F0A)
    PetState.done -> Color(0xFF2FB457)
    PetState.error -> Color(0xFFF0453A)
    PetState.idle, PetState.unknown -> Color(0xFF8C85A3)
}

/** The pixel icon for a state, the same marks the desktop pet wears ([local.critter.phone.ui.look.PixelIcons]). */
fun stateIcon(s: PetState): String = when (s) {
    PetState.waiting -> "q"
    PetState.running -> "sun"
    PetState.done -> "check"
    PetState.error -> "bang"
    PetState.idle, PetState.unknown -> "z"
}

/** A one-character mark for the state block on the board. */
fun stateGlyph(state: PetState): String = when (state) {
    PetState.idle -> "z"
    PetState.running -> "…"
    PetState.waiting -> "!"
    PetState.done -> "✓"
    PetState.error -> "×"
    PetState.unknown -> "?"
}

fun sourceLabel(source: SessionSource): String = when (source) {
    SessionSource.terminal -> "终端"
    SessionSource.vscode -> "VS Code"
    SessionSource.desktop -> "桌面版"
    SessionSource.other -> "其它"
}

/** The pixel icon for where a session runs. */
fun sourceIcon(source: SessionSource): String = when (source) {
    SessionSource.terminal -> "term"
    SessionSource.vscode -> "editor"
    SessionSource.desktop, SessionSource.other -> "laptop"
}

/** The last path component of [cwd] ("/Users/me/proj" -> "proj"). */
fun folderName(cwd: String): String = cwd.trimEnd('/').substringAfterLast('/').ifEmpty { cwd }

/** "proj · main" (branch omitted when unknown). */
fun folderBranch(s: BridgeSession): String =
    listOfNotNull(folderName(s.cwd), s.branch?.takeIf { it.isNotBlank() }).joinToString(" · ")

/** "proj · main · 终端". */
fun placeLine(s: BridgeSession): String = "${folderBranch(s)} · ${sourceLabel(s.source)}"

/** What the session is doing: the detail line, falling back to the activity, then the state name. */
fun doingText(s: BridgeSession): String =
    s.detail?.takeIf { it.isNotBlank() } ?: s.activity?.takeIf { it.isNotBlank() } ?: stateLabel(s.state)

/** "42%", with "≈" in front when the Mac only estimated it. */
fun contextPercentText(c: BridgeContext): String =
    (if (c.estimated) "≈" else "") + "${c.usedPercent.roundToInt()}%"

fun contextFraction(c: BridgeContext): Float = (c.usedPercent / 100.0).toFloat().coerceIn(0f, 1f)

fun connText(state: ConnState): String = when (state) {
    ConnState.Idle -> "未连接"
    ConnState.Connecting -> "连接中…"
    ConnState.AwaitingApproval -> "请在 Mac 上点允许"
    is ConnState.Connected -> "已连接"
    is ConnState.Offline -> "未连接，正在重试"
    is ConnState.NeedsRepair -> state.reason
}

/** "刚刚", "5 分钟前", "3 小时前". */
fun agoText(thenMs: Long, nowMs: Long): String {
    val minutes = ((nowMs - thenMs) / 60_000).coerceAtLeast(0)
    return when {
        minutes < 1 -> "刚刚"
        minutes < 60 -> "$minutes 分钟前"
        else -> "${minutes / 60} 小时前"
    }
}
