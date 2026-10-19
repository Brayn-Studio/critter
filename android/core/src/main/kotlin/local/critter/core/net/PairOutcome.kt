package local.critter.core.net

import local.critter.core.protocol.DenyReason
import local.critter.core.protocol.ServerMessage

/** Why a [BridgeClient.pair] attempt did not end in `paired`; the pairing screen says each one differently. */
enum class PairFailure {
    /** `denied badCode`: a wrong, expired or used pairing code. */
    BadCode,

    /** `denied rejected`: the user declined on the Mac. */
    Rejected,

    /** `denied protocol` (or any other reason a pairing should never get): the two apps disagree on the protocol. */
    Protocol,

    /** The Mac's certificate is not the one in the QR code. Nothing was sent. */
    CertMismatch,

    /** Nobody approved on the Mac in time: our own timeout, or the Mac closing without `denied` after its 300 s. */
    NoAnswer,

    /** No connection: refused, cut off, wrong network, or the Mac is not accepting phones. */
    Unreachable,
}

sealed interface PairResult {
    data class Paired(val paired: ServerMessage.Paired) : PairResult
    data class Failed(val why: PairFailure) : PairResult
}

/**
 * How a pairing attempt that was not approved ended, as a [PairFailure]: what the Mac said in [denied] first,
 * then a pinned-certificate mismatch anywhere in [cause], then [timedOut] or a WebSocket close without `denied`
 * ([closedCleanly], see the protocol doc's "Timeouts and limits"), and anything else is unreachable.
 */
internal fun pairFailureOf(denied: DenyReason?, cause: Throwable?, timedOut: Boolean, closedCleanly: Boolean): PairFailure =
    when {
        denied != null -> when (denied) {
            DenyReason.badCode -> PairFailure.BadCode
            DenyReason.rejected -> PairFailure.Rejected
            DenyReason.protocol, DenyReason.badToken, DenyReason.unknown -> PairFailure.Protocol
        }
        cause.hasPinMismatch() -> PairFailure.CertMismatch
        timedOut || closedCleanly -> PairFailure.NoAnswer
        else -> PairFailure.Unreachable
    }
