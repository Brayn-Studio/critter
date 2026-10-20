package local.critter.phone.bridge

import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.ServerMessage

/**
 * The requests an answer is on its way for. A second answer to one of them while the first is out (a notification
 * button and the card tapped together) is not sent alongside it: the caller gets [alreadySending], "正在发送…".
 * Not "已在电脑上处理": it was this phone, and the first answer may still fail.
 */
class InFlight {
    private val ids = HashSet<String>()

    /** Claims [requestId]; false if an answer to it is already on its way. */
    @Synchronized
    fun start(requestId: String): Boolean = ids.add(requestId)

    @Synchronized
    fun finish(requestId: String) {
        ids.remove(requestId)
    }

    companion object {
        private const val SENDING = "正在发送…"

        /** What a second answer gets: a local `unknown`, so the card stays open and shows [SENDING] over its buttons. */
        fun alreadySending(): ServerMessage.Result =
            ServerMessage.Result(id = null, ok = false, reason = ResultReason.unknown, message = SENDING)

        /** Whether [result] is [alreadySending]: no failure of the connection, nothing to retry. */
        fun isAlreadySending(result: ServerMessage.Result): Boolean =
            !result.ok && result.reason == ResultReason.unknown && result.message == SENDING
    }
}
