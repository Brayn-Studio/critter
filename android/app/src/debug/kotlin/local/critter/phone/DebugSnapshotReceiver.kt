package local.critter.phone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import local.critter.core.protocol.BridgeContext
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgePrefs
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SessionSource
import local.critter.core.protocol.SnapshotBody

/**
 * Debug builds only, for checking the screens without a Mac:
 * `adb shell am broadcast -n local.critter.phone/.DebugSnapshotReceiver -a local.critter.phone.DEBUG_SNAPSHOT --ei count 5`
 * shows `count` made-up sessions (states cycle waiting, running, done, idle, error; skins cycle through the five
 * bundled ones). `--ez nopending true` leaves out the permission request of the first waiting session.
 */
class DebugSnapshotReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "local.critter.phone.DEBUG_SNAPSHOT") return
        val count = intent.getIntExtra("count", 5).coerceIn(0, 20)
        val states = listOf(PetState.waiting, PetState.running, PetState.done, PetState.idle, PetState.error)
        val skins = listOf("clawd", "sprig", "mochi", "peep", "bristle")
        val now = System.currentTimeMillis()
        val sessions = List(count) { i ->
            val state = states[i % states.size]
            BridgeSession(
                id = "s$i", name = "项目 $i", source = SessionSource.terminal, state = state,
                detail = when (state) {
                    PetState.waiting -> "Bash: npm test"
                    PetState.running -> "Edit: FlockView.swift"
                    PetState.done -> "README 已更新"
                    PetState.error -> "API 超时"
                    else -> null
                },
                activity = if (state == PetState.running) "edit" else null,
                cwd = "/Users/me/proj$i", branch = "main", model = "claude-haiku", context = BridgeContext(20.0 + i * 7, 200_000),
                skin = skins[i % skins.size], eventTime = now, startedAt = now - i * 60_000L, tracked = true,
            )
        }
        val pending = if (intent.getBooleanExtra("nopending", false)) emptyList() else sessions.filter { it.state == PetState.waiting }.map {
            BridgePending(
                requestId = "r-${it.id}", sessionId = it.id, kind = PendingKind.permission, toolName = "Bash",
                summary = "npm test", createdAt = now, expiresAt = null,
            )
        }
        val body = SnapshotBody(sessions, null, pending, BridgePrefs("clawd", false, 0.6, 5))
        context.applicationContext.repository.injectSnapshotForDebug(body)
    }
}
