package local.critter.core.net

import local.critter.core.protocol.DenyReason
import java.io.IOException
import javax.net.ssl.SSLHandshakeException
import kotlin.test.Test
import kotlin.test.assertEquals

class PairOutcomeTest {
    private fun of(
        denied: DenyReason? = null,
        cause: Throwable? = null,
        timedOut: Boolean = false,
        closedCleanly: Boolean = false,
    ) = pairFailureOf(denied, cause, timedOut, closedCleanly)

    /** What JSSE hands OkHttp when the pinned trust manager refuses the Mac's certificate. */
    private fun pinFailure() = SSLHandshakeException("handshake failed").apply {
        initCause(PinMismatchException("a".repeat(64), "b".repeat(64)))
    }

    @Test fun deniedBadCodeIsBadCode() = assertEquals(PairFailure.BadCode, of(denied = DenyReason.badCode))

    @Test fun deniedRejectedIsRejected() = assertEquals(PairFailure.Rejected, of(denied = DenyReason.rejected))

    @Test fun deniedProtocolBadTokenAndUnknownAreProtocol() {
        assertEquals(PairFailure.Protocol, of(denied = DenyReason.protocol))
        assertEquals(PairFailure.Protocol, of(denied = DenyReason.badToken))
        assertEquals(PairFailure.Protocol, of(denied = DenyReason.unknown))
    }

    /** A denied reason is what the Mac said; it wins over how the socket ended afterwards. */
    @Test fun deniedWinsOverTheWayTheConnectionEnded() {
        assertEquals(PairFailure.BadCode, of(denied = DenyReason.badCode, closedCleanly = true))
        assertEquals(PairFailure.Rejected, of(denied = DenyReason.rejected, cause = IOException("reset")))
    }

    @Test fun pinMismatchIsCertMismatch() {
        assertEquals(PairFailure.CertMismatch, of(cause = pinFailure()))
        assertEquals(PairFailure.CertMismatch, of(cause = PinMismatchException("a".repeat(64), "b".repeat(64))))
    }

    /** With IPv6 then IPv4 to try, OkHttp reports the first failure and hangs the pin mismatch off it. */
    @Test fun suppressedPinMismatchIsCertMismatch() {
        val first = IOException("Connection refused").apply { addSuppressed(pinFailure()) }
        assertEquals(PairFailure.CertMismatch, of(cause = first))
    }

    @Test fun refusedConnectionIsUnreachable() =
        assertEquals(PairFailure.Unreachable, of(cause = IOException("Connection refused")))

    @Test fun noCauseAndNoCloseIsUnreachable() = assertEquals(PairFailure.Unreachable, of())

    @Test fun timeoutIsNoAnswer() = assertEquals(PairFailure.NoAnswer, of(timedOut = true))

    /** The Mac's 300 s approval wait ends with a plain close and no `denied` (protocol doc, Timeouts and limits). */
    @Test fun plainCloseWithoutDeniedIsNoAnswer() = assertEquals(PairFailure.NoAnswer, of(closedCleanly = true))
}
