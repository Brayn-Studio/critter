package local.critter.core.skin

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import local.critter.core.motion.GazeZone
import local.critter.core.protocol.PetState
import kotlin.math.abs
import kotlin.math.floor

/** The five states a manifest must define (the protocol's `unknown` is not one of them). */
val SKIN_STATES: List<PetState> = PetState.entries.filter { it != PetState.unknown }

/**
 * A complete, data-driven description of how the pet looks and animates: no animation is
 * hardcoded, so a brand-replacement skin only has to supply a valid manifest. Field names
 * equal the JSON keys of schema 2. Mirrors `SkinManifest` in Skin.swift. Immutable, all the way
 * down: one manifest is shared by every Critter wearing the skin (Swift's is a value type).
 * A changed manifest is a `copy`.
 */
@Serializable
data class SkinManifest(
    val schema: Int,
    val name: String,
    /** What the settings call the skin ("小芽 Sprig"); optional. */
    val title: String? = null,
    /** Duration of one tick in milliseconds. */
    val tickMs: Int,
    /** Base box `[width, height]` in square pixel cells; row `height` is the ground. */
    val grid: List<Int>,
    val palette: Map<String, String>,
    val parts: Map<String, SkinPart>,
    val poses: Map<String, List<String>>,
    val glyphs: Map<String, List<String>>,
    val clips: Map<String, List<ClipKey>>,
    val effects: Map<String, EffectSpec>,
    val accessories: Map<String, AccessorySpec>,
    val states: Map<String, StateSpec>,
    val interactions: InteractionNames,
    val props: Map<String, PropSpec>,
) {
    /** The spec of `s`. Only call on a manifest that passed `SkinValidator`. */
    fun state(s: PetState): StateSpec = states.getValue(s.name)
}

/** A rectangle of pixel rows placed at `at` (top-left, base-box coordinates, may be negative). */
@Serializable
data class SkinPart(val at: List<Int>, val rows: List<String>)

/**
 * One key of a motion clip: show `pose` for `ticks` ticks offset by (`dx`, `dy`) cells,
 * firing `effect` once when the key starts. JSON is an array: `[pose, ticks]`,
 * `[pose, ticks, dx, dy]` or `[pose, ticks, dx, dy, effect]`.
 */
@Serializable(with = ClipKeySerializer::class)
data class ClipKey(
    val pose: String,
    val ticks: Int,
    val dx: Int = 0,
    val dy: Int = 0,
    val effect: String? = null,
)

typealias MotionClip = List<ClipKey>

object ClipKeySerializer : KSerializer<ClipKey> {
    override val descriptor = JsonElement.serializer().descriptor

