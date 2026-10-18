package local.critter.core.skin

/**
 * Finds a skin by name: a manifest the Mac pushed wins (as `~/.critter/skins` does on the
 * desktop), then the bundled ones read from the app's assets (`skins/<name>/manifest.json`).
 * An unknown, undecodable or invalid skin falls back to clawd, so a broken manifest or a name
 * this phone doesn't have never crashes.
 *
 * @param assetReader reads an asset by its path (e.g. `skins/clawd/manifest.json`); null if absent.
 * @param pushed manifests pushed by the Mac, as JSON by skin name.
 */
class SkinLibrary(
    private val assetReader: (String) -> String?,
    private val pushed: Map<String, String> = emptyMap(),
) {
    private val cache = HashMap<String, SkinManifest>()

    fun manifest(name: String): SkinManifest = cache.getOrPut(name) { find(name) ?: clawd() }

    private fun find(name: String): SkinManifest? {
        pushed[name]?.let { json -> SkinLoader.decode(json)?.let { return it } }
        if (!isPlainName(name)) return null
        return assetReader("skins/$name/manifest.json")?.let { SkinLoader.decode(it) }
    }

    private fun clawd(): SkinManifest = find(FALLBACK)
        ?: error("the bundled $FALLBACK skin is missing or invalid")

    // The name becomes part of an asset path, so it must not climb out of `skins/`.
    private fun isPlainName(name: String) = name.isNotEmpty() && name.none { it == '/' || it == '\\' || it == '.' }

    companion object {
        const val FALLBACK = "clawd"
    }
}
