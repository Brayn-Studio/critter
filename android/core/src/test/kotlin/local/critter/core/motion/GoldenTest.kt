package local.critter.core.motion

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import local.critter.core.bundledSkin
import local.critter.core.protocol.PetState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Replays the scenarios the Swift engine exported (Tests/CritterCoreTests/GoldenExportTests.swift)
 * and compares every tick: the snapshot and `ticksUntilChange` must equal the Swift ones. The
 * golden files only list the ticks where either changed, so a tick in between must equal the
 * last listed one. On a mismatch the message names the scenario, the tick and the field. Never
 * edit the golden files to make this pass: fix the port.
 */
class GoldenTest {
    private val json = Json

    private fun JsonObject.str(key: String) = getValue(key).jsonPrimitive.content
    private fun JsonObject.optStr(key: String) = this[key]?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull

    private fun apply(o: JsonObject, a: MotionActor) {
        when (val name = o.str("op")) {
            "enterState" -> a.enterState(PetState.valueOf(o.str("state")), quiet = o.getValue("quiet").jsonPrimitive.boolean)
            "setActivity" -> a.setActivity(o.optStr("activity"))
            "wake" -> a.wake()
            "play" -> a.play(o.str("clip"))
            "setMode" -> a.setMode(o.optStr("mode"))
            "cancelOnce" -> a.cancelOnce()
            "setLift" -> a.lift = o.getValue("value").jsonPrimitive.int
            "setLag" -> a.lag = o.getValue("value").jsonPrimitive.int
            "setGaze" -> a.setGaze(o.optStr("zone")?.let { GazeZone.valueOf(it) })
            "startFollow" -> a.startFollow(lookLeft = o.getValue("lookLeft").jsonPrimitive.boolean)
            "followShift" -> a.followShift(dx = o.getValue("dx").jsonPrimitive.double, dy = o.getValue("dy").jsonPrimitive.double)
            "releaseFollow" -> a.releaseFollow()
            "travel" -> a.travel(
                fromDx = o.getValue("fromDx").jsonPrimitive.int,
                fromDy = o.getValue("fromDy").jsonPrimitive.int,
                delay = o.getValue("delay").jsonPrimitive.int,
                seat = o["seatRow"]?.jsonPrimitive?.intOrNull?.let { PileSeating.seat(row = it) },
            )
            "unseat" -> a.unseat()
            "holdUnderground" -> a.holdUnderground(depth = o.getValue("depth").jsonPrimitive.int)
            "releaseUnderground" -> a.releaseUnderground()
            "setHidden" -> a.hidden = o.getValue("value").jsonPrimitive.boolean
            "setNoAccessory" -> a.noAccessory = o.getValue("value").jsonPrimitive.boolean
            "setReduceMotion" -> a.reduceMotion = o.getValue("value").jsonPrimitive.boolean
            else -> fail("unknown op $name")
        }
    }

    /** The first field of the snapshots that differs, or null. */
    private fun firstDifference(e: ActorSnapshot, a: ActorSnapshot): String? {
        val fields = listOf<Triple<String, Any?, Any?>>(
            Triple("hidden", e.hidden, a.hidden), Triple("pose", e.pose, a.pose),
            Triple("bodyX", e.bodyX, a.bodyX), Triple("bodyY", e.bodyY, a.bodyY),
            Triple("offsetX", e.offsetX, a.offsetX), Triple("offsetY", e.offsetY, a.offsetY),
            Triple("tint", e.tint, a.tint), Triple("alpha", e.alpha, a.alpha), Triple("z", e.z, a.z),
            Triple("shadowWidth", e.shadowWidth, a.shadowWidth),
            Triple("accessory", e.accessory, a.accessory), Triple("badge", e.badge, a.badge),
            Triple("particles", e.particles, a.particles), Triple("props", e.props, a.props),
        )
        return fields.firstOrNull { it.second != it.third }?.let { "${it.first}: expected ${it.second} but was ${it.third}" }
    }

    /** Replays `name`; returns (ticks compared, frames listed in the golden file). */
    private fun replay(name: String): Pair<Int, Int> {
        val text = javaClass.getResourceAsStream("/golden/$name.json")!!.use { it.readBytes().toString(Charsets.UTF_8) }
        val doc = json.parseToJsonElement(text).jsonObject
        val skin = bundledSkin(doc.str("skin"))
        val actor = MotionActor(
            skin = skin,
            rng = MotionRNG(seed = doc.getValue("seed").jsonPrimitive.long),
            reduceMotion = doc.getValue("reduceMotion").jsonPrimitive.boolean,
        )
        val ticks = doc.getValue("ticks").jsonPrimitive.int
        val ops = doc.getValue("ops").jsonArray.map { it.jsonObject }
        val frames = doc.getValue("frames").jsonArray.map { it.jsonObject }
        assertTrue(frames.isNotEmpty() && frames[0].getValue("tick").jsonPrimitive.int == 0, "$name: first frame must be tick 0")

        var next = 0 // index of the next listed frame
        var expectedSnapshot: ActorSnapshot? = null
        var expectedUntil = 0
        for (tick in 0 until ticks) {
            for (o in ops) if (o.getValue("at").jsonPrimitive.int == tick) apply(o, actor)
            if (next < frames.size && frames[next].getValue("tick").jsonPrimitive.int == tick) {
                val f = frames[next++]
                expectedSnapshot = json.decodeFromJsonElement(ActorSnapshot.serializer(), f.getValue("snapshot"))
                expectedUntil = f.getValue("ticksUntilChange").jsonPrimitive.int
            }
            val actual = actor.snapshot()
            firstDifference(expectedSnapshot!!, actual)?.let { fail("$name tick $tick, $it") }
            assertEquals(expectedUntil, actor.ticksUntilChange(), "$name tick $tick, ticksUntilChange")
            actor.step()
        }
        assertEquals(frames.size, next, "$name: every listed frame is reached")
        return ticks to frames.size
    }

    private fun check(name: String, minTicks: Int) {
        val (compared, listed) = replay(name)
        println("golden $name: $compared ticks compared, $listed listed")
        assertTrue(compared >= minTicks, "$name compares at least $minTicks ticks")
    }

    @Test fun sprigIdle2400() = check("sprig-idle-2400", 2400)

    @Test fun bristleStates() = check("bristle-states", 1800)

    @Test fun sprigRunningVariants() = check("sprig-running-variants", 600)

    @Test fun mochiInteractions() = check("mochi-interactions", 360)

    @Test fun peepReducedMotion() = check("peep-reduced-motion", 1800)

    @Test fun sprigTravelFollow() = check("sprig-travel-follow", 700)

    @Test
    fun goldenSnapshotsAreNotTrivial() {
        // A scenario whose frames never differ would pass for any engine: make sure the
        // golden files really show the animations they claim to cover.
        fun poses(name: String): Set<String> {
            val text = javaClass.getResourceAsStream("/golden/$name.json")!!.use { it.readBytes().toString(Charsets.UTF_8) }
            val doc = json.parseToJsonElement(text).jsonObject
            return doc.getValue("frames").jsonArray.map { it.jsonObject.getValue("snapshot").jsonObject.str("pose") }.toSet()
        }
        assertTrue("shut" in poses("sprig-idle-2400"), "the idle scenario falls asleep")
        assertTrue(poses("bristle-states").size > 8)
        assertTrue(poses("mochi-interactions").size > 4)
    }
}
