package local.critter.phone.ui.board

import android.os.Bundle
import android.view.MotionEvent
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import local.critter.core.logic.AnswerDraft
import local.critter.core.net.ConnState
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.ResultReason
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.repository
import local.critter.phone.ui.answer.AnswerActivity
import local.critter.phone.ui.rememberMinuteClock

/** The landscape pro dashboard. Always on while visible; the content only changes when the Mac sends something. */
class BoardActivity : ComponentActivity() {
    private var lastActivityAt by mutableLongStateOf(System.currentTimeMillis())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setUpBoardWindow(this)
        val repo = repository
        setContent { Board(repo) }
    }

    override fun onStart() {
        super.onStart()
        repository.boardVisible(true)
    }

    override fun onStop() {
        repository.boardVisible(false)
        super.onStop()
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) lastActivityAt = System.currentTimeMillis()
        return super.dispatchTouchEvent(ev)
    }

    @Composable
    private fun Board(repo: BridgeRepository) {
        val snapshot by repo.snapshot.collectAsState()
        val state by repo.state.collectAsState()
        val updatedAt by repo.lastUpdated.collectAsState()
        val settings by repo.settingsStore.settings.collectAsState()
        val now by rememberMinuteClock()
        val shift = rememberBurnInShift()

        // A change on the Mac counts as activity, so the board stays bright while something is happening.
        val signature = snapshot?.let { s -> s.sessions.map { it.id to it.state } to s.pending.map { it.requestId } }
        LaunchedEffect(signature) { lastActivityAt = System.currentTimeMillis() }

        val brightness = boardBrightness(settings.boardBrightness, now - lastActivityAt)
        LaunchedEffect(brightness) { applyBrightness(window, brightness) }

        ProBoard(
            data = BoardData(snapshot, state is ConnState.Connected, updatedAt, now),
            shift = shift,
            onAllow = { answerPermission(repo, it, allow = true) },
            onDeny = { answerPermission(repo, it, allow = false) },
            onOpen = { startActivity(AnswerActivity.intent(this, it.requestId)) },
        )
    }

    private fun answerPermission(repo: BridgeRepository, request: BridgePending, allow: Boolean) {
        val draft = AnswerDraft(request)
        if (allow) draft.allow() else draft.deny(null)
        val payload = draft.payload() ?: return
        if (!draft.markSubmitted()) return
        lifecycleScope.launch {
            val result = repo.answer(request.requestId, payload)
            if (!result.ok && result.reason != ResultReason.resolved) {
                Toast.makeText(this@BoardActivity, result.message ?: "没有发送出去", Toast.LENGTH_SHORT).show()
            }
        }
    }
}
