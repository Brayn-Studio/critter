package local.critter.phone.service

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import local.critter.core.logic.AlertPlan
import local.critter.core.logic.AlertPlanner
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SnapshotBody
import local.critter.phone.ui.MainActivity
import local.critter.phone.ui.answer.AnswerActivity
import local.critter.phone.ui.detail.DetailActivity
import local.critter.phone.ui.stateLabel

/** Notification channels, and turning an [AlertPlan] into notifications and one buzz. */
object Alerts {
    const val CH_STATUS = "critter.status"
    const val CH_WAITING = "critter.waiting"
    const val CH_RESULT = "critter.result"

    const val STATUS_ID = 1
    private const val TAG_REQUEST = "request"
    private const val TAG_SESSION = "session"
    private const val TAG_WAITING = "waiting"
    private const val TAG_HANDLED = "handled"

    const val ACTION_ANSWER = "local.critter.phone.ANSWER"
    const val EXTRA_REQUEST_ID = "requestId"
    const val EXTRA_DECISION = "decision"
    const val DECISION_ALLOW = "allow"
    const val DECISION_DENY = "deny"

    /** The notification id of a request's notification, derived from its requestId. */
    fun notificationId(requestId: String): Int = requestId.hashCode()

    fun requestTitle(request: BridgePending, session: BridgeSession?): String {
        val name = session?.name ?: "会话"
        val what = request.summary?.takeIf { it.isNotBlank() } ?: request.toolName ?: ""
        return when (request.kind) {
            PendingKind.permission -> if (what.isEmpty()) "$name 想执行一个操作" else "$name 想 $what"
            PendingKind.question -> if (what.isEmpty()) "$name 有问题要问你" else "$name 问：$what"
            PendingKind.plan -> "$name 的计划等你批准"
            PendingKind.unknown -> "$name 需要你"
        }
    }

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_STATUS, "连接状态", NotificationManager.IMPORTANCE_LOW).apply {
                description = "显示和电脑的连接状态，保持后台连接"
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_WAITING, "等你确认", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "会话等你批准、回答或确认计划"
                enableVibration(false) // the app buzzes once per snapshot itself
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_RESULT, "做完了和出错", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "会话做完了或出错了"
            },
        )
    }

    fun statusNotification(context: Context, title: String, text: String?): Notification {
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(context, CH_STATUS)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    /**
     * Posts and withdraws notifications for [plan], and buzzes once if it says so. [body] is the new snapshot.
     * With [notify] false (the floating pile is on screen) nothing is posted, but stale ones are still withdrawn.
     */
    fun apply(context: Context, plan: AlertPlan, body: SnapshotBody, canVibrate: Boolean, notify: Boolean = true) {
        val nm = context.getSystemService(NotificationManager::class.java)
        plan.cancel.forEach { nm.cancel(TAG_REQUEST, notificationId(it)) }
        plan.cancelWaitingNotices.forEach { nm.cancel(TAG_WAITING, it.hashCode()) }
        plan.cancelSessionAlerts.forEach { nm.cancel(TAG_SESSION, it.hashCode()) }
        // Leftovers the plan cannot know about (a previous process's): only worth a look when the pending set changed.
        if (plan.reconcile) reconcile(nm, body)

        if (plan.vibrate && canVibrate) vibrate(context)
        if (!notify || !canPost(context)) return
        val sessions = body.sessions.associateBy { it.id }
        plan.post.forEach { post(context, nm, it, sessions[it.sessionId]) }
        plan.waitingNotices.forEach { postWaitingNotice(context, nm, it) }
        plan.sessionAlerts.forEach { (session, state) -> postSessionResult(context, nm, session, state) }
    }

    private fun reconcile(nm: NotificationManager, body: SnapshotBody) {
        val requests = body.pending.mapTo(HashSet()) { notificationId(it.requestId) }
        val waiting = body.sessions.filter { it.state == PetState.waiting }.mapTo(HashSet()) { it.id.hashCode() }
        val finished = AlertPlanner.finishedSessions(body).mapTo(HashSet()) { it.hashCode() }
        for (n in nm.activeNotifications) {
            val stale = when (n.tag) {
                TAG_REQUEST -> n.id !in requests
                TAG_WAITING -> n.id !in waiting
                TAG_SESSION -> n.id !in finished
                else -> false
            }
            if (stale) nm.cancel(n.tag, n.id)
        }
    }

    /**
     * Withdraws every request and waiting notification: the connection service is going away (unpaired, or "保持
     * 后台连接" switched off), so nothing would withdraw them once they are answered elsewhere. With [results],
     * the done/error ones too (unpaired: they belong to a Mac this phone no longer follows).
     */
    fun withdrawAll(context: Context, results: Boolean = false) {
        val nm = context.getSystemService(NotificationManager::class.java)
        for (n in nm.activeNotifications) {
            if (n.tag == TAG_REQUEST || n.tag == TAG_WAITING || (results && n.tag == TAG_SESSION)) nm.cancel(n.tag, n.id)
        }
    }

    fun cancelRequest(context: Context, requestId: String) {
        context.getSystemService(NotificationManager::class.java).cancel(TAG_REQUEST, notificationId(requestId))
    }

    /** "已在电脑上处理", gone after 3 seconds. */
    fun showHandled(context: Context, requestId: String) {
        if (!canPost(context)) return
        val n = NotificationCompat.Builder(context, CH_RESULT)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("已在电脑上处理")
            .setTimeoutAfter(3_000)
            .setAutoCancel(true)
            .build()
        context.getSystemService(NotificationManager::class.java).notify(TAG_HANDLED, notificationId(requestId), n)
    }

    /** Only while no Do Not Disturb filter is on (spec §8.7); the system handles the notifications themselves. */
    fun vibrationAllowed(context: Context): Boolean =
        context.getSystemService(NotificationManager::class.java).currentInterruptionFilter ==
            NotificationManager.INTERRUPTION_FILTER_ALL

    private fun canPost(context: Context) =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun post(context: Context, nm: NotificationManager, request: BridgePending, session: BridgeSession?) {
        val open = PendingIntent.getActivity(
            context,
            notificationId(request.requestId),
            AnswerActivity.intent(context, request.requestId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = NotificationCompat.Builder(context, CH_WAITING)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(requestTitle(request, session))
            .setContentText(session?.cwd?.substringAfterLast('/'))
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
        // The hook gives up at expiresAt; the notification goes then even if no snapshot says so (offline).
        request.expiresAt?.let { it - System.currentTimeMillis() }?.takeIf { it > 0 }?.let { builder.setTimeoutAfter(it) }
        if (request.kind == PendingKind.permission) {
            builder.addAction(decisionAction(context, request, DECISION_ALLOW, "允许"))
            builder.addAction(decisionAction(context, request, DECISION_DENY, "拒绝"))
        } else {
            builder.addAction(NotificationCompat.Action.Builder(0, "打开", open).build())
        }
        nm.notify(TAG_REQUEST, notificationId(request.requestId), builder.build())
    }

    private fun decisionAction(
        context: Context,
        request: BridgePending,
        decision: String,
        label: String,
    ): NotificationCompat.Action {
        val intent = Intent(context, NotificationActionReceiver::class.java)
            .setAction(ACTION_ANSWER)
            // Distinct data keeps the two buttons (and different requests) from sharing one PendingIntent.
            .setData("critter://answer/${Uri.encode(request.requestId)}/$decision".toUri())
            .putExtra(EXTRA_REQUEST_ID, request.requestId)
            .putExtra(EXTRA_DECISION, decision)
        val pending = PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Action.Builder(0, label, pending)
            .setAuthenticationRequired(true)
            .build()
    }

    /** "<名字> 等你确认（请在电脑上处理）": waiting for something only the Mac can answer. Opens the session's details. */
    private fun postWaitingNotice(context: Context, nm: NotificationManager, session: BridgeSession) {
        val open = PendingIntent.getActivity(
            context,
            session.id.hashCode(),
            DetailActivity.intent(context, session.id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, CH_WAITING)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(waitingNoticeTitle(session))
            .setContentText(session.detail?.takeIf { it.isNotBlank() } ?: session.cwd.substringAfterLast('/'))
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .build()
        nm.notify(TAG_WAITING, session.id.hashCode(), n)
    }

    fun waitingNoticeTitle(session: BridgeSession): String = "${session.name} 等你确认（请在电脑上处理）"

    private fun postSessionResult(context: Context, nm: NotificationManager, session: BridgeSession, state: PetState) {
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(context, CH_RESULT)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle("${session.name} ${stateLabel(state)}")
            .setContentText(session.detail)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        nm.notify(TAG_SESSION, session.id.hashCode(), n)
    }

    private fun vibrate(context: Context) {
        val effect = VibrationEffect.createOneShot(80, VibrationEffect.DEFAULT_AMPLITUDE)
        if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(VibratorManager::class.java).defaultVibrator.vibrate(effect)
        } else {
            @Suppress("DEPRECATION")
            (context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator).vibrate(effect)
        }
    }
}