    override fun deserialize(decoder: Decoder): ClipKey {
        val a = (decoder as JsonDecoder).decodeJsonElement() as? JsonArray
            ?: throw SerializationException("clip key must be an array")
        val n = a.size
        if (n != 2 && n != 4 && n != 5) throw SerializationException("clip key needs 2, 4 or 5 elements")
        fun str(i: Int) = (a[i] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: throw SerializationException("clip key element $i must be a string")
        fun int(i: Int) = (a[i] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
            ?: throw SerializationException("clip key element $i must be an integer")
        return ClipKey(
            pose = str(0), ticks = int(1),
            dx = if (n >= 4) int(2) else 0, dy = if (n >= 4) int(3) else 0,
            effect = if (n == 5) str(4) else null,
        )
    }

    /** Emits the shortest form that can express the key. */
    override fun serialize(encoder: Encoder, value: ClipKey) {
        val out = mutableListOf<JsonElement>(JsonPrimitive(value.pose), JsonPrimitive(value.ticks))
        if (value.effect != null) {
            out += JsonPrimitive(value.dx); out += JsonPrimitive(value.dy); out += JsonPrimitive(value.effect)
        } else if (value.dx != 0 || value.dy != 0) {
            out += JsonPrimitive(value.dx); out += JsonPrimitive(value.dy)
        }
        (encoder as JsonEncoder).encodeJsonElement(JsonArray(out))
    }
}

/** A number or an inclusive `[min, max]` range (uniformly random when min < max). */
@Serializable(with = SpanSerializer::class)
data class Span(val min: Double, val max: Double) {
    constructor(v: Double) : this(v, v)
}

object SpanSerializer : KSerializer<Span> {
    override val descriptor = JsonElement.serializer().descriptor

    override fun deserialize(decoder: Decoder): Span {
        val e = (decoder as JsonDecoder).decodeJsonElement()
        fun num(p: JsonElement) = (p as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
            ?: throw SerializationException("span needs numbers")
        if (e is JsonPrimitive) return Span(num(e))
        val a = e as? JsonArray ?: throw SerializationException("span must be a number or [min, max]")
        if (a.size != 2) throw SerializationException("span range needs 2 numbers")
        return Span(num(a[0]), num(a[1]))
    }

    override fun serialize(encoder: Encoder, value: Span) {
        fun num(d: Double): JsonPrimitive =
            if (d == Math.floor(d) && Math.abs(d) < 1e15) JsonPrimitive(d.toLong()) else JsonPrimitive(d)
        val e = if (value.min == value.max) num(value.min) else JsonArray(listOf(num(value.min), num(value.max)))
        (encoder as JsonEncoder).encodeJsonElement(e)
    }
}

/** One emitted particle (or a repeated group, via `count`). */
@Serializable
data class ParticleSpec(
    val count: Int? = null,
    val glyph: String,
    val color: String? = null,
    val colors: List<String>? = null,
    val x: Span,
    val y: Span,
    val vx: Span? = null,
    val vy: Span? = null,
    val ay: Double? = null,
    val life: Span,
    val sway: Double? = null,
    val pop: Boolean? = null,
    val shrinkTo: String? = null,
)

/** A particle effect: all `particles` on every trigger, or the next group of `cycle` each time. */
@Serializable
data class EffectSpec(
    val particles: List<ParticleSpec>? = null,
    val cycle: List<List<ParticleSpec>>? = null,
)

/** A marker above the head (spinner, question mark, check, bang). */
@Serializable
data class AccessorySpec(
    val glyph: String? = null,
    val frames: List<String>? = null,
    val color: String,
    val periodMs: Int? = null,
    val box: Int? = null,
    val reduced: String? = null,
    val bobEvery: Int? = null,
    val twinkleEvery: Int? = null,
    val twinkle: String? = null,
)

/** A clip name with a pick weight; JSON is `["blink", 6]`. */
@Serializable(with = WeightedClipSerializer::class)
data class WeightedClip(val clip: String, val weight: Int)

object WeightedClipSerializer : KSerializer<WeightedClip> {
    override val descriptor = JsonElement.serializer().descriptor

    override fun deserialize(decoder: Decoder): WeightedClip {
        val a = (decoder as JsonDecoder).decodeJsonElement() as? JsonArray
            ?: throw SerializationException("weighted clip must be an array")
        if (a.size != 2) throw SerializationException("weighted clip needs [clip, weight]")
        val clip = (a[0] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: throw SerializationException("weighted clip name must be a string")
        val weight = (a[1] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
            ?: throw SerializationException("weighted clip weight must be an integer")
        return WeightedClip(clip, weight)
    }

    override fun serialize(encoder: Encoder, value: WeightedClip) {
        (encoder as JsonEncoder).encodeJsonElement(JsonArray(listOf(JsonPrimitive(value.clip), JsonPrimitive(value.weight))))
    }
}

/** Random small gestures: every `every[0]..every[1]` ticks, one weighted pick plays. */
@Serializable
data class FidgetSpec(val every: List<Int>, val pick: List<WeightedClip>)

@Serializable
data class SleepSpec(val after: Int, val doze: String, val loop: String, val wake: String, val still: String)

@Serializable
data class ImpatientSpec(val after: Int, val loop: String)

@Serializable
data class BadgeSpec(
    val glyph: String,
    val color: String,
    val x: Int,
    val hopEvery: Int,
    val impatientHopEvery: Int,
)

@Serializable
data class VariantSpec(
    val loop: String,
    val enter: String? = null,
    val exit: String? = null,
    val prop: String? = null,
)

/**
 * The poses a state looks around with, in place of `interactions.look*` (so a state can keep
 * what it wears, like the done state's flower, while its eyes follow the pointer).
 */
@Serializable
data class GazePoses(
    val left: String,
    val right: String,
    val up: String,
    val down: String,
    val center: String,
) {
    fun pose(zone: GazeZone): String = when (zone) {
        GazeZone.left -> left
        GazeZone.right -> right
        GazeZone.up -> up
        GazeZone.down -> down
        GazeZone.center -> center
    }
}

/** A color post-processing effect applied to a whole state's poses. */
@Serializable
enum class Tint { dim }

/**
 * Everything one `PetState` needs: entry and loop clips, tint, head marker, the pose shown
 * under reduced motion (`still`), and the optional behaviours layered on top.
 */
@Serializable
data class StateSpec(
    val enter: String? = null,
    val loop: String? = null,
    val tint: Tint? = null,
    val accessory: String? = null,
    val still: String,
    val stillDy: Int? = null,
    val seen: String? = null,
    val fidget: FidgetSpec? = null,
    val sleep: SleepSpec? = null,
    val impatient: ImpatientSpec? = null,
    val badge: BadgeSpec? = null,
    val variants: Map<String, VariantSpec>? = null,
    val defaultVariant: String? = null,
    val gaze: GazePoses? = null,
)

/** Names of the clips, poses and effects the engine uses for interactions and orchestration. */
@Serializable
data class InteractionNames(
    val notice: String,
    val pet: String,
    val petEnd: String,
    val press: String,
    val boopEnd: String,
    val held: String,
    val heldStill: String,
    val drop: String,
    val blink: String,
    val join: String,
    val leave: String,
    val appear: String,
    val vanish: String,
    val hop: String,
    val land: String,
    val blinkPose: String,
    val landDust: String,
    val walkLeft: List<String>,
    val walkRight: List<String>,
    val lookLeft: String,
    val lookRight: String,
    val lookUp: String,
    val lookDown: String,
    val lookCenter: String,
)

/** A prop bound to a clip variant (the juggled balls). */
@Serializable
data class PropSpec(val glyph: String, val colors: List<String>)

/**
 * Checks a manifest is internally consistent and complete enough to render, so a broken or
 * partial custom skin can be safely rejected (falling back to sprig) instead of crashing or
 * rendering garbage. Effect names starting with "@" are reserved for effects the engine
 * generates at runtime, so a manifest may neither define nor reference them.
 *
 * Every number is bounded too, so no skin can overflow or hog the CPU at runtime: `tickMs`
 * 16…1000, offsets within ±64 cells, pixel art at most 64×64, durations and periods
 * 1…100000, badge hops 1…1000 ticks, fidget weights 1…1000, at most 64 particles per spec
 * living 1…300 ticks, and particle positions, speeds, acceleration and sway within ±1000.
 */
object SkinValidator {
    fun validate(m: SkinManifest): List<String> {
        val out = mutableListOf<String>()
        fun bad(s: String) { out += s }
        fun number(v: Int, range: IntRange, what: String) {
            if (v !in range) bad("$what must be within ${range.first}…${range.last}")
        }
        fun number(v: Double, range: ClosedFloatingPointRange<Double>, what: String) {
            if (v !in range) bad("$what must be within ${range.start}…${range.endInclusive}")
        }
        fun span(s: Span?, range: ClosedFloatingPointRange<Double>, what: String) {
            if (s == null) return
            if (s.min !in range || s.max !in range) bad("$what must be within ${range.start}…${range.endInclusive}")
        }
        val cells = -64..64
        val ticks = 1..100_000
        val motion = -1000.0..1000.0

        if (m.schema != 2) bad("unsupported schema ${m.schema} (need 2)")
        m.title?.let { t ->
            if (t.isEmpty() || t.codePointCount(0, t.length) > 40) bad("title must be 1…40 characters")
        }
        number(m.tickMs, 16..1000, "tickMs")
        // The renderer, layout, hover and gaze all draw an 18×10 box with the ground on row 10.
        if (m.grid != listOf(18, 10)) bad("grid must be [18, 10]")

        val paletteChars = m.palette.keys.filter { it.length == 1 }.map { it[0] }.toSet()
        if ('.' in paletteChars) bad("palette must not define '.' (transparent)")
        for ((key, value) in m.palette) if (!isHex(value)) bad("palette $key is not a #RRGGBB color")

        fun checkRows(rows: List<String>, what: String, allowed: (Char) -> Boolean) {
            if (rows.isEmpty()) { bad("$what has no rows"); return }
            val width = rows[0].length
            if (width == 0 || rows.any { it.length != width }) bad("$what has ragged rows")
            if (rows.size > 64 || width > 64) bad("$what is larger than 64×64")
            for (ch in rows.joinToString("").toSet()) {
                if (ch != '.' && !allowed(ch)) bad("$what uses character '$ch' not allowed")
            }
        }

        for ((name, part) in m.parts) {
            if (part.at.size != 2) bad("part $name needs at: [x, y]")
            for (v in part.at) number(v, cells, "part $name at")
            checkRows(part.rows, "part $name") { it in paletteChars }
        }
        for ((name, glyph) in m.glyphs) checkRows(glyph, "glyph $name") { it == '#' }

        for ((name, partNames) in m.poses) {
            if (partNames.isEmpty()) bad("pose $name has no parts")
            for (p in partNames) if (m.parts[p] == null) bad("pose $name references unknown part $p")
        }

        fun pose(n: String, ctx: String) { if (m.poses[n] == null) bad("$ctx references unknown pose $n") }
        fun clip(n: String, ctx: String) { if (m.clips[n] == null) bad("$ctx references unknown clip $n") }
        fun effect(n: String, ctx: String) { if (m.effects[n] == null) bad("$ctx references unknown effect $n") }
        fun glyph(n: String, ctx: String) { if (m.glyphs[n] == null) bad("$ctx references unknown glyph $n") }
        fun color(c: String, ctx: String) { if (!isHex(c)) bad("$ctx has invalid color $c") }

        for ((name, keys) in m.clips) {
            if (keys.isEmpty()) bad("clip $name has no keys")
            for (key in keys) {
                pose(key.pose, "clip $name")
                number(key.ticks, ticks, "clip $name key ticks")
                number(key.dx, cells, "clip $name key dx")
                number(key.dy, cells, "clip $name key dy")
                key.effect?.let { effect(it, "clip $name") }
            }
        }

        for ((name, spec) in m.effects) {
            if (name.startsWith("@")) bad("effect $name uses the reserved '@' prefix")
            if (spec.particles == null && spec.cycle == null) bad("effect $name has neither particles nor cycle")
            val groups = (spec.particles?.let { listOf(it) } ?: emptyList()) + (spec.cycle ?: emptyList())
            if (groups.any { it.isEmpty() }) bad("effect $name has an empty particle group")
            for (p in groups.flatten()) {
                glyph(p.glyph, "effect $name")
                p.shrinkTo?.let { glyph(it, "effect $name") }
                p.color?.let { color(it, "effect $name") }
                for (c in p.colors ?: emptyList()) color(c, "effect $name")
                if (p.color == null && (p.colors ?: emptyList()).isEmpty()) bad("effect $name has a particle without a color")
                p.count?.let { number(it, 1..64, "effect $name particle count") }
                span(p.life, 1.0..300.0, "effect $name particle life")
                span(p.x, motion, "effect $name particle x")
                span(p.y, motion, "effect $name particle y")
                span(p.vx, motion, "effect $name particle vx")
                span(p.vy, motion, "effect $name particle vy")
                p.ay?.let { number(it, motion, "effect $name particle ay") }
                p.sway?.let { number(it, motion, "effect $name particle sway") }
            }
        }

        for ((name, a) in m.accessories) {
            color(a.color, "accessory $name")
            if (a.glyph == null && (a.frames ?: emptyList()).isEmpty()) bad("accessory $name has no glyph or frames")
            a.glyph?.let { glyph(it, "accessory $name") }
            for (g in a.frames ?: emptyList()) glyph(g, "accessory $name")
            a.reduced?.let { glyph(it, "accessory $name") }
            a.twinkle?.let { effect(it, "accessory $name") }
            a.periodMs?.let { number(it, 1..100_000, "accessory $name periodMs") }
            a.box?.let { number(it, 1..64, "accessory $name box") }
            a.bobEvery?.let { number(it, ticks, "accessory $name bobEvery") }
            a.twinkleEvery?.let { number(it, ticks, "accessory $name twinkleEvery") }
        }

        for (state in SKIN_STATES) if (m.states[state.name] == null) bad("missing state ${state.name}")
        for ((name, s) in m.states) {
            val ctx = "state $name"
            if (SKIN_STATES.none { it.name == name }) bad("$ctx is not a known state")
            s.enter?.let { clip(it, ctx) }
            s.loop?.let { clip(it, ctx) }
            s.seen?.let { clip(it, ctx) }
            if (s.loop == null && (s.variants ?: emptyMap()).isEmpty()) bad("$ctx has neither loop nor variants")
            pose(s.still, ctx)
            s.accessory?.let { if (m.accessories[it] == null) bad("$ctx references unknown accessory $it") }
            s.stillDy?.let { number(it, cells, "$ctx stillDy") }
            s.fidget?.let { f ->
                if (f.every.size != 2 || !f.every.all { it in ticks } || f.every[1] < f.every[0]) {
                    bad("$ctx fidget.every must be [min, max] within ${ticks.first}…${ticks.last}")
                }
                if (f.pick.isEmpty()) bad("$ctx fidget has nothing to pick")
                for (w in f.pick) {
                    clip(w.clip, ctx)
                    number(w.weight, 1..1000, "$ctx fidget weight")
                }
            }
            s.sleep?.let { z ->
                clip(z.doze, ctx); clip(z.loop, ctx); clip(z.wake, ctx); pose(z.still, ctx)
                number(z.after, ticks, "$ctx sleep.after")
            }
            s.impatient?.let { i ->
                clip(i.loop, ctx)
                number(i.after, ticks, "$ctx impatient.after")
            }
            s.gaze?.let { g ->
                for (p in listOf(g.left, g.right, g.up, g.down, g.center)) pose(p, "$ctx gaze")
            }
            s.badge?.let { b ->
                glyph(b.glyph, ctx); color(b.color, ctx)
                number(b.x, cells, "$ctx badge x")
                // Scanned tick by tick for the next hop, so kept short.
                number(b.hopEvery, 1..1000, "$ctx badge hopEvery")
                number(b.impatientHopEvery, 1..1000, "$ctx badge impatientHopEvery")
            }
            s.variants?.let { variants ->
                for ((vn, v) in variants) {
                    clip(v.loop, "$ctx variant $vn")
                    v.enter?.let { clip(it, "$ctx variant $vn") }
                    v.exit?.let { clip(it, "$ctx variant $vn") }
                    v.prop?.let { if (m.props[it] == null) bad("$ctx variant $vn references unknown prop $it") }
                }
                val d = s.defaultVariant
                if (d != null) {
                    if (variants[d] == null) bad("$ctx defaultVariant $d is not a variant")
                } else if (variants.isNotEmpty()) {
                    bad("$ctx has variants but no defaultVariant")
                }
            }
        }

        val i = m.interactions
        for (n in listOf(i.notice, i.pet, i.petEnd, i.press, i.boopEnd, i.held, i.drop, i.blink,
            i.join, i.leave, i.appear, i.vanish)) clip(n, "interactions")
        for (n in listOf(i.heldStill, i.hop, i.land, i.blinkPose, i.lookLeft, i.lookRight, i.lookUp,
            i.lookDown, i.lookCenter) + i.walkLeft + i.walkRight) pose(n, "interactions")
        effect(i.landDust, "interactions")
        if (i.walkLeft.isEmpty() || i.walkRight.isEmpty()) bad("interactions walk cycles must not be empty")

        for ((name, p) in m.props) {
            glyph(p.glyph, "prop $name")
            if (p.colors.isEmpty()) bad("prop $name has no colors")
            for (c in p.colors) color(c, "prop $name")
        }

        return out
    }

    private fun isHex(s: String): Boolean =
        s.length == 7 && s[0] == '#' && s.drop(1).all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}

/** The JSON settings every manifest is read and written with (unknown keys are ignored). */
val SkinJson = Json { ignoreUnknownKeys = true }

/** Decodes skin manifests. */
object SkinLoader {
    /** The manifest in `json`, or null if it doesn't decode or fails `SkinValidator`. */
    fun decode(json: String): SkinManifest? {
        val manifest = try {
            SkinJson.decodeFromJsonElement(SkinManifest.serializer(), wholeNumbersAsIntegers(SkinJson.parseToJsonElement(json)))
        } catch (_: SerializationException) {
            return null
        } catch (_: IllegalArgumentException) {
            return null
        }
        return manifest.takeIf { SkinValidator.validate(it).isEmpty() }
    }

    /**
     * JSON has one number type, and Swift's decoder reads a whole number written as `60.0` or `6e1` into an Int, so
     * the Mac shows such a skin. Here they become integer literals before decoding; a fraction stays one (and is
     * no Int), and a `Double` field takes an integer literal just the same.
     */
    private fun wholeNumbersAsIntegers(e: JsonElement): JsonElement = when (e) {
        is JsonObject -> JsonObject(e.mapValues { wholeNumbersAsIntegers(it.value) })
        is JsonArray -> JsonArray(e.map(::wholeNumbersAsIntegers))
        is JsonNull -> e
        is JsonPrimitive -> {
            val c = e.content
            val whole = if (e.isString || c.none { it == '.' || it == 'e' || it == 'E' }) null
            else c.toDoubleOrNull()?.takeIf { it == floor(it) && abs(it) < 1e15 }
            if (whole != null) JsonPrimitive(whole.toLong()) else e
        }
    }
}
