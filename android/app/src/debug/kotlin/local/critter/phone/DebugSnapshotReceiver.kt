package local.critter.phone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
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
 * bundled ones). `--ez nopending true` leaves out the permission requests of the waiting sessions. `--ez long true`
 * gives every session a very long name, branch and folder, and the requests a 200-character command, for checking
 * that nothing overflows. `--es kind question` or `--es kind plan` makes the requests questions or a plan instead
 * of permissions. `--es states idle,done` cycles those states instead (e.g. a calm pile, whose Critters look into
 * the screen). A paired Mac's next push replaces the made-up sessions; `--ei hold 120` keeps the Mac's
 * pushes off the screen for that many seconds (a later broadcast, or `--ei hold 0`, ends it).
 */
class DebugSnapshotReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "local.critter.phone.DEBUG_SNAPSHOT") return
        val count = intent.getIntExtra("count", 5).coerceIn(0, 20)
        val long = intent.getBooleanExtra("long", false)
        val states = intent.getStringExtra("states")?.split(',')?.mapNotNull { name -> PetState.entries.firstOrNull { it.name == name.trim() } }
            ?.takeIf { it.isNotEmpty() }
            ?: listOf(PetState.waiting, PetState.running, PetState.done, PetState.idle, PetState.error)
        val skins = listOf("sprig", "mochi", "peep", "bristle", "frill", "spout", "bonnet")
        val command = if (long) LONG_COMMAND else "npm test"
        val now = System.currentTimeMillis()
        val sessions = List(count) { i ->
            val state = states[i % states.size]
            BridgeSession(
                id = "s$i", name = if (long) "$LONG_NAME $i" else "项目 $i", source = SessionSource.terminal, state = state,
                detail = when (state) {
                    PetState.waiting -> "Bash: $command"
                    PetState.running -> "Edit: FlockView.swift"
                    PetState.done -> "README 已更新"
                    PetState.error -> "API 超时"
                    else -> null
                },
                activity = if (state == PetState.running) "edit" else null,
                cwd = if (long) "/Users/me/CODESPACE/$LONG_FOLDER$i" else "/Users/me/proj$i",
                branch = if (long) LONG_BRANCH else "main",
                model = "claude-haiku", context = BridgeContext(20.0 + i * 7, 200_000),
                skin = skins[i % skins.size], eventTime = now, startedAt = now - i * 60_000L, tracked = true,
            )
        }
        val kind = when (intent.getStringExtra("kind")) {
            "question" -> PendingKind.question
            "plan" -> PendingKind.plan
            else -> PendingKind.permission
        }
        val pending = if (intent.getBooleanExtra("nopending", false)) emptyList() else sessions.filter { it.state == PetState.waiting }.map {
            when (kind) {
                PendingKind.question -> BridgePending(
                    requestId = "r-${it.id}", sessionId = it.id, kind = kind, toolName = "AskUserQuestion",
                    summary = "DNS 缓存放在哪一层？", input = QUESTIONS, createdAt = now,
                )
                PendingKind.plan -> BridgePending(
                    requestId = "r-${it.id}", sessionId = it.id, kind = kind, toolName = "ExitPlanMode",
                    summary = null, input = buildJsonObject { put("plan", PLAN) }, createdAt = now,
                )
                else -> BridgePending(
                    requestId = "r-${it.id}", sessionId = it.id, kind = kind, toolName = "Bash",
                    summary = command, input = buildJsonObject { put("command", JsonPrimitive(command)) },
                    createdAt = now, expiresAt = null,
                )
            }
        }
        val body = SnapshotBody(sessions, null, pending, BridgePrefs("sprig", false, 0.6, 5))
        val repo = context.applicationContext.repository
        val hold = intent.getIntExtra("hold", 0)
        handler.removeCallbacksAndMessages(null)
        repo.holdForDebug(hold > 0)
        repo.injectSnapshotForDebug(body)
        if (hold > 0) handler.postDelayed({ repo.holdForDebug(false) }, hold * 1000L)
    }

    private companion object {
        val handler = Handler(Looper.getMainLooper())
        const val LONG_NAME = "这是一个名字特别特别长的会话-with-a-very-long-english-tail"
        const val LONG_BRANCH = "feature/a-really-long-branch-name-that-keeps-going"
        const val LONG_FOLDER = "a-really-long-folder-name-without-any-spaces-"

        val QUESTIONS: JsonObject = buildJsonObject {
            putJsonArray("questions") {
                addJsonObject {
                    put("header", "缓存"); put("question", "DNS 缓存放在哪一层？"); put("multiSelect", false)
                    putJsonArray("options") {
                        addJsonObject { put("label", "本地进程内"); put("description", "最快，重启就没了") }
                        addJsonObject { put("label", "Redis"); put("description", "多个实例共用，多一次网络往返") }
                    }
                }
                addJsonObject {
                    put("header", "测试"); put("question", "要补哪些测试？"); put("multiSelect", true)
                    putJsonArray("options") {
                        addJsonObject { put("label", "缓存过期"); put("description", "TTL 到了重新解析") }
                        addJsonObject { put("label", "解析失败"); put("description", "上游超时用旧值") }
                        addJsonObject { put("label", "并发"); put("description", "同一个域名只解析一次") }
                    }
                }
            }
        }

        val PLAN = """
            |# 给秋天的三篇文章换配图
            |原图太大，首页打开要 4 秒。
            |## 步骤
            |1. 把 `posts/2026-10-*` 里的 PNG 转成 WebP
            |2. 宽度统一缩到 1600px，质量 82
            |3. 更新三篇文章里的图片链接
            |4. 本地跑一遍 `npm run build`，看首页大小
            |## 不动的
            |原图保留在 originals/ 里，不删。
            |## 之后
            |- 看一周首页的打开时间
            |- 没问题再处理其他年份的文章
            |- 把转换脚本放进 tools/，以后新图自动转
        """.trimMargin()

        /** Exactly 200 characters. */
        const val LONG_COMMAND = "adb shell am start -n local.critter.phone/.ui.answer.AnswerActivity --es requestId r-s0 && " +
            "adb shell settings put system font_scale 1.3 && adb shell cmd uimode night yes && adb shell input keyevent 26"
    }
}
