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
 * clawd fallback.
 */
class SkinStore(private val context: Context) {
    private val dir = File(context.filesDir, "skins")
    private val pushed = ConcurrentHashMap<String, String>()
    private val _library: MutableStateFlow<SkinLibrary>
    val library: StateFlow<SkinLibrary> get() = _library.asStateFlow()

    init {
        dir.listFiles { f -> f.extension == "json" }?.forEach { f ->
            val text = runCatching { f.readText() }.getOrNull() ?: return@forEach
            if (SkinLoader.decode(text) != null) pushed[f.nameWithoutExtension] = text
        }
        _library = MutableStateFlow(build())
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
        _library.value = build()
        return true
    }

    private fun build() = SkinLibrary(::readAsset, pushed.toMap())

    private fun readAsset(path: String): String? = try {
        context.assets.open(path).bufferedReader().use { it.readText() }
    } catch (_: IOException) {
        null
    }

    private fun isPlain(name: String) = name.isNotEmpty() && name.none { it == '/' || it == '\\' || it == '.' }
}
