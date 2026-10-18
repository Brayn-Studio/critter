package local.critter.phone.board

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SoundTheme
import local.critter.phone.service.Alerts
import java.io.IOException

/**
 * The board's sounds (spec §8.7): `sounds/<theme>/{waiting,done,error}.wav` from assets, through a
 * [SoundPool]. The theme is the Mac's `prefs.soundTheme`; `system`, an unknown one or one the app does not
 * have means `voice`. Silent under Do Not Disturb. Which snapshot deserves a sound is decided by
 * `SoundTrigger.enteredAlertStates`, not here.
 */
class BoardSounds(private val context: Context) {
    private val pool = SoundPool.Builder()
        .setMaxStreams(1)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
        )
        .build()
    private val loaded = HashMap<String, Int>()
    private val themes: Set<String> by lazy { context.assets.list("sounds")?.toSet() ?: emptySet() }

    /** The folder name to use for the Mac's [theme]. */
    fun resolveTheme(theme: SoundTheme?): String {
        val name = theme?.name
        return if (name != null && name != SoundTheme.system.name && name != SoundTheme.unknown.name && name in themes) name else FALLBACK
    }

    /** Loads the theme's three sounds ahead of time, so the first one is not lost to loading. */
    fun prepare(theme: SoundTheme?) {
        val t = resolveTheme(theme)
        for (state in SOUND_STATES) soundId(t, state)
    }

    fun play(state: PetState, theme: SoundTheme?) {
        if (state !in SOUND_STATES || !Alerts.vibrationAllowed(context)) return // DND mutes the board too
        val id = soundId(resolveTheme(theme), state) ?: return
        pool.play(id, 1f, 1f, 1, 0, 1f)
    }

    fun release() {
        pool.release()
        loaded.clear()
    }

    private fun soundId(theme: String, state: PetState): Int? {
        val key = "$theme/${state.name}"
        loaded[key]?.let { return it }
        return try {
            context.assets.openFd("sounds/$key.wav").use { pool.load(it, 1) }.also { loaded[key] = it }
        } catch (_: IOException) {
            null
        }
    }

    private companion object {
        const val FALLBACK = "voice"
        val SOUND_STATES = listOf(PetState.waiting, PetState.done, PetState.error)
    }
}
