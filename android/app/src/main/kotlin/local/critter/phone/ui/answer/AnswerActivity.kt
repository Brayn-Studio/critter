package local.critter.phone.ui.answer

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import local.critter.core.logic.AnswerDraft
import local.critter.core.net.ConnState
import local.critter.core.protocol.BridgeSession
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.repository
import local.critter.phone.ui.meadow.STAGE_PET
import local.critter.phone.ui.sheet.LookAtYouCue
import local.critter.phone.ui.sheet.SheetMessage
import local.critter.phone.ui.sheet.SheetScaffold
import local.critter.phone.ui.theme.CritterTheme
import local.critter.phone.ui.withKeyguardDismissed

/** How long "已在电脑上处理" stays before the card closes by itself. */
private const val HANDLED_CLOSE_MS = 1_500L

/**
 * The answer card for one pending request (spec §8.5). The entry intent carries only the requestId; the
 * request itself is always looked up in the latest snapshot, never taken from "the session's current request".
 */
class AnswerActivity : ComponentActivity() {
    private var requestId by mutableStateOf<String?>(null)

    /**
     * An answer the Mac took. The card keeps showing the request as it was while it says so ([label], "已允许")
     * and slides away, though the request has left the snapshot by then. A no (deny, revise) has no label.
     */
    private class Answered(val draft: AnswerDraft, val session: BridgeSession?, val label: String?)

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
        val library by repo.skins.library.collectAsState()
        val scope = rememberCoroutineScope()

        val request = snapshot?.pending?.firstOrNull { it.requestId == id }
        val session = request?.let { r -> snapshot?.sessions?.firstOrNull { it.id == r.sessionId } }

        // The sheet slides away first; the activity finishes once it has gone.
        var shown by remember { mutableStateOf(true) }
        val cue = remember { LookAtYouCue() }
        var handledElsewhere by remember(id) { mutableStateOf(false) }
        // The Mac's word that the request ran out of time: closes the card like handledElsewhere.
        var expired by remember(id) { mutableStateOf<String?>(null) }
        var busy by remember(id) { mutableStateOf(false) }
        var failure by remember(id) { mutableStateOf<String?>(null) }
        var attempt by remember(id) { mutableIntStateOf(0) }
        var answered by remember(id) { mutableStateOf<Answered?>(null) }
        val draft = remember(id, attempt, request?.requestId) { request?.let { AnswerDraft(it) } }

        // For "已在电脑上处理": whose request it was, once it has left the snapshot.
        var lastSession by remember(id) { mutableStateOf<BridgeSession?>(null) }
        LaunchedEffect(session) { if (session != null) lastSession = session }

        // Missing from a cached snapshot (a fresh process, offline) proves nothing: wait for the live one a while.
        var waitedOut by remember(id) { mutableStateOf(false) }
        LaunchedEffect(id) {
            delay(BridgeRepository.LIVE_WAIT_MS)
            waitedOut = true
        }
        val settledElsewhere = handledElsewhere || expired != null
        val waiting = answered == null && request == null && live == null && !waitedOut && !settledElsewhere
        val gone = answered == null && !waiting && (request == null || settledElsewhere)
        LaunchedEffect(gone) {
            if (gone) {
                delay(HANDLED_CLOSE_MS)
                shown = false
            }
        }
        // Taken: "✓ 已允许" and the cheering Critter for a moment, then away; a no goes at once.
        LaunchedEffect(answered) {
            val a = answered ?: return@LaunchedEffect
            if (a.label != null) delay(SUCCESS_HOLD_MS)
            shown = false
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
                    when (val outcome = answerOutcome(result)) {
                        AnswerOutcome.Sent -> {
                            val label = successLabel(payload)
                            if (label == null) cue.view?.notice(STAGE_PET)
                            answered = Answered(d, session, label)
                        }
                        AnswerOutcome.HandledElsewhere -> handledElsewhere = true
                        is AnswerOutcome.Expired -> expired = outcome.message
                        is AnswerOutcome.Failed -> {
                            failure = outcome.message
                            attempt++ // a fresh draft, so the retry is allowed
                        }
                    }
                }
            }
        }

        SheetScaffold(
            onDismiss = { shown = false },
            visible = shown,
            onSettled = cue::onSettled,
            onHidden = ::finish,
        ) {
            val taken = answered
            val shownDraft = taken?.draft ?: draft
            when {
                gone -> HandledElsewhereCard(
                    name = lastSession?.name,
                    manifest = library.manifest(lastSession?.skin.orEmpty()),
                    onOk = { shown = false },
                    expired = expired,
                )
                shownDraft == null -> SheetMessage("正在连接电脑…")
                else -> {
                    val shownSession = taken?.session ?: session
                    AnswerSheet(
                        request = shownDraft.request,
                        session = shownSession,
                        manifest = library.manifest(shownSession?.skin.orEmpty()),
                        draft = shownDraft,
                        online = state is ConnState.Connected,
                        busy = busy || taken != null,
                        failure = failure,
                        doneLabel = taken?.label,
                        onView = cue::onView,
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
