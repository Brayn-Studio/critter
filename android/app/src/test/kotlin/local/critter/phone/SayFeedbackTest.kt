package local.critter.phone

import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.ServerMessage
import local.critter.phone.ui.detail.sayFeedback
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals

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
}
