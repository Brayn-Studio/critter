package local.critter.core

import local.critter.core.skin.AccessorySpec
import local.critter.core.skin.ParticleSpec
import local.critter.core.skin.SkinJson
import local.critter.core.skin.SkinManifest
import local.critter.core.skin.SkinPart
import local.critter.core.skin.SkinValidator
import local.critter.core.skin.StateSpec

/** The repo's `Skins` folder is on the test classpath (see core/build.gradle.kts): `<name>/manifest.json`. */
fun bundledSkinJson(name: String): String =
    object {}.javaClass.getResourceAsStream("/$name/manifest.json")!!.use { it.readBytes().toString(Charsets.UTF_8) }

/** A bundled skin, decoded without validation (as Swift's `bundledSkin`). */
fun bundledSkin(name: String): SkinManifest =
    SkinJson.decodeFromString(SkinManifest.serializer(), bundledSkinJson(name))

/** Sprig, the builtin skin (Swift's `SkinLoader.builtin()`). */
fun builtin(): SkinManifest = bundledSkin("sprig")

/** The problems of the builtin skin after `change` (Swift's `mutated`, which changes a copy). */
fun mutated(change: (SkinManifest) -> SkinManifest): List<String> = SkinValidator.validate(change(builtin()))

// The manifest is immutable: these make the changed copies the ported Swift tests make in place.

fun SkinManifest.withState(name: String, change: (StateSpec) -> StateSpec) =
    copy(states = states + (name to change(states.getValue(name))))

fun SkinManifest.withPart(name: String, change: (SkinPart) -> SkinPart) =
    copy(parts = parts + (name to change(parts.getValue(name))))

fun SkinManifest.withAccessory(name: String, change: (AccessorySpec) -> AccessorySpec) =
    copy(accessories = accessories + (name to change(accessories.getValue(name))))

/** The first particle of [effect]'s `particles` changed. */
fun SkinManifest.withFirstParticle(effect: String, change: (ParticleSpec) -> ParticleSpec): SkinManifest {
    val spec = effects.getValue(effect)
    val particles = spec.particles!!
    return copy(effects = effects + (effect to spec.copy(particles = listOf(change(particles[0])) + particles.drop(1))))
}
