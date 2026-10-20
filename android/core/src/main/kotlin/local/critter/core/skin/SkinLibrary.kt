package local.critter.core.skin

import java.util.concurrent.ConcurrentHashMap

/**
 * Finds a skin by name: a manifest the Mac pushed wins (as `~/.critter/skins` does on the
 * desktop), then the bundled ones read from the app's assets (`skins/<name>/manifest.json`).
 * An unknown, undecodable or invalid skin falls back to clawd, so a broken manifest or a name
 * this phone doesn't have never crashes.
 *
 * @param assetReader reads an asset by its path (e.g. `skins/clawd/manifest.json`); null if absent.
 * @param pushed manifests pushed by the Mac, as JSON by skin name.
 * @param forced when set, every lookup answers with this skin whatever name is asked for (the phone's own skin
 * choice, spec §8.8); an invalid forced skin falls back to clawd like any other.
 * @param clockSkin the Mac's selected skin (`prefs.skin`). As on the desktop, a row of Critters runs on one clock
 * at that skin's `tickMs`, and only skins with the same tick join it (random-pets spec): a skin on another tick
 * is drawn as the clock skin instead, never at the wrong speed. Null: no such rule (one skin per view).
 * @param reuse the library this one replaces: a manifest from the same source (a bundled skin, or the same pushed
 * JSON) is the very object it decoded, so the screens, which rebuild a Critter whose manifest is another object,
 * leave those Critters alone. Bundled skins are taken over unread: assets do not change while the app runs.
 */
class SkinLibrary(
    private val assetReader: (String) -> String?,
    private val pushed: Map<String, String> = emptyMap(),
    private val forced: String? = null,
    private val clockSkin: String? = null,
    reuse: SkinLibrary? = null,
) {
    private val cache = ConcurrentHashMap<String, SkinManifest>()

    /** One decoded source: its JSON (pushed; null for a bundled one) and the manifest (null: absent or invalid). */
    private class Decoded(val json: String?, val manifest: SkinManifest?)

    /** By source, `pushed/<name>` or `bundled/<name>`; a copy of [reuse]'s, so no chain of old libraries is kept. */
    private val decoded: ConcurrentHashMap<String, Decoded> = ConcurrentHashMap(reuse?.decoded ?: emptyMap())

    /** The skin whose tick the clock runs at; null when every lookup gives one skin anyway (forced) or no rule. */
    private val clockManifest: SkinManifest? by lazy {
        if (forced != null) null else clockSkin?.let { find(it) ?: clawd() }
    }

    fun manifest(name: String): SkinManifest {
        val wanted = forced ?: name
        return cache.getOrPut(wanted) {
            val found = find(wanted) ?: clawd()
            val clock = clockManifest
            if (clock != null && clock.tickMs != found.tickMs) clock else found
        }
    }

    private fun find(name: String): SkinManifest? {
        pushed[name]?.let { json ->
            val d = decoded.compute("pushed/$name") { _, old -> old?.takeIf { it.json == json } ?: Decoded(json, SkinLoader.decode(json)) }
            d?.manifest?.let { return it }
        }
        if (!isPlainName(name)) return null
        return decoded.computeIfAbsent("bundled/$name") {
            Decoded(null, assetReader("skins/$name/manifest.json")?.let { SkinLoader.decode(it) })
        }.manifest
    }

    private fun clawd(): SkinManifest = find(FALLBACK)
        ?: error("the bundled $FALLBACK skin is missing or invalid")

    // The name becomes part of an asset path, so it must not climb out of `skins/`.
    private fun isPlainName(name: String) = name.isNotEmpty() && name.none { it == '/' || it == '\\' || it == '.' }

    companion object {
        const val FALLBACK = "clawd"
    }
}
