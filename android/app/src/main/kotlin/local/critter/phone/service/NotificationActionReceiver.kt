package local.critter.phone.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import local.critter.core.logic.AnswerDraft
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.ResultReason
import local.critter.phone.repository

/** The "允许" / "拒绝" buttons on a permission notification. */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra(Alerts.EXTRA_REQUEST_ID) ?: return
        val decision = intent.getStringExtra(Alerts.EXTRA_DECISION) ?: return
        val app = context.applicationContext
        val repo = app.repository
        val pending = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                // Answer only a request that is still in the latest snapshot (spec §8.5).
                val request = repo.snapshot.value?.pending?.firstOrNull { it.requestId == requestId }
                if (request == null || request.kind != PendingKind.permission) {
                    Alerts.cancelRequest(app, requestId)
                    Alerts.showHandled(app, requestId)
                    return@launch
                }
                val draft = AnswerDraft(request)
                if (decision == Alerts.DECISION_ALLOW) draft.allow() else draft.deny(null)
                val payload = draft.payload()
                if (payload == null || !draft.markSubmitted()) return@launch

                val result = repo.answer(requestId, payload)
                when {
                    result.ok -> Alerts.cancelRequest(app, requestId)
                    result.reason == ResultReason.resolved -> {
                        Alerts.cancelRequest(app, requestId)
                        Alerts.showHandled(app, requestId)
                    }
                    // Anything else (offline, timeout): keep the notification so it can be tried again.
                    else -> withContext(Dispatchers.Main) {
                        Toast.makeText(app, result.message ?: "没有发送出去", Toast.LENGTH_SHORT).show()
                    }
                }
            } finally {
                pending.finish()
            }
        }
    }
}
