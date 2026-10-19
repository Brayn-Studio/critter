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
    /** Which board is shown: the enlarged critters or the pro dashboard (remembered). */
    val boardCritterMode: Boolean = true,
    /** Sounds on the board when a session just needs you, finished or failed (spec §8.7). Off by default. */
    val boardSounds: Boolean = false,
    /** Open the board by itself while charging in landscape (spec §8.6). */
    val boardAutoOpen: Boolean = true,
    /** Reduce motion by hand; the system's "remove animations" switches it on as well (spec §8.2). */
    val reduceMotion: Boolean = false,
    /** A bundled skin shown for every session; null follows the Mac (spec §8.8). */
    val skinOverride: String? = null,
    val onboardingDone: Boolean = false,
    val overlayEnabled: Boolean = false,
    /** 1 small, 2 medium, 3 large. */
    val overlaySize: Int = 2,
    /** The idle dimming strength 0..1 for the floating pile; null follows the Mac's setting. */
    val overlayIdleDim: Float? = null,
    val overlayAutoHide: Boolean = false,
    val overlayHideInFullscreen: Boolean = false,
    /** Where the pile sits: on the right edge or the left, and its top as a fraction of the screen height. */
    val overlayOnRight: Boolean = true,
    val overlayY: Float = 0.4f,
    /** The day the opening (Critters popping up on the home screen) last played, as `LocalDate.toEpochDay()`. */
    val openingShownOn: Long? = null,
    /** When the system last kept the board from opening, in millis. */
    val boardBlockedAt: Long? = null,
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
            boardCritterMode = prefs.getBoolean("boardCritterMode", d.boardCritterMode),
            boardSounds = prefs.getBoolean("boardSounds", d.boardSounds),
            boardAutoOpen = prefs.getBoolean("boardAutoOpen", d.boardAutoOpen),
            reduceMotion = prefs.getBoolean("reduceMotion", d.reduceMotion),
            skinOverride = prefs.getString("skinOverride", null)?.takeIf { it.isNotEmpty() },
            onboardingDone = prefs.getBoolean("onboardingDone", d.onboardingDone),
            overlayEnabled = prefs.getBoolean("overlayEnabled", d.overlayEnabled),
            overlaySize = prefs.getInt("overlaySize", d.overlaySize).coerceIn(1, 3),
            overlayIdleDim = if (prefs.contains("overlayIdleDim")) prefs.getFloat("overlayIdleDim", 1f).coerceIn(0f, 1f) else null,
            overlayAutoHide = prefs.getBoolean("overlayAutoHide", d.overlayAutoHide),
            overlayHideInFullscreen = prefs.getBoolean("overlayHideInFullscreen", d.overlayHideInFullscreen),
            overlayOnRight = prefs.getBoolean("overlayOnRight", d.overlayOnRight),
            overlayY = prefs.getFloat("overlayY", d.overlayY).coerceIn(0f, 1f),
            openingShownOn = if (prefs.contains("openingShownOn")) prefs.getLong("openingShownOn", 0) else null,
            boardBlockedAt = if (prefs.contains("boardBlockedAt")) prefs.getLong("boardBlockedAt", 0) else null,
        )
    }

    private fun write(s: PhoneSettings) = prefs.edit {
        putBoolean("bridgeEnabled", s.bridgeEnabled)
        putBoolean("vibrateOnWaiting", s.vibrateOnWaiting)
        putBoolean("notifyDone", s.notifyDone)
        putBoolean("notifyError", s.notifyError)
        putFloat("boardBrightness", s.boardBrightness)
        putBoolean("boardCritterMode", s.boardCritterMode)
        putBoolean("boardSounds", s.boardSounds)
        putBoolean("boardAutoOpen", s.boardAutoOpen)
        putBoolean("reduceMotion", s.reduceMotion)
        if (s.skinOverride == null) remove("skinOverride") else putString("skinOverride", s.skinOverride)
        putBoolean("onboardingDone", s.onboardingDone)
        putBoolean("overlayEnabled", s.overlayEnabled)
        putInt("overlaySize", s.overlaySize)
        val dim = s.overlayIdleDim
        if (dim == null) remove("overlayIdleDim") else putFloat("overlayIdleDim", dim)
        putBoolean("overlayAutoHide", s.overlayAutoHide)
        putBoolean("overlayHideInFullscreen", s.overlayHideInFullscreen)
        putBoolean("overlayOnRight", s.overlayOnRight)
        putFloat("overlayY", s.overlayY)
        val opening = s.openingShownOn
        if (opening == null) remove("openingShownOn") else putLong("openingShownOn", opening)
        val blocked = s.boardBlockedAt
        if (blocked == null) remove("boardBlockedAt") else putLong("boardBlockedAt", blocked)
    }
}
