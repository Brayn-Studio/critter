package local.critter.phone.ui.board

import android.app.Activity
import android.os.Build
import android.view.View
import android.view.Window
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlin.random.Random

// Everything about the board that is about the screen rather than the content: staying on, brightness,
// refresh rate, and keeping a static layout from burning in (spec §9).

/** How long the board waits, without a touch or a change, before it dims further. */
const val IDLE_DIM_AFTER_MS = 15 * 60_000L

/** The shift of the whole layout is re-rolled this often. */
const val BURN_IN_SHIFT_EVERY_MS = 3 * 60_000L

private const val BURN_IN_MAX_DP = 4

/** The board brightness [base], lowered to 60% once the board has been idle for 15 minutes. */
fun boardBrightness(base: Float, idleMs: Long): Float =
    (if (idleMs >= IDLE_DIM_AFTER_MS) base * 0.6f else base).coerceIn(0.01f, 1f)

/** A random x/y offset in -4..4 dp, as whole numbers. */
fun randomShift(random: Random): Pair<Int, Int> =
    random.nextInt(-BURN_IN_MAX_DP, BURN_IN_MAX_DP + 1) to random.nextInt(-BURN_IN_MAX_DP, BURN_IN_MAX_DP + 1)

/**
 * The layout offset to apply to the whole content area; it jumps (no animation) every 3 minutes, counted only
 * while the board is started (nothing burns in while it is out of sight).
 */
@Composable
fun rememberBurnInShift(): State<Pair<Dp, Dp>> {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    return produceState(0.dp to 0.dp, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                delay(BURN_IN_SHIFT_EVERY_MS)
                val (x, y) = randomShift(Random.Default)
                value = x.dp to y.dp
            }
        }
    }
}

/**
 * Go full screen and ask for the slowest refresh rate: a static board gains nothing from 120 Hz. Staying on is
 * [keepScreenOn]'s, and only while charging.
 */
fun setUpBoardWindow(activity: Activity) {
    val window = activity.window
    WindowCompat.setDecorFitsSystemWindows(window, false)
    WindowInsetsControllerCompat(window, window.decorView).apply {
        hide(WindowInsetsCompat.Type.systemBars())
        systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }
    requestLowRefreshRate(activity, window)
}

/** FLAG_KEEP_SCREEN_ON while [on] (charging), so a board on battery times out like any screen (spec §9). */
fun keepScreenOn(window: Window, on: Boolean) {
    if (on) {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    } else {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}

fun applyBrightness(window: Window, brightness: Float) {
    window.attributes = window.attributes.apply { screenBrightness = brightness }
}

private fun requestLowRefreshRate(activity: Activity, window: Window) {
    if (Build.VERSION.SDK_INT >= 35) {
        window.decorView.setRequestedFrameRate(View.REQUESTED_FRAME_RATE_CATEGORY_LOW)
    } else if (Build.VERSION.SDK_INT >= 30) {
        val display = activity.display
        val current = display?.mode
        // The slowest mode that keeps the current resolution, so the switch is seamless.
        val slowest = display?.supportedModes
            ?.filter { current != null && it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            ?.minByOrNull { it.refreshRate }
        window.attributes = window.attributes.apply {
            if (slowest != null) preferredDisplayModeId = slowest.modeId else preferredRefreshRate = 30f
        }
    }
}
