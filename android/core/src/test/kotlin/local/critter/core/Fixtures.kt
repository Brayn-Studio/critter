package local.critter.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgePrefs
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SessionSource
import local.critter.core.protocol.SnapshotBody

fun session(id: String, state: PetState = PetState.idle) = BridgeSession(
    id = id, name = id, source = SessionSource.terminal, state = state, cwd = "~", skin = "clawd",
    eventTime = 1, startedAt = 1, tracked = true,
)

fun pending(
    requestId: String,
    sessionId: String,
    kind: PendingKind = PendingKind.permission,
    createdAt: Long = 1,
    input: JsonObject? = null,
) = BridgePending(requestId = requestId, sessionId = sessionId, kind = kind, input = input, createdAt = createdAt)

fun body(sessions: List<BridgeSession>, pending: List<BridgePending> = emptyList()) = SnapshotBody(
    sessions = sessions, pending = pending,
    prefs = BridgePrefs(skin = "clawd", randomSkins = false, idleDim = 1.0, mergeThreshold = 4),
)

/** An `AskUserQuestion` input; each pair is the question text and whether it is multi-select. */
fun questions(vararg qs: Pair<String, Boolean>): JsonObject = buildJsonObject {
    put("questions", buildJsonArray {
        for ((q, multi) in qs) add(buildJsonObject {
            put("question", q)
            put("multiSelect", multi)
        })
    })
}
