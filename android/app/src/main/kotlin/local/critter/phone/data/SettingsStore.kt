package local.critter.phone.data

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class PhoneSettings(
    val bridgeEnabled: Boolean = true,
    val vibrateOnWaiting: Boolean = true,
    val notifyDone: Boolean = false,
    val notifyError: Boolean = false,
    val boardBrightness: Float = 0.3f,
)

class SettingsStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val _settings = MutableStateFlow(read())
    val settings: StateFlow<PhoneSettings> = _settings.asStateFlow()

    @Synchronized
    fun update(transform: (PhoneSettings) -> PhoneSettings) {
        val next = transform(_settings.value)
        _settings.value = next
        write(next)
    }

    private fun read(): PhoneSettings {
        val d = PhoneSettings()
        return PhoneSettings(
            bridgeEnabled = prefs.getBoolean("bridgeEnabled", d.bridgeEnabled),
            vibrateOnWaiting = prefs.getBoolean("vibrateOnWaiting", d.vibrateOnWaiting),
            notifyDone = prefs.getBoolean("notifyDone", d.notifyDone),
            notifyError = prefs.getBoolean("notifyError", d.notifyError),
            boardBrightness = prefs.getFloat("boardBrightness", d.boardBrightness).coerceIn(0.1f, 1f),
        )
    }

    private fun write(s: PhoneSettings) = prefs.edit {
        putBoolean("bridgeEnabled", s.bridgeEnabled)
        putBoolean("vibrateOnWaiting", s.vibrateOnWaiting)
        putBoolean("notifyDone", s.notifyDone)
        putBoolean("notifyError", s.notifyError)
        putFloat("boardBrightness", s.boardBrightness)
    }
}
