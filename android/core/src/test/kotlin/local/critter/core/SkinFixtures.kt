package local.critter.core

import local.critter.core.skin.SkinJson
import local.critter.core.skin.SkinManifest
import local.critter.core.skin.SkinValidator

/** The repo's `Skins` folder is on the test classpath (see core/build.gradle.kts): `<name>/manifest.json`. */
fun bundledSkinJson(name: String): String =
    object {}.javaClass.getResourceAsStream("/$name/manifest.json")!!.use { it.readBytes().toString(Charsets.UTF_8) }

/** A fresh, mutable copy of a bundled skin, decoded without validation (as Swift's `bundledSkin`). */
fun bundledSkin(name: String): SkinManifest =
    SkinJson.decodeFromString(SkinManifest.serializer(), bundledSkinJson(name))

/** A fresh, mutable copy of clawd, the builtin skin (Swift's `SkinLoader.builtin()`). */
fun builtin(): SkinManifest = bundledSkin("clawd")

/** The problems of the builtin skin after `change` (Swift's `mutated`). */
fun mutated(change: (SkinManifest) -> Unit): List<String> {
    val m = builtin()
    change(m)
    return SkinValidator.validate(m)
}
