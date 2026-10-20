package local.critter.phone.critter

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import local.critter.core.skin.SkinLibrary
import local.critter.core.skin.SkinLoader
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/**
 * Where the phone gets skins: the bundled ones from assets, and the custom ones the Mac has sent (asked for
 * with a `skin` request, remembered in memory and in the app's private `skins/<name>.json`). [library] is
 * rebuilt whenever a new manifest arrives, so screens that read it redraw with the real skin instead of the
 * clawd fallback. The new library takes over the old one's manifests whose source did not change, so only the
 * Critters wearing the new skin are rebuilt.
 */
class SkinStore(private val context: Context) {
    private val dir = File(context.filesDir, "skins")
    private val pushed = ConcurrentHashMap<String, String>()
    private val _library: MutableStateFlow<SkinLibrary>
    @Volatile private var forced: String? = null
    @Volatile private var clockSkin: String? = null
    val library: StateFlow<SkinLibrary> get() = _library.asStateFlow()

    init {
        dir.listFiles { f -> f.extension == "json" }?.forEach { f ->
            val text = runCatching { f.readText() }.getOrNull() ?: return@forEach
            if (SkinLoader.decode(text) != null) pushed[f.nameWithoutExtension] = text
        }
        _library = MutableStateFlow(build(previous = null))
    }

    /** The manifest JSON of a skin the Mac sent earlier, or null. */
    fun pushed(name: String): String? = pushed[name]

    private val bundledNames: Set<String> by lazy { context.assets.list("skins")?.toSet() ?: emptySet() }

    /** Whether the app ships skin [name] (a cheap lookup, no file read). */
    fun isBundled(name: String): Boolean = name in bundledNames

    /** The bundled manifest's JSON, or null if the app has no such skin. */
    fun bundled(name: String): String? = if (isPlain(name)) readAsset("skins/$name/manifest.json") else null

    /** Remembers a manifest the Mac sent; ignored (false) if it is not a valid skin. */
    fun put(name: String, json: String): Boolean {
        if (!isPlain(name) || SkinLoader.decode(json) == null) return false
        pushed[name] = json
        try {
            dir.mkdirs()
            File(dir, "$name.json").writeText(json)
        } catch (_: IOException) {
            // Kept in memory only; asked for again after a restart.
        }
        rebuild()
        return true
    }

    /**
     * The phone's own skin choice (spec §8.8): null follows the Mac, a name shows that skin for every session.
     * [library] is rebuilt, so every screen redraws.
     */
    @Synchronized
    fun setForced(name: String?) {
        if (name == forced) return
        forced = name
        rebuild()
    }

    /**
     * The Mac's selected skin (`prefs.skin`): its tick runs every row of Critters, and only skins on the same tick
     * join (see [SkinLibrary]). [library] is rebuilt when it changes.
     */
    @Synchronized
    fun setClockSkin(name: String?) {
        if (name == clockSkin) return
        clockSkin = name
        rebuild()
    }

    /** The bundled skins by name, unaffected by the phone's own choice: for the previews in the settings. */
    val previewLibrary: SkinLibrary by lazy { SkinLibrary(::readAsset) }

    /** One rebuild at a time, each from the library before it (callers come from several threads). */
    @Synchronized
    private fun rebuild() {
        _library.value = build(_library.value)
    }

    private fun build(previous: SkinLibrary?) = SkinLibrary(::readAsset, pushed.toMap(), forced, clockSkin, reuse = previous)

    private fun readAsset(path: String): String? = try {
        context.assets.open(path).bufferedReader().use { it.readText() }
    } catch (_: IOException) {
        null
    }

    private fun isPlain(name: String) = name.isNotEmpty() && name.none { it == '/' || it == '\\' || it == '.' }
}
