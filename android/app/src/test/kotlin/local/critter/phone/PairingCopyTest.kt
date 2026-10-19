package local.critter.phone

import local.critter.core.net.PairFailure
import local.critter.phone.ui.pairing.pairFailureText
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals

class PairingCopyTest {
    /** Design §8.2, copied from the spec: one sentence per reason, word for word (the "Wi‑Fi" hyphen is U+2011). */
    private val spec = mapOf(
        PairFailure.BadCode to "这个码不对，或者已经过期了。在 Mac 的「添加手机」里点「重新生成」再试。",
        PairFailure.Rejected to "Mac 上点了「拒绝」。要配对的话重新扫码，这次点「允许」。",
        PairFailure.Protocol to "这台 Mac 上的 Critter 版本和手机不一致，把两边都更新到最新再试。",
        PairFailure.CertMismatch to "这台 Mac 的证书和二维码里的不一样，已经停下。确认扫的是你自己的 Mac。",
        PairFailure.NoAnswer to "Mac 上一直没人点「允许」。回到 Mac 前，重新扫一次码。",
        PairFailure.Unreachable to "连不上这台 Mac。确认手机和电脑在同一个 Wi‑Fi，并且 Mac 上开着「允许手机连接」。",
    )

    @Test fun everyFailureSaysTheDesignsSentence() {
        assertEquals(PairFailure.entries.toSet(), spec.keys)
        for ((why, text) in spec) assertEquals(text, pairFailureText(why), why.name)
    }
}
