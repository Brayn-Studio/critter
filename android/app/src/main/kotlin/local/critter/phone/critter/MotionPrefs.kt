package local.critter.phone.critter

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The phone-wide "reduce motion" switch from the settings; the system's "remove animations" counts as well. */
object MotionPrefs {
    private val state = MutableStateFlow(false)

    /** The switch as a flow, for screens that must follow it while they are shown. */
    val manualState: StateFlow<Boolean> = state.asStateFlow()

    var manual: Boolean
        get() = state.value
        set(value) {
            state.value = value
        }
}
