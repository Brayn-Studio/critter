package local.critter.core.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

// The wire format is defined in docs/critter-bridge-protocol.md; keep these models in step with it.

val BridgeJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
}

/** The only protocol version this app speaks (`hello.protocol`). */
const val PROTOCOL_VERSION = 1

/** Decodes an enum by name; a value this app does not know (a newer protocol) becomes [fallback]. */
abstract class LenientEnumSerializer<E : Enum<E>>(
    name: String,
    private val values: List<E>,
    private val fallback: E,
) : KSerializer<E> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor(name, PrimitiveKind.STRING)
    override fun deserialize(decoder: Decoder): E {
        val raw = decoder.decodeString()
        return values.firstOrNull { it.name == raw } ?: fallback
    }
    override fun serialize(encoder: Encoder, value: E) = encoder.encodeString(value.name)
}

object SessionSourceSerializer : LenientEnumSerializer<SessionSource>("SessionSource", SessionSource.entries, SessionSource.other)
object PetStateSerializer : LenientEnumSerializer<PetState>("PetState", PetState.entries, PetState.unknown)
object PendingKindSerializer : LenientEnumSerializer<PendingKind>("PendingKind", PendingKind.entries, PendingKind.unknown)
object SoundThemeSerializer : LenientEnumSerializer<SoundTheme>("SoundTheme", SoundTheme.entries, SoundTheme.unknown)
object DenyReasonSerializer : LenientEnumSerializer<DenyReason>("DenyReason", DenyReason.entries, DenyReason.unknown)
object ResultReasonSerializer : LenientEnumSerializer<ResultReason>("ResultReason", ResultReason.entries, ResultReason.unknown)

@Serializable(with = SessionSourceSerializer::class)
enum class SessionSource { terminal, vscode, desktop, other }

@Serializable(with = PetStateSerializer::class)
enum class PetState { idle, running, waiting, done, error, unknown }

@Serializable(with = PendingKindSerializer::class)
enum class PendingKind { permission, question, plan, unknown }

@Serializable(with = SoundThemeSerializer::class)
enum class SoundTheme { voice, pixel, marimba, system, unknown }

@Serializable(with = DenyReasonSerializer::class)
enum class DenyReason { badToken, badCode, rejected, protocol, unknown }

@Serializable(with = ResultReasonSerializer::class)
enum class ResultReason { resolved, invalid, expired, unavailable, failed, unknown }

@Serializable
data class BridgeContext(
    val usedPercent: Double,
    val windowSize: Long? = null,
    val estimated: Boolean = false,
)

@Serializable
data class BridgeSession(
    val id: String,
    val name: String,
    val source: SessionSource,
    val state: PetState,
    val detail: String? = null,
    val activity: String? = null,
    val cwd: String,
    val branch: String? = null,
    val model: String? = null,
    val context: BridgeContext? = null,
    val skin: String,
    val eventTime: Long,
    val startedAt: Long,
    val tracked: Boolean,
)

@Serializable
data class RateWindow(val usedPercentage: Double, val resetsAt: Long)

@Serializable
data class BridgeLimits(
    val fiveHour: RateWindow? = null,
    val sevenDay: RateWindow? = null,
    val updatedAt: Long,
)

@Serializable
data class BridgePending(
    val requestId: String,
    val sessionId: String,
    val kind: PendingKind,
    val toolName: String? = null,
    val summary: String? = null,
    val input: JsonObject? = null,
    val createdAt: Long,
    val expiresAt: Long? = null,
)

@Serializable
data class BridgePrefs(
    val skin: String,
    val randomSkins: Boolean,
    val idleDim: Double,
    val mergeThreshold: Int,
    val soundTheme: SoundTheme? = null,
)

/** The state of everything, minus the envelope (`seq`, `sentAt`). It sits at the top level of the wire frame. */
@Serializable
data class SnapshotBody(
    val sessions: List<BridgeSession>,
    val limits: BridgeLimits? = null,
    val pending: List<BridgePending>,
    val prefs: BridgePrefs,
)

/** What the phone sends for `answer`; absent fields mean "not applicable". */
@Serializable
data class AnswerPayload(
    val decision: String? = null,
    val message: String? = null,
    val answers: Map<String, String>? = null,
)

