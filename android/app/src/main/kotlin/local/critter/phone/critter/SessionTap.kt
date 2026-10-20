package local.critter.phone.critter

import android.content.Context
import android.content.Intent
import local.critter.core.protocol.PetState
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.ui.answer.AnswerActivity
import local.critter.phone.ui.detail.DetailActivity

/**
 * What tapping a Critter does, on the board and in the floating pile alike (spec §8.4): one with a request
 * waiting opens its answer card (always by `requestId`, the oldest request of that session); one that is done
 * is marked seen and shows its details; any other shows its details.
 */
object SessionTap {
    /** [flags] are added to the card's launch (the board adds [Intent.FLAG_ACTIVITY_NO_USER_ACTION]). */
    fun handle(context: Context, repo: BridgeRepository, sessionId: String, flags: Int = 0) {
        val body = repo.snapshot.value ?: return
        val session = body.sessions.firstOrNull { it.id == sessionId } ?: return
        val request = body.pending.filter { it.sessionId == sessionId }.minByOrNull { it.createdAt }
        val intent = if (request != null) {
            AnswerActivity.intent(context, request.requestId)
        } else {
            if (session.state == PetState.done) repo.markSeen(sessionId)
            DetailActivity.intent(context, sessionId)
        }
        // From the floating pile there is no activity to start from.
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or flags))
    }
}
