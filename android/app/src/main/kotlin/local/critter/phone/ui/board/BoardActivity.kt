package local.critter.phone.ui.board

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.os.PowerManager
import androidx.core.content.ContextCompat
import local.critter.phone.board.BoardTriggerService
import android.view.MotionEvent
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import local.critter.core.flock.SoundTrigger
import local.critter.core.protocol.PetState
import local.critter.phone.board.BoardSounds
import local.critter.phone.board.CritterBoard
import local.critter.phone.critter.SessionTap
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
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
import local.critter.phone.ui.withKeyguardDismissed

/**
 * The landscape pro dashboard. Kept on while charging; the content only changes when the Mac sends something.
 * Opened by hand from the app, or by [BoardTriggerService] ([intent] with `auto`) when the phone charges in landscape.
 */
class BoardActivity : ComponentActivity() {
    private var lastActivityAt by mutableLongStateOf(System.currentTimeMillis())
    private val sounds by lazy { BoardSounds(this) }

    /** Opened by the trigger rather than by hand: it has no business on screen once the charger is gone. */
    private val auto by lazy { intent.getBooleanExtra(EXTRA_AUTO, false) }

    /** True when the trigger asked the board to go (unplugged, or the phone stood up); that is not a manual exit. */
    private var closedByTrigger = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                BoardTriggerService.ACTION_CLOSE_BOARD -> {
                    closedByTrigger = true
                    finish()
                }
                // Unplugged: the screen may time out again right away, not only when the board closes 10 s later.
                Intent.ACTION_POWER_DISCONNECTED -> keepScreenOn(window, false)
                Intent.ACTION_POWER_CONNECTED -> keepScreenOn(window, true)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The board may open by itself over the lock screen (never on a dark screen: BoardTrigger waits for the
        // screen to be on, so it does not turn the screen on itself). Answering from it needs the keyguard gone
        // first: every answer path asks for that.
        setShowWhenLocked(true)
        ContextCompat.registerReceiver(
            this, receiver,
            IntentFilter().apply {
                addAction(BoardTriggerService.ACTION_CLOSE_BOARD)
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        setUpBoardWindow(this)
        // Shown from now until onDestroy: a board whose screen went off is still the board on top.
        BoardTriggerService.boardShown(true)
        val repo = repository
        setContent { Board(repo) }
    }

    override fun onStart() {
        super.onStart()
        val charging = BoardTriggerService.isCharging(this)
        if (auto && !charging) {
            // The charger went while it was coming up or while it was out of sight: nothing to show.
            closedByTrigger = true
            finish()
            return
        }
        keepScreenOn(window, charging)
        repository.boardVisible(true)
        repository.ensureConnected()
    }

    override fun onDestroy() {
        unregisterReceiver(receiver)
        sounds.release()
        BoardTriggerService.boardShown(false)
        super.onDestroy()
    }

    override fun onStop() {
        repository.boardVisible(false)
        // Leaving by hand (back, home) keeps the board from opening again on this charge. The screen going off
        // is not leaving.
        val byHand = isFinishing || getSystemService(PowerManager::class.java).isInteractive
        if (!closedByTrigger && byHand && !isChangingConfigurations) BoardTriggerService.manualExit()
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

        // Sounds: only for states just entered, never on the first snapshot of a connection, only the most urgent.
        LaunchedEffect(Unit) {
            var previous: Map<String, PetState>? = null
            repo.live.collect { body ->
                if (body == null) {
                    previous = null
                    return@collect
                }
                val current = body.sessions.associate { it.id to it.state }
                if (repo.settingsStore.settings.value.boardSounds) {
                    sounds.prepare(body.prefs.soundTheme)
                    val entered = SoundTrigger.enteredAlertStates(previous, current).firstOrNull()
                    if (entered != null && lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
                        sounds.play(entered, body.prefs.soundTheme)
                    }
                }
                previous = current
            }
        }

        val library by repo.skins.library.collectAsState()
        val data = BoardData(snapshot, state is ConnState.Connected, updatedAt, now)
        var swiped by remember { mutableStateOf(0f) }
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black)
                .pointerInput(Unit) {
                    // A horizontal swipe on empty board switches the mode (swipes that start on a Critter lift it).
                    detectHorizontalDragGestures(
                        onDragStart = { swiped = 0f },
                        onDragEnd = { if (kotlin.math.abs(swiped) > 120.dp.toPx()) toggleMode(repo) },
                    ) { _, amount -> swiped += amount }
                },
        ) {
            if (settings.boardCritterMode) {
                CritterBoard(data, library, shift) { SessionTap.handle(this@BoardActivity, repo, it) }
            } else {
                ProBoard(
                    data = data,
                    shift = shift,
                    onAllow = { answerPermission(repo, it, allow = true) },
                    onDeny = { answerPermission(repo, it, allow = false) },
                    onOpen = { startActivity(AnswerActivity.intent(this@BoardActivity, it.requestId)) },
                )
            }
            Text(
                if (settings.boardCritterMode) "▤" else "◉",
                color = Color(0xFF8E8E93),
                fontSize = 18.sp,
                modifier = Modifier.align(Alignment.TopEnd).padding(8.dp)
                    .clickable { toggleMode(repo) }.padding(6.dp),
            )
        }
    }

    private fun toggleMode(repo: BridgeRepository) {
        repo.settingsStore.update { it.copy(boardCritterMode = !it.boardCritterMode) }
    }

    /** On the lock screen the board may be showing, but nothing is sent before the user unlocks (spec §8.6). */
    private fun answerPermission(repo: BridgeRepository, request: BridgePending, allow: Boolean) {
        withKeyguardDismissed { sendPermission(repo, request, allow) }
    }

    private fun sendPermission(repo: BridgeRepository, request: BridgePending, allow: Boolean) {
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

    companion object {
        private const val EXTRA_AUTO = "auto"

        fun intent(context: Context, auto: Boolean = false): Intent =
            Intent(context, BoardActivity::class.java).putExtra(EXTRA_AUTO, auto)
    }
}
