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

fun stateColor(state: PetState): Color = when (state) {
    PetState.idle -> Color(0xFF8E8E93)
    PetState.running -> Color(0xFF0A84FF)
    PetState.waiting -> Color(0xFFFF9F0A)
    PetState.done -> Color(0xFF34C759)
    PetState.error -> Color(0xFFFF3B30)
    PetState.unknown -> Color(0xFF636366)
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

/** The last path component of [cwd] ("/Users/me/proj" -> "proj"). */
fun folderName(cwd: String): String = cwd.trimEnd('/').substringAfterLast('/').ifEmpty { cwd }

/** "main · proj" (branch omitted when unknown). */
fun branchAndFolder(s: BridgeSession): String =
    listOfNotNull(s.branch?.takeIf { it.isNotBlank() }, folderName(s.cwd)).joinToString(" · ")

/** "main · proj · 终端". */
fun placeLine(s: BridgeSession): String = "${branchAndFolder(s)} · ${sourceLabel(s.source)}"

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
