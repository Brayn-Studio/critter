package local.critter.phone.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay

/**
 * The current time in millis, updated once a minute on the minute (not a per-frame animation; spec §9). It only
 * ticks while the screen is started: out of sight it waits, and it catches up the moment it is seen again.
 */
@Composable
fun rememberMinuteClock(): State<Long> {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    return produceState(System.currentTimeMillis(), lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                val now = System.currentTimeMillis()
                value = now
                delay(60_000 - now % 60_000)
            }
        }
    }
}
