package local.critter.phone.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import kotlinx.coroutines.delay

/** The current time in millis, updated once a minute on the minute (not a per-frame animation; spec §9). */
@Composable
fun rememberMinuteClock(): State<Long> = produceState(System.currentTimeMillis()) {
    while (true) {
        val now = System.currentTimeMillis()
        value = now
        delay(60_000 - now % 60_000)
    }
}
