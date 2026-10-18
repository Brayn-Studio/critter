package local.critter.phone.ui.answer

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import local.critter.core.logic.AnswerDraft
import local.critter.core.net.ConnState
import local.critter.core.protocol.ResultReason
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.repository
import local.critter.phone.ui.theme.CritterTheme
import local.critter.phone.ui.withKeyguardDismissed

/**
 * The answer card for one pending request (spec §8.5). The entry intent carries only the requestId; the
 * request itself is always looked up in the latest snapshot, never taken from "the session's current request".
 */
class AnswerActivity : ComponentActivity() {
    private var requestId by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        requestId = intent.getStringExtra(EXTRA_REQUEST_ID)
        val repo = repository
        setContent {
            CritterTheme {
                Content(repo)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        requestId = intent.getStringExtra(EXTRA_REQUEST_ID)
    }

    override fun onStart() {
        super.onStart()
        // Opened from a notification, the process may be fresh (or just thawed) with no connection yet.
        repository.ensureConnected()
    }

    @Composable
    private fun Content(repo: BridgeRepository) {
        val id = requestId
        val snapshot by repo.snapshot.collectAsState()
        val live by repo.live.collectAsState()
        val state by repo.state.collectAsState()
        val scope = rememberCoroutineScope()

        val request = snapshot?.pending?.firstOrNull { it.requestId == id }
        val session = request?.let { r -> snapshot?.sessions?.firstOrNull { it.id == r.sessionId } }

        var handledElsewhere by remember(id) { mutableStateOf(false) }
        var busy by remember(id) { mutableStateOf(false) }
        var failure by remember(id) { mutableStateOf<String?>(null) }
        var attempt by remember(id) { mutableIntStateOf(0) }
        val draft = remember(id, attempt, request?.requestId) { request?.let { AnswerDraft(it) } }

        // Missing from a cached snapshot (a fresh process, offline) proves nothing: wait for the live one a while.
        var waitedOut by remember(id) { mutableStateOf(false) }
        LaunchedEffect(id) {
            delay(BridgeRepository.LIVE_WAIT_MS)
            waitedOut = true
        }
        val waiting = request == null && live == null && !waitedOut && !handledElsewhere
        val gone = !waiting && (request == null || handledElsewhere)
        LaunchedEffect(gone) {
            if (gone) {
                delay(1_500)
                finish()
            }
        }

        fun submit() {
            val d = draft ?: return
            val payload = d.payload() ?: return
            withKeyguardDismissed {
                if (!d.markSubmitted()) return@withKeyguardDismissed
                busy = true
                failure = null
                scope.launch {
                    val result = repo.answer(d.request.requestId, payload)
                    busy = false
                    when {
                        result.ok -> finish()
                        result.reason == ResultReason.resolved -> handledElsewhere = true
                        else -> {
                            failure = result.message ?: "没有发送出去，再试一次"
                            attempt++ // a fresh draft, so the retry is allowed
                        }
                    }
                }
            }
        }

        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.45f))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { finish() },
            contentAlignment = Alignment.BottomCenter,
        ) {
            // Taps on the sheet itself must not fall through to the scrim.
            Box(
                Modifier
                    .navigationBarsPadding()
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
            ) {
                if (gone || draft == null) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                            .padding(28.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            if (waiting) "正在连接电脑…" else "已在电脑上处理",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                } else {
                    AnswerSheet(
                        request = draft.request,
                        session = session,
                        draft = draft,
                        online = state is ConnState.Connected,
                        busy = busy,
                        failure = failure,
                        onSubmit = ::submit,
                    )
                }
            }
        }
    }

    companion object {
        const val EXTRA_REQUEST_ID = "requestId"

        fun intent(context: Context, requestId: String): Intent =
            Intent(context, AnswerActivity::class.java).putExtra(EXTRA_REQUEST_ID, requestId)
    }
}
