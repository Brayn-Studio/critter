package local.critter.phone.service

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import androidx.compose.ui.graphics.toArgb
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
import local.critter.phone.R
import local.critter.phone.critter.Portraits
import local.critter.phone.repository
import local.critter.phone.ui.MainActivity
import local.critter.phone.ui.answer.AnswerActivity
import local.critter.phone.ui.answer.permissionBody
import local.critter.phone.ui.detail.DetailActivity
import local.critter.phone.ui.folderName
import local.critter.phone.ui.stateLabel
import local.critter.phone.ui.theme.LightCritterColors

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
    private const val TAG_BOARD = "board"
    private const val BOARD_BLOCKED_ID = 1

    /** The small icon's tint: Sprig purple (design §8.9). */
    private val Accent = LightCritterColors.brand.toArgb()

    /** The large icon's side in pixels: the session's Critter on its state's pale tile. */
    private const val LARGE_ICON_PX = 96
    private const val LARGE_ICON_CELL_PX = 4

    /** What the lock screen says instead of the command or the question. */
    private const val PUBLIC_TEXT = "解锁后查看内容"

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

    /** A request's notification text: the command or path of a permission, otherwise the session's folder. */
    fun requestText(request: BridgePending, session: BridgeSession?): String? =
        (if (request.kind == PendingKind.permission) permissionBody(request.input) else null)
            ?: session?.cwd?.let { folderName(it) }

    /** The lock screen's title for a request: who is waiting, nothing about what for. */
    fun publicTitle(session: BridgeSession?): String = "${session?.name ?: "会话"} 需要你确认"

    /** What the lock screen shows of a notification that waits for you. */
    data class LockScreenText(val title: String, val text: String)

    /**
     * The public version of a request or waiting notification: the session's name and "解锁后查看内容", never the
     * command, what it is doing or its folder (the notifications themselves are VISIBILITY_PRIVATE).
     */
    fun lockScreenText(session: BridgeSession?): LockScreenText = LockScreenText(publicTitle(session), PUBLIC_TEXT)

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
            .setSmallIcon(R.drawable.ic_stat_critter)
            .setColor(Accent)
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
            .setSmallIcon(R.drawable.ic_stat_critter)
            .setColor(Accent)
            .setContentTitle("已在电脑上处理")
            .setTimeoutAfter(3_000)
            .setAutoCancel(true)
            .build()
        context.getSystemService(NotificationManager::class.java).notify(TAG_HANDLED, notificationId(requestId), n)
    }

    /**
     * The board could not open by itself: the system blocked a pop-up from the background. A quiet notification
     * says so and how to allow it; 「去设置」 opens the app's details page.
     */
    fun boardBlocked(context: Context) {
        if (!canPost(context)) return
        val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:${context.packageName}".toUri())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val open = PendingIntent.getActivity(context, BOARD_BLOCKED_ID, details, PendingIntent.FLAG_IMMUTABLE)
        val text = "系统拦下了后台弹出的界面。打开「后台弹出界面」后，下次插电就能自动打开。"
        val n = NotificationCompat.Builder(context, CH_STATUS)
            .setSmallIcon(R.drawable.ic_stat_critter)
            .setColor(Accent)
            .setContentTitle("没能自动打开看板")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .addAction(NotificationCompat.Action.Builder(0, "去设置", open).build())
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setAutoCancel(true)
            .build()
        context.getSystemService(NotificationManager::class.java).notify(TAG_BOARD, BOARD_BLOCKED_ID, n)
    }

    /** The board opened by itself after all: the "blocked" notification no longer applies. */
    fun boardUnblocked(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(TAG_BOARD, BOARD_BLOCKED_ID)
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
        val text = requestText(request, session)
        val icon = largeIcon(context, session, PetState.waiting)
        val actions = if (request.kind == PendingKind.permission) {
            listOf(decisionAction(context, request, DECISION_ALLOW, "允许"), decisionAction(context, request, DECISION_DENY, "拒绝"))
        } else {
            listOf(NotificationCompat.Action.Builder(0, "打开", open).build())
        }
        // On the lock screen: who is waiting, not the command (the buttons still ask to unlock first).
        val locked = lockScreenText(session)
        val lockScreen = NotificationCompat.Builder(context, CH_WAITING)
            .setSmallIcon(R.drawable.ic_stat_critter)
            .setColor(Accent)
            .setContentTitle(locked.title)
            .setContentText(locked.text)
            .setLargeIcon(icon)
            .setContentIntent(open)
        actions.forEach { lockScreen.addAction(it) }
        val builder = NotificationCompat.Builder(context, CH_WAITING)
            .setSmallIcon(R.drawable.ic_stat_critter)
            .setColor(Accent)
            .setContentTitle(requestTitle(request, session))
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setLargeIcon(icon)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(lockScreen.build())
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
        // The hook gives up at expiresAt; the notification goes then even if no snapshot says so (offline).
        request.expiresAt?.let { it - System.currentTimeMillis() }?.takeIf { it > 0 }?.let { builder.setTimeoutAfter(it) }
        actions.forEach { builder.addAction(it) }
        nm.notify(TAG_REQUEST, notificationId(request.requestId), builder.build())
    }

    /**
     * The session's Critter standing still in its state's pose on that state's pale tile ([LARGE_ICON_PX] square,
     * corners rounded by a quarter), as on the mockup; null without a session.
     */
    private fun largeIcon(context: Context, session: BridgeSession?, state: PetState): Bitmap? {
        session ?: return null
        val manifest = context.repository.skins.library.value.manifest(session.skin)
        val still = Portraits.still(manifest, state, session.activity, LARGE_ICON_CELL_PX)
        val c = LightCritterColors
        val tile = when (state) {
            PetState.waiting -> c.waitBg
            PetState.done -> c.doneBg
            PetState.error -> c.errBg
            PetState.running -> c.runBg
            PetState.idle, PetState.unknown -> c.idleBg
        }
        val size = LARGE_ICON_PX.toFloat()
        val bitmap = Bitmap.createBitmap(LARGE_ICON_PX, LARGE_ICON_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawRoundRect(0f, 0f, size, size, size / 4, size / 4, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = tile.toArgb() })
        // Drawn 1:1 (no scaling, so no smoothing), centered, standing just above the bottom edge.
        canvas.drawBitmap(still, ((LARGE_ICON_PX - still.width) / 2).toFloat(), (LARGE_ICON_PX - still.height - LARGE_ICON_CELL_PX).toFloat(), null)
        return bitmap
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
        val icon = largeIcon(context, session, PetState.waiting)
        // What it is doing may name a command too: the lock screen only says who.
        val locked = lockScreenText(session)
        val lockScreen = NotificationCompat.Builder(context, CH_WAITING)
            .setSmallIcon(R.drawable.ic_stat_critter)
            .setColor(Accent)
            .setContentTitle(locked.title)
            .setContentText(locked.text)
            .setLargeIcon(icon)
            .setContentIntent(open)
            .build()
        val n = NotificationCompat.Builder(context, CH_WAITING)
            .setSmallIcon(R.drawable.ic_stat_critter)
            .setColor(Accent)
            .setContentTitle(waitingNoticeTitle(session))
            .setContentText(session.detail?.takeIf { it.isNotBlank() } ?: folderName(session.cwd))
            .setLargeIcon(icon)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(lockScreen)
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
            .setSmallIcon(R.drawable.ic_stat_critter)
            .setColor(Accent)
            .setContentTitle("${session.name} ${stateLabel(state)}")
            .setContentText(session.detail)
            .setLargeIcon(largeIcon(context, session, state))
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
