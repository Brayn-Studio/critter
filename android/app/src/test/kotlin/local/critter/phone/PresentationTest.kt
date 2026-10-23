package local.critter.phone

import kotlinx.serialization.json.JsonObject
import local.critter.core.net.ConnState
import local.critter.core.protocol.BridgeContext
import local.critter.core.protocol.BridgeJson
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SessionSource
import local.critter.phone.bridge.NsdLocator
import local.critter.phone.service.Alerts
import local.critter.phone.service.BridgeService
import local.critter.phone.service.receiverMayOpenCard
import local.critter.phone.ui.agoText
import local.critter.phone.ui.contextPercentText
import local.critter.phone.ui.folderBranch
import local.critter.phone.ui.folderName
import local.critter.phone.ui.stateIcon
import local.critter.phone.ui.stateLabel
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class PresentationTest {
    private fun session(branch: String? = "main", cwd: String = "/Users/me/proj/") = BridgeSession(
        id = "s1", name = "proj", source = SessionSource.terminal, state = PetState.waiting, cwd = cwd,
        branch = branch, skin = "sprig", eventTime = 0, startedAt = 0, tracked = true,
    )

    private fun pending(kind: PendingKind, summary: String? = "运行 npm test") =
        BridgePending("r1", "s1", kind, toolName = "Bash", summary = summary, createdAt = 0)

    @Test
    fun stateNamesMatchTheDesktop() {
        assertEquals(
            listOf("空闲", "运行中", "等你确认", "做完了", "出错"),
            listOf(PetState.idle, PetState.running, PetState.waiting, PetState.done, PetState.error).map(::stateLabel),
        )
    }

    @Test
    fun folderBranchHandlesMissingBranchAndTrailingSlash() {
        assertEquals("proj · main", folderBranch(session()))
        assertEquals("proj", folderBranch(session(branch = null)))
        assertEquals("proj", folderName("/Users/me/proj/"))
    }

    @Test
    fun stateIconsMatchTheDesktopMarkers() {
        assertEquals(
            listOf("q", "sun", "check", "bang", "z"),
            listOf(PetState.waiting, PetState.running, PetState.done, PetState.error, PetState.idle).map(::stateIcon),
        )
        assertEquals("z", stateIcon(PetState.unknown))
    }

    @Test
    fun estimatedContextGetsAnApproxSign() {
        assertEquals("≈42%", contextPercentText(BridgeContext(41.6, estimated = true)))
        assertEquals("42%", contextPercentText(BridgeContext(41.6)))
    }

    @Test
    fun agoText() {
        assertEquals("刚刚", agoText(1_000, 30_000))
        assertEquals("5 分钟前", agoText(0, 5 * 60_000L + 1))
        assertEquals("2 小时前", agoText(0, 2 * 3_600_000L))
    }

    @Test
    fun requestTitleNamesTheSessionAndWhatItWants() {
        assertEquals("proj 想 运行 npm test", Alerts.requestTitle(pending(PendingKind.permission), session()))
        assertEquals("proj 的计划等你批准", Alerts.requestTitle(pending(PendingKind.plan), session()))
        assertEquals("会话 想执行一个操作", Alerts.requestTitle(pending(PendingKind.permission, null).copy(toolName = null), null))
    }

    @Test
    fun notificationIdsDifferPerRequestAndAreStable() {
        assertEquals(Alerts.notificationId("req-1"), Alerts.notificationId("req-1"))
        assertNotEquals(Alerts.notificationId("req-1"), Alerts.notificationId("req-2"))
    }

    @Test
    fun serviceStatusLine() {
        val body = local.critter.core.protocol.SnapshotBody(
            listOf(session(), session()), null, emptyList(),
            local.critter.core.protocol.BridgePrefs("sprig", false, 0.0, 3),
        )
        assertEquals("已连接 · 2 个会话" to "Mac", BridgeService.statusText(ConnState.Connected("Mac"), body, "Mac"))
        assertEquals("未连接", BridgeService.statusText(ConnState.Offline(2000, 0), null, "Mac").first)
        assertEquals("未连接", BridgeService.statusText(ConnState.Idle, null, null).first)
    }

    @Test
    fun bonjourNameMatching() {
        assertTrue(NsdLocator.namesMatch("Xuan's MacBook", "xuan's macbook"))
        assertTrue(NsdLocator.namesMatch("Xuan's MacBook (2)", "Xuan's MacBook"))
        assertTrue(!NsdLocator.namesMatch("Other Mac", "Xuan's MacBook"))
    }

    /** Android 12+ quietly drops an activity start from a notification button's receiver; it is not even tried. */
    @Test
    fun receiverOpensCardsOnlyBeforeAndroid12() {
        assertTrue(receiverMayOpenCard(30))
        assertFalse(receiverMayOpenCard(31))
        assertFalse(receiverMayOpenCard(36))
    }

    @Test
    fun requestTextShowsTheCommand() {
        val input = BridgeJson.parseToJsonElement("""{"command":"./gradlew test"}""") as JsonObject
        val permission = BridgePending("r1", "s1", PendingKind.permission, toolName = "Bash", summary = "运行测试", input = input, createdAt = 0)
        assertEquals("./gradlew test", Alerts.requestText(permission, session()))
        // A question shows the session's folder ("/Users/me/proj/" -> "proj"), as before.
        assertEquals("proj", Alerts.requestText(pending(PendingKind.question), session()))
        // A permission without a command or path falls back to the folder too.
        assertEquals("proj", Alerts.requestText(pending(PendingKind.permission), session()))
    }

    /** The lock screen's version names the session and nothing else: no command, no path. */
    @Test
    fun publicTitleHidesTheCommand() {
        assertEquals("proj 需要你确认", Alerts.publicTitle(session()))
        assertEquals("会话 需要你确认", Alerts.publicTitle(null))
    }

    /**
     * The lock screen's version of a request (and of a waiting notice) names the session and nothing else: not the
     * command, not what it is doing, not its folder.
     */
    @Test
    fun lockScreenTextNeverShowsTheCommand() {
        val input = BridgeJson.parseToJsonElement("""{"command":"rm -rf /tmp/secret"}""") as JsonObject
        val permission = BridgePending("r1", "s1", PendingKind.permission, toolName = "Bash", summary = "运行 rm -rf /tmp/secret", input = input, createdAt = 0)
        val busy = session(cwd = "/tmp/secret").copy(detail = "运行 rm -rf /tmp/secret")
        // Unlocked, the notification shows the command...
        assertEquals("rm -rf /tmp/secret", Alerts.requestText(permission, busy))
        // ...locked, only who is waiting.
        val locked = Alerts.lockScreenText(busy)
        assertEquals("proj 需要你确认", locked.title)
        assertEquals("解锁后查看内容", locked.text)
        for (part in listOf(locked.title, locked.text)) {
            assertFalse("rm -rf" in part, part)
            assertFalse("secret" in part, part)
        }
        assertEquals("会话 需要你确认", Alerts.lockScreenText(null).title)
    }
}
