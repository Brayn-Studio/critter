package local.critter.phone

import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.ServerMessage
import local.critter.phone.ui.detail.afterSent
import local.critter.phone.ui.detail.letterPath
import local.critter.phone.ui.detail.sayFeedback
import org.junit.jupiter.api.Test
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SayFeedbackTest {
    private fun result(ok: Boolean, reason: ResultReason? = null, message: String? = null) =
        ServerMessage.Result("1", ok, reason, message)

    @Test fun okSaysSent() = assertEquals("已发送", sayFeedback(result(true)))

    @Test fun unavailableExplainsWhy() = assertEquals(
        "这个会话收不到消息（可能是启动得太早，重启会话后可用）",
        sayFeedback(result(false, ResultReason.unavailable)),
    )

    @Test fun failedShowsTheReason() = assertEquals("socket 连不上", sayFeedback(result(false, ResultReason.failed, "socket 连不上")))

    @Test fun failedWithoutAReasonStillSaysSo() = assertEquals("发送失败", sayFeedback(result(false, ResultReason.failed)))

    @Test
    fun whatWasTypedDuringTheSendStays() {
        // Nothing typed meanwhile: the field is emptied.
        assertEquals("", afterSent(current = "hello", sent = "hello"))
        // More typed after the sent words while the send was on its way: only the sent words go.
        assertEquals("还有一件事", afterSent(current = "hello 还有一件事", sent = "hello"))
        // The sent words were edited meanwhile: the field is the user's new draft and is left alone.
        assertEquals("hullo", afterSent(current = "hullo", sent = "hello"))
    }

    @Test
    fun letterArcsAndLands() {
        val path = letterPath(300f to 300f, 150f to 60f)
        assertEquals(7, path.size)
        assertEquals(150f to 60f, path.last())
        for ((x, y) in path) assertTrue(abs(x % 3f) == 0f && abs(y % 3f) == 0f, "($x, $y) is off the 3-unit grid")
        // Halfway along (the 4th of 7 steps) the letter is about 60 above the straight line.
        val straightY = 300f + (60f - 300f) * 4 / 7
        assertEquals(60f, straightY - path[3].second, 3f)
    }
}
