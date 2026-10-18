package local.critter.core.logic

import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.SnapshotBody

object SessionOrder {
    /** Sessions with an open request first, oldest request first; the rest keep the Mac's order. */
    fun forBoard(body: SnapshotBody): List<BridgeSession> {
        val oldestRequest = body.pending.groupBy { it.sessionId }.mapValues { (_, reqs) -> reqs.minOf { it.createdAt } }
        val (needsYou, others) = body.sessions.partition { it.id in oldestRequest }
        return needsYou.sortedBy { oldestRequest.getValue(it.id) } + others
    }
}