sealed interface ServerMessage {
    data class Welcome(val macName: String, val version: String? = null) : ServerMessage
    data class Paired(val deviceId: String, val macName: String, val token: String) : ServerMessage
    data class Denied(val reason: DenyReason) : ServerMessage
    data class Snapshot(val seq: Long, val sentAt: Long, val body: SnapshotBody) : ServerMessage
    data class Skin(val id: String?, val name: String, val manifest: JsonObject?) : ServerMessage
    data class Result(
        val id: String?,
        val ok: Boolean,
        val reason: ResultReason? = null,
        val message: String? = null,
    ) : ServerMessage
}

sealed interface ClientMessage {
    data class Hello(
        val app: String,
        val deviceId: String,
        val token: String,
        val protocol: Int = PROTOCOL_VERSION,
    ) : ClientMessage

    data class Pair(val code: String, val deviceName: String) : ClientMessage

    /** A phone command the Mac answers with a `result` (or `skin`) echoing [id]. */
    sealed interface Command : ClientMessage {
        val id: String?
        fun withId(id: String): Command
    }

    data class Answer(override val id: String?, val requestId: String, val payload: AnswerPayload) : Command {
        override fun withId(id: String) = copy(id = id)
    }

    data class Seen(override val id: String?, val sessionId: String) : Command {
        override fun withId(id: String) = copy(id = id)
    }

    data class Say(override val id: String?, val sessionId: String, val text: String) : Command {
        override fun withId(id: String) = copy(id = id)
    }

    data class SkinRequest(override val id: String?, val name: String) : Command {
        override fun withId(id: String) = copy(id = id)
    }
}

/** Decodes one text frame. Returns null for anything that is not a known, well-formed server message. */
fun decodeServer(text: String): ServerMessage? = try {
    val obj = BridgeJson.parseToJsonElement(text).jsonObject
    fun str(key: String) = obj[key]?.jsonPrimitive?.takeIf { it.isString }?.content
    when (str("type")) {
        "welcome" -> ServerMessage.Welcome(str("macName") ?: "", str("version"))
        "paired" -> ServerMessage.Paired(str("deviceId")!!, str("macName") ?: "", str("token")!!)
        "denied" -> ServerMessage.Denied(
            BridgeJson.decodeFromJsonElement<DenyReason>(obj["reason"] ?: throw SerializationException("no reason")),
        )
        "snapshot" -> ServerMessage.Snapshot(
            seq = obj["seq"]!!.jsonPrimitive.content.toLong(),
            sentAt = obj["sentAt"]!!.jsonPrimitive.content.toLong(),
            body = BridgeJson.decodeFromJsonElement<SnapshotBody>(obj),
        )
        "skin" -> ServerMessage.Skin(str("id"), str("name") ?: "", obj["manifest"] as? JsonObject)
        "result" -> ServerMessage.Result(
            id = str("id"),
            ok = obj["ok"]!!.jsonPrimitive.boolean,
            reason = obj["reason"]?.let { BridgeJson.decodeFromJsonElement<ResultReason>(it) },
            message = str("message"),
        )
        else -> null
    }
} catch (_: SerializationException) {
    null
} catch (_: IllegalArgumentException) {
    null
} catch (_: IllegalStateException) {
    null
} catch (_: NullPointerException) {
    null
}

fun encode(msg: ClientMessage): String = BridgeJson.encodeToString(JsonElement.serializer(), toJson(msg))

private fun toJson(msg: ClientMessage): JsonObject = buildJsonObject {
    when (msg) {
        is ClientMessage.Hello -> {
            put("type", "hello")
            put("app", msg.app)
            put("deviceId", msg.deviceId)
            put("protocol", msg.protocol)
            put("token", msg.token)
        }
        is ClientMessage.Pair -> {
            put("type", "pair")
            put("code", msg.code)
            put("deviceName", msg.deviceName)
        }
        is ClientMessage.Answer -> {
            put("type", "answer")
            msg.id?.let { put("id", it) }
            put("requestId", msg.requestId)
            put("payload", BridgeJson.encodeToJsonElement(msg.payload))
        }
        is ClientMessage.Seen -> {
            put("type", "seen")
            msg.id?.let { put("id", it) }
            put("sessionId", msg.sessionId)
        }
        is ClientMessage.Say -> {
            put("type", "say")
            msg.id?.let { put("id", it) }
            put("sessionId", msg.sessionId)
            put("text", msg.text)
        }
        is ClientMessage.SkinRequest -> {
            put("type", "skin")
            msg.id?.let { put("id", it) }
            put("name", msg.name)
        }
    }
}
