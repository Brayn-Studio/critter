package local.critter.phone.ui.detail

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import local.critter.core.net.ConnState
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.ServerMessage
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.repository
import local.critter.phone.ui.agoText
import local.critter.phone.ui.contextPercentText
import local.critter.phone.ui.doingText
import local.critter.phone.ui.sourceLabel
import local.critter.phone.ui.stateColor
import local.critter.phone.ui.stateLabel
import local.critter.phone.ui.theme.CritterTheme
import local.critter.phone.ui.withKeyguardDismissed

/** The longest message "发一句" sends. */
const val MAX_SAY_LENGTH = 4000

/** What the sheet tells the user about the Mac's receipt for a message (spec §6.4). */
fun sayFeedback(result: ServerMessage.Result): String = when {
    result.ok -> "已发送"
    result.reason == ResultReason.unavailable -> "这个会话收不到消息（可能是启动得太早，重启会话后可用）"
    else -> result.message?.takeIf { it.isNotBlank() } ?: "发送失败"
}

/**
 * One session's details and "发一句" (spec §8.4): a translucent bottom sheet over whatever app is behind, like
 * the answer card. An activity rather than an overlay so the keyboard can come up.
 */
class DetailActivity : ComponentActivity() {
    /** The session shown; a tap on another Critter while the sheet is up (singleTop) switches it. */
    private var sessionId by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
        setContent { CritterTheme { Content(sessionId) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
    }

    override fun onStart() {
        super.onStart()
        // Opened from the floating pile or a notification, the connection may be down (a frozen process).
        repository.ensureConnected()
    }

    @Composable
    private fun Content(sessionId: String?) {
        val repo = repository
        val snapshot by repo.snapshot.collectAsState()
        val live by repo.live.collectAsState()
        val state by repo.state.collectAsState()
        val session = snapshot?.sessions?.firstOrNull { it.id == sessionId }
        val now = System.currentTimeMillis()

        // A session that is gone (it ended while the sheet was open): close after a moment. Missing from a cached
        // snapshot only counts once the live one had a chance to arrive.
        var waitedOut by remember(sessionId) { mutableStateOf(false) }
        LaunchedEffect(sessionId) {
            delay(BridgeRepository.LIVE_WAIT_MS)
            waitedOut = true
        }
        val gone = session == null && (live != null || waitedOut)
        LaunchedEffect(gone) {
            if (gone) {
                delay(1_500)
                finish()
            }
        }

        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.45f))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { finish() },
            contentAlignment = Alignment.BottomCenter,
        ) {
            Box(
                Modifier
                    .imePadding()
                    .navigationBarsPadding()
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
            ) {
                if (session == null) {
                    Box(
                        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface, SHEET_SHAPE).padding(28.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            if (gone) "这个会话已经结束" else "正在连接电脑…",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                } else {
                    DetailSheet(session, online = state is ConnState.Connected, now = now)
                }
            }
        }
    }

    @Composable
    private fun DetailSheet(session: BridgeSession, online: Boolean, now: Long) {
        val scope = rememberCoroutineScope()
        var text by remember(session.id) { mutableStateOf("") }
        var busy by remember(session.id) { mutableStateOf(false) }
        var feedback by remember(session.id) { mutableStateOf<Pair<String, Boolean>?>(null) }

        // Outside a Surface the default text colour is black, unreadable on the dark sheet.
        CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurface) {
        Column(
            Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surface, SHEET_SHAPE)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(session.name, style = MaterialTheme.typography.titleLarge)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stateLabel(session.state), color = stateColor(session.state), style = MaterialTheme.typography.labelLarge)
                Text(doingText(session), style = MaterialTheme.typography.bodyMedium, maxLines = 2)
            }
            Fact("目录", session.cwd)
            session.branch?.takeIf { it.isNotBlank() }?.let { Fact("分支", it) }
            Fact("来源", sourceLabel(session.source))
            session.model?.takeIf { it.isNotBlank() }?.let { Fact("模型", it) }
            // An estimated context share (the Mac could not read the real one) is marked with ≈.
            session.context?.let { Fact("上下文", contextPercentText(it)) }
            Fact("最后更新", agoText(session.eventTime, now))

            OutlinedTextField(
                value = text,
                onValueChange = { text = it.take(MAX_SAY_LENGTH) },
                label = { Text("发一句") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
                maxLines = 5,
                enabled = !busy,
            )
            Text(
                "Claude 会把这句话当成另一个会话发来的消息，它不能用来批准任何东西",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                feedback?.let { (message, ok) ->
                    Text(
                        message,
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (ok) stateColor(local.critter.core.protocol.PetState.done) else MaterialTheme.colorScheme.error,
                    )
                } ?: Box(Modifier.weight(1f))
                Button(
                    enabled = online && !busy && text.isNotBlank(),
                    onClick = {
                        // Like an answer, nothing goes to the Mac from the lock screen before the phone is unlocked.
                        withKeyguardDismissed {
                            busy = true
                            feedback = null
                            scope.launch {
                                val result = repository.say(session.id, text.trim())
                                busy = false
                                feedback = sayFeedback(result) to result.ok
                                if (result.ok) text = ""
                            }
                        }
                    },
                ) { Text(if (busy) "发送中…" else "发送") }
            }
        }
        }
    }

    @Composable
    private fun Fact(label: String, value: String) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(end = 4.dp))
            Text(value, style = MaterialTheme.typography.bodyMedium)
        }
    }

    companion object {
        const val EXTRA_SESSION_ID = "sessionId"
        private val SHEET_SHAPE = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp)

        fun intent(context: Context, sessionId: String): Intent =
            Intent(context, DetailActivity::class.java).putExtra(EXTRA_SESSION_ID, sessionId)
    }
}
