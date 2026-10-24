package local.critter.phone

import local.critter.core.protocol.BridgeCapabilities
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgePrefs
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SessionSource
import local.critter.core.protocol.SnapshotBody
import local.critter.phone.ui.board.cardRequests
import local.critter.phone.ui.canStopTurn
import local.critter.phone.ui.isCodexSession
import local.critter.phone.ui.messageHint
import local.critter.phone.ui.sourceIcon
import local.critter.phone.ui.sourceLabel
import local.critter.phone.ui.supportsAnswers
import local.critter.phone.ui.supportsMessages
import local.critter.phone.ui.visibleSessionSource
import local.critter.phone.ui.waitingHint
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CodexSessionUiTest {
    private fun session(source: SessionSource = SessionSource.codex, id: String = "codex-thread") = BridgeSession(
        id = id, name = "project", source = source, state = PetState.waiting, cwd = "/project",
        skin = "sprig", eventTime = 0, startedAt = 0, tracked = true,
    )

    @Test fun codexSourcesAndOldUnknownSnapshotsAreRecognized() {
        for (source in listOf(SessionSource.codex, SessionSource.codex_terminal, SessionSource.codex_vscode, SessionSource.codex_desktop)) {
            assertTrue(isCodexSession(session(source)))
        }
        assertTrue(isCodexSession(session(SessionSource.other)))
        assertEquals(SessionSource.codex, visibleSessionSource(session(SessionSource.other)))
        assertFalse(isCodexSession(session(SessionSource.other, "claude-thread")))
        assertEquals("Codex", sourceLabel(SessionSource.codex))
        assertEquals("laptop", sourceIcon(SessionSource.codex))
        assertEquals("终端", sourceLabel(SessionSource.terminal))
    }

    @Test fun kimiAndDeepseekSourcesHaveTheirOwnLabelsAndIcons() {
        assertEquals("Kimi · Desktop", sourceLabel(SessionSource.kimi_desktop))
        assertEquals("Kimi · 终端", sourceLabel(SessionSource.kimi_terminal))
        assertEquals("DeepSeek · Desktop", sourceLabel(SessionSource.deepseek_desktop))
        assertEquals("laptop", sourceIcon(SessionSource.kimi_desktop))
        assertEquals("term", sourceIcon(SessionSource.kimi_terminal))
        assertEquals("laptop", sourceIcon(SessionSource.deepseek_desktop))
        for (source in listOf(SessionSource.kimi_desktop, SessionSource.kimi_terminal, SessionSource.deepseek_desktop)) {
            assertFalse(isCodexSession(session(source, "x-thread")))
            assertEquals(source, visibleSessionSource(session(source, "x-thread")))
        }
    }

    @Test fun kimiAndDeepseekFollowTheirExplicitCapabilities() {
        val readOnly = BridgeCapabilities(canSay = false, canAnswer = true, readOnlyReason = "只能在电脑上发消息")
        for (source in listOf(SessionSource.kimi_desktop, SessionSource.kimi_terminal, SessionSource.deepseek_desktop)) {
            val s = session(source, "x-thread").copy(capabilities = readOnly)
            assertFalse(supportsMessages(s))
            assertTrue(supportsAnswers(s))
            assertEquals("只能在电脑上发消息", messageHint(s))
            val closed = s.copy(capabilities = BridgeCapabilities(canSay = false, canAnswer = false))
            assertFalse(supportsAnswers(closed))
        }
    }

    @Test fun codexMessagesRequireAnExplicitLiveOwnerCapability() {
        assertFalse(supportsMessages(session()))
        assertFalse(supportsMessages(session(SessionSource.other)))
        assertTrue(supportsMessages(session().copy(capabilities = BridgeCapabilities(canSay = true))))
        assertFalse(supportsMessages(session().copy(capabilities = BridgeCapabilities(canAnswer = true))))
        assertTrue(supportsMessages(session(SessionSource.terminal, "claude-thread")))
    }

    @Test fun stopAndAnswersUseTheirOwnCapabilities() {
        assertFalse(supportsAnswers(session()))
        val connected = session().copy(capabilities = BridgeCapabilities(canAnswer = true, canInterrupt = true))
        assertTrue(supportsAnswers(connected))
        assertTrue(canStopTurn(connected, online = true))
        assertFalse(canStopTurn(connected, online = false))
        assertFalse(canStopTurn(session().copy(capabilities = BridgeCapabilities(canSay = true)), online = true))
        assertTrue(supportsAnswers(session(SessionSource.terminal, "claude-thread")))
    }

    @Test fun composerExplainsTheActualProviderRoute() {
        assertEquals("发送到当前 Codex 会话", messageHint(session().copy(capabilities = BridgeCapabilities(canSay = true))))
        assertEquals("此会话尚未连接", messageHint(session().copy(capabilities = BridgeCapabilities(readOnlyReason = "此会话尚未连接"))))
        assertEquals("尚未连接 Codex 控制通道，请在电脑上继续操作", messageHint(session(SessionSource.other)))
        assertEquals("Claude 会把这句话当成另一个会话发来的消息，它不能用来批准任何东西", messageHint(session(SessionSource.terminal, "claude-thread")))
    }

    @Test fun waitingWithoutAnAnswerablePhoneCardPointsToTheDesktop() {
        val answerable = session().copy(capabilities = BridgeCapabilities(canAnswer = true))
        assertNull(waitingHint(answerable, hasActionableRequest = true))
        assertEquals("请在电脑上的 Codex 会话中处理这次确认", waitingHint(answerable, hasActionableRequest = false))
        assertEquals("请在电脑上的 Codex 会话中处理这次确认", waitingHint(session(), hasActionableRequest = true))
        assertNull(waitingHint(session().copy(state = PetState.running), hasActionableRequest = false))
        assertNull(waitingHint(session(SessionSource.terminal, "claude-thread"), hasActionableRequest = false))
    }

    @Test fun cardsExposeCodexApprovalsOnlyWithAnAnswerCapability() {
        val pending = BridgePending("request", "codex-thread", PendingKind.permission, createdAt = 0)
        val body = SnapshotBody(listOf(session()), pending = listOf(pending), prefs = BridgePrefs("sprig", false, 0.5, 5))
        assertTrue(cardRequests(body).isEmpty())
        val answerable = body.copy(sessions = listOf(session().copy(capabilities = BridgeCapabilities(canAnswer = true))))
        assertEquals("request", cardRequests(answerable)["codex-thread"]?.request?.requestId)
    }
}
