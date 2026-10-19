package local.critter.phone.service

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import local.critter.core.logic.AnswerDraft
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.ResultReason
import local.critter.phone.repository
import local.critter.phone.ui.answer.AnswerActivity

/**
 * The "允许" / "拒绝" buttons on a permission notification. The process may have just been started for this (vivo
 * kills or freezes it with the screen off), so the answer waits for the connection to come back and for a live
 * snapshot that still lists the request ([local.critter.phone.bridge.BridgeRepository.answerWhenLive]).
 */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra(Alerts.EXTRA_REQUEST_ID) ?: return
        val decision = intent.getStringExtra(Alerts.EXTRA_DECISION) ?: return
        val app = context.applicationContext
        val repo = app.repository

        // setAuthenticationRequired makes the system unlock first, but not below API 31 and not on every OEM's
        // SystemUI. Never answer from a locked phone: open the card, which asks to unlock before it sends.
        if (app.getSystemService(KeyguardManager::class.java).isKeyguardLocked) {
            openCard(app, requestId, locked = true)
            return
        }

        val pending = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                val result = repo.answerWhenLive(requestId) { request ->
                    if (request.kind != PendingKind.permission) return@answerWhenLive null
                    val draft = AnswerDraft(request)
                    if (decision == Alerts.DECISION_ALLOW) draft.allow() else draft.deny(null)
                    draft.payload()
                }
                when {
                    result.ok -> Alerts.cancelRequest(app, requestId)
                    result.reason == ResultReason.resolved -> {
                        Alerts.cancelRequest(app, requestId)
                        Alerts.showHandled(app, requestId)
                    }
                    result.reason == ResultReason.invalid -> withContext(Dispatchers.Main) { openCard(app, requestId, locked = false) }
                    // Anything else (no connection, timeout): keep the notification so it can be tried again.
                    else -> withContext(Dispatchers.Main) {
                        Toast.makeText(app, result.message ?: "没有发送出去", Toast.LENGTH_SHORT).show()
                    }
                }
            } finally {
                pending.finish()
            }
        }
    }

    /**
     * The answer card for [requestId]. From Android 12 on, the system quietly drops an activity start from a
     * notification button's receiver, so it is not tried there: a Toast points at the notification's body, which
     * opens the same card (the notification stays). [locked]: the phone has to be unlocked first.
     */
    private fun openCard(context: Context, requestId: String, locked: Boolean) {
        if (!receiverMayOpenCard(Build.VERSION.SDK_INT)) {
            Toast.makeText(context, if (locked) "先解锁手机，再点通知正文回答" else "点通知正文打开卡片", Toast.LENGTH_SHORT).show()
            return
        }
        try {
            context.startActivity(AnswerActivity.intent(context, requestId).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: RuntimeException) {
            Log.w("CritterNotify", "could not open the answer card", e)
        }
        if (locked) Toast.makeText(context, "先解锁手机再回答", Toast.LENGTH_SHORT).show()
    }
}

/** Whether a notification button's receiver may start the answer card: only before Android 12 (API 31). */
fun receiverMayOpenCard(sdk: Int): Boolean = sdk < 31
