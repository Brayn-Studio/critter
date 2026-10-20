package local.critter.phone.ui

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

/** The pixel icon for a state, the same marks the desktop pet wears ([local.critter.phone.ui.look.PixelIcons]). */
fun stateIcon(s: PetState): String = when (s) {
    PetState.waiting -> "q"
    PetState.running -> "sun"
    PetState.done -> "check"
    PetState.error -> "bang"
    PetState.idle, PetState.unknown -> "z"
}

fun sourceLabel(source: SessionSource): String = when (source) {
    SessionSource.terminal -> "终端"
    SessionSource.vscode -> "VS Code"
    SessionSource.desktop -> "桌面版"
    SessionSource.other -> "其它"
    SessionSource.codex -> "Codex"
    SessionSource.codex_terminal -> "Codex · 终端"
    SessionSource.codex_vscode -> "Codex · VS Code"
    SessionSource.codex_desktop -> "Codex · Desktop"
}

/** The pixel icon for where a session runs. */
fun sourceIcon(source: SessionSource): String = when (source) {
    SessionSource.terminal, SessionSource.codex_terminal -> "term"
    SessionSource.vscode, SessionSource.codex_vscode -> "editor"
    SessionSource.desktop, SessionSource.other, SessionSource.codex, SessionSource.codex_desktop -> "laptop"
}

/** Old phones cached Codex as `other`; its namespaced id still identifies the provider. */
fun isCodexSession(session: BridgeSession): Boolean = session.source in setOf(
    SessionSource.codex, SessionSource.codex_terminal, SessionSource.codex_vscode, SessionSource.codex_desktop,
) || (session.source == SessionSource.other && session.id.startsWith("codex-"))

fun visibleSessionSource(session: BridgeSession): SessionSource =
    if (session.source == SessionSource.other && isCodexSession(session)) SessionSource.codex else session.source

/** Missing capabilities preserve the older Claude route; Codex needs a verified owner. */
fun supportsMessages(session: BridgeSession): Boolean = session.capabilities?.canSay ?: !isCodexSession(session)

fun supportsAnswers(session: BridgeSession): Boolean = session.capabilities?.canAnswer ?: !isCodexSession(session)

fun canStopTurn(session: BridgeSession, online: Boolean): Boolean = online && session.capabilities?.canInterrupt == true

fun messageHint(session: BridgeSession): String = when {
    !supportsMessages(session) -> session.capabilities?.readOnlyReason?.takeIf { it.isNotBlank() }
        ?: if (isCodexSession(session)) "尚未连接 Codex 控制通道，请在电脑上继续操作" else "此会话暂时无法接收消息，请在电脑上继续操作"
    isCodexSession(session) -> "发送到当前 Codex 会话"
    else -> "Claude 会把这句话当成另一个会话发来的消息，它不能用来批准任何东西"
}

fun waitingHint(session: BridgeSession, hasActionableRequest: Boolean): String? =
    if (isCodexSession(session) && session.state == PetState.waiting && (!supportsAnswers(session) || !hasActionableRequest))
        "请在电脑上的 Codex 会话中处理这次确认" else null

/** The last path component of [cwd] ("/Users/me/proj" -> "proj"). */
fun folderName(cwd: String): String = cwd.trimEnd('/').substringAfterLast('/').ifEmpty { cwd }

/** "proj · main" (branch omitted when unknown). */
fun folderBranch(s: BridgeSession): String =
    listOfNotNull(folderName(s.cwd), s.branch?.takeIf { it.isNotBlank() }).joinToString(" · ")

/** What the session is doing: the detail line, falling back to the activity, then the state name. */
fun doingText(s: BridgeSession): String =
    s.detail?.takeIf { it.isNotBlank() } ?: s.activity?.takeIf { it.isNotBlank() } ?: stateLabel(s.state)

/** "42%", with "≈" in front when the Mac only estimated it. */
fun contextPercentText(c: BridgeContext): String =
    (if (c.estimated) "≈" else "") + "${c.usedPercent.roundToInt()}%"

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
