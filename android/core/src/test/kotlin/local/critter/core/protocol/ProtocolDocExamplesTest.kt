package local.critter.core.protocol

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * The JSON examples in docs/critter-bridge-protocol.md, held against this app's codec: every Mac -> phone example
 * decodes and loses none of its keys, and every phone -> Mac example has exactly the keys [encode] writes. (The Mac
 * side has the same check in Tests/CritterCoreTests/ProtocolDocExamplesTests.swift.)
 */
class ProtocolDocExamplesTest {
    /** Tests run in android/core. */
    private val doc = File("../../docs/critter-bridge-protocol.md")

    private data class Example(val fromPhone: Boolean, val line: Int, val json: JsonObject) {
        val type: String? get() = json["type"]?.jsonPrimitive?.content
    }

    /**
     * Every ```json block, and which way it travels (by its `## Phone -> Mac` / `## Mac -> phone` section).
     * The `## iOS push registration` section is skipped: it is an optional extension only the iPhone app speaks
     * (a `push` frame and the APNs payloads), which this app neither sends nor reads.
     */
    private fun examples(): List<Example> {
        val examples = mutableListOf<Example>()
        var fromPhone: Boolean? = null
        var skipped = false
        var start = 0
        var block: MutableList<String>? = null
        doc.readLines().forEachIndexed { index, line ->
            val open = block
            when {
                open != null && line.startsWith("```") -> {
                    if (!skipped) {
                        val direction = checkNotNull(fromPhone) { "docs line $start: a JSON example outside the message sections" }
                        examples += Example(direction, start, BridgeJson.parseToJsonElement(open.joinToString("\n")).jsonObject)
                    }
                    block = null
                }
                open != null -> open += line
                line == "```json" -> {
                    block = mutableListOf()
                    start = index + 2
                }
                line.startsWith("## ") -> {
                    skipped = line.lowercase().startsWith("## ios push registration")
                    fromPhone = when {
                        line.lowercase().startsWith("## phone -> mac") -> true
                        line.lowercase().startsWith("## mac -> phone") -> false
                        else -> null
                    }
                }
            }
        }
        return examples
    }

    /** Every key as a path from the top (`/sessions[]/context/usedPercent`); arrays merge their elements. */
    private fun keyPaths(element: JsonElement, prefix: String = ""): Set<String> = when (element) {
        is JsonObject -> element.flatMap { (key, value) -> keyPaths(value, "$prefix/$key") + "$prefix/$key" }.toSet()
        is JsonArray -> element.flatMap { keyPaths(it, "$prefix[]") }.toSet()
        else -> emptySet()
    }

    /** A phone -> Mac example read back into the message this app would send (the app itself never parses one). */
    private fun clientMessage(json: JsonObject): ClientMessage {
        fun str(key: String) = json[key]?.jsonPrimitive?.content
        return when (str("type")) {
            "hello" -> ClientMessage.Hello(
                app = str("app")!!, deviceId = str("deviceId")!!, token = str("token")!!,
                protocol = json["protocol"]!!.jsonPrimitive.int,
            )
            "pair" -> ClientMessage.Pair(str("code")!!, str("deviceName")!!)
            "answer" -> ClientMessage.Answer(str("id"), str("requestId")!!, BridgeJson.decodeFromJsonElement(json["payload"]!!))
            "seen" -> ClientMessage.Seen(str("id"), str("sessionId")!!)
            "say" -> ClientMessage.Say(str("id"), str("sessionId")!!, str("text")!!)
            "skin" -> ClientMessage.SkinRequest(str("id"), str("name")!!)
            else -> error("no phone -> Mac message of type ${str("type")}")
        }
    }

    /** Defaults included, so a value equal to its default still shows its key. */
    private val withDefaults = Json(from = BridgeJson) { encodeDefaults = true }

    /** Everything a decoded Mac -> phone message holds, written back in the wire layout (the app never sends one). */
    private fun serverJson(msg: ServerMessage): JsonObject = buildJsonObject {
        when (msg) {
            is ServerMessage.Welcome -> {
                put("type", "welcome")
                put("macName", msg.macName)
                msg.version?.let { put("version", it) }
            }
            is ServerMessage.Paired -> {
                put("type", "paired")
                put("deviceId", msg.deviceId)
                put("macName", msg.macName)
                put("token", msg.token)
            }
            is ServerMessage.Denied -> {
                put("type", "denied")
                put("reason", withDefaults.encodeToJsonElement(msg.reason))
            }
            is ServerMessage.Snapshot -> {
                put("type", "snapshot")
                put("seq", msg.seq)
                put("sentAt", msg.sentAt)
                withDefaults.encodeToJsonElement(msg.body).jsonObject.forEach { (key, value) -> put(key, value) }
            }
            is ServerMessage.Skin -> {
                put("type", "skin")
                msg.id?.let { put("id", it) }
                put("name", msg.name)
                msg.manifest?.let { put("manifest", it) }
            }
            is ServerMessage.Result -> {
                put("type", "result")
                msg.id?.let { put("id", it) }
                put("ok", msg.ok)
                msg.reason?.let { put("reason", withDefaults.encodeToJsonElement(it)) }
                msg.message?.let { put("message", it) }
            }
        }
    }

    @Test fun docHasAnExampleOfEveryMessage() {
        val examples = examples()
        assertEquals(
            setOf("hello", "pair", "answer", "seen", "say", "skin"),
            examples.filter { it.fromPhone }.mapNotNull { it.type }.toSet(),
        )
        assertEquals(
            setOf("welcome", "paired", "denied", "snapshot", "skin", "result"),
            examples.filter { !it.fromPhone }.mapNotNull { it.type }.toSet(),
        )
    }

    @Test fun everyMacExampleDecodesKeepingAllItsKeys() {
        for (example in examples().filter { !it.fromPhone }) {
            val msg = assertNotNull(decodeServer(example.json.toString()), "docs line ${example.line}: does not decode")
            assertEquals(keyPaths(example.json), keyPaths(serverJson(msg)), "docs line ${example.line}")
        }
    }

    @Test fun everyPhoneExampleHasTheKeysEncodeWrites() {
        for (example in examples().filter { it.fromPhone }) {
            val written = BridgeJson.parseToJsonElement(encode(clientMessage(example.json)))
            assertEquals(keyPaths(example.json), keyPaths(written), "docs line ${example.line}")
        }
    }
}
