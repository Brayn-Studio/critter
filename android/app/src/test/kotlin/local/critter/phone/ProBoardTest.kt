package local.critter.phone

import kotlinx.serialization.json.JsonObject
import local.critter.core.protocol.BridgeJson
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgePrefs
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SessionSource
import local.critter.core.protocol.SnapshotBody
import local.critter.phone.ui.board.cardRequests
import local.critter.phone.ui.board.proColumns
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProBoardTest {
    private fun json(s: String) = BridgeJson.parseToJsonElement(s) as JsonObject

    private fun request(id: String, session: String, createdAt: Long, kind: PendingKind = PendingKind.permission, summary: String? = null, input: JsonObject? = null) =
        BridgePending(requestId = id, sessionId = session, kind = kind, summary = summary, input = input, createdAt = createdAt)

    private fun body(vararg pending: BridgePending) = SnapshotBody(
        sessions = emptyList(), pending = pending.toList(),
        prefs = BridgePrefs(skin = "sprig", randomSkins = false, idleDim = 1.0, mergeThreshold = 4),
    )

    @Test
    fun aLonePermissionIsShownInFullAndAnsweredOnTheCard() {
        val card = cardRequests(body(request("r1", "a", 1, summary = "运行 ls", input = json("""{"command":"ls -la"}"""))))["a"]!!
        assertEquals("r1", card.request.requestId)
        assertEquals("想 运行 ls", card.what)
        assertEquals("ls -la", card.detail)
        assertEquals(0, card.more)
        assertTrue(card.inline)
    }

    /** The buttons act on the oldest request, which is the one shown; with more waiting, the card opens instead. */
    @Test
    fun severalRequestsShowTheOldestAndOpenTheSheet() {
        val cards = cardRequests(
            body(
                request("r2", "a", 20, input = json("""{"file_path":"/tmp/b"}""")),
                request("r1", "a", 10, input = json("""{"file_path":"/tmp/a"}""")),
                request("r3", "a", 30),
            ),
        )
        val card = cards["a"]!!
        assertEquals("r1", card.request.requestId)
        assertEquals("/tmp/a", card.detail)
        assertEquals(2, card.more)
        assertFalse(card.inline)
    }

    @Test
    fun questionsAndPlansAlwaysOpenTheSheet() {
        val cards = cardRequests(
            body(request("q", "a", 1, PendingKind.question, summary = "用哪个数据库"), request("p", "b", 1, PendingKind.plan)),
        )
        assertEquals("问：用哪个数据库", cards["a"]!!.what)
        assertNull(cards["a"]!!.detail)
        assertFalse(cards["a"]!!.inline)
        assertEquals("计划等你批准", cards["b"]!!.what)
        assertFalse(cards["b"]!!.inline)
    }

    @Test
    fun noSnapshotNoCards() {
        assertTrue(cardRequests(null).isEmpty())
    }

    private fun session(id: String, state: PetState = PetState.running) = BridgeSession(
        id = id, name = id, source = SessionSource.terminal, state = state, cwd = "/p/$id",
        skin = "sprig", eventTime = 0, startedAt = 0, tracked = true,
    )

    @Test
    fun cardsAlternateBetweenTheColumns() {
        val (left, right) = proColumns(listOf("a", "b", "c", "d", "e").map { session(it) }, emptyMap())
        assertEquals(listOf("a", "c", "e"), left.map { it.id })
        assertEquals(listOf("b", "d"), right.map { it.id })
    }

    /** A card with a request is two rows tall and always heads the left column; the others fill the shorter column. */
    @Test
    fun requestCardsStackOnTheLeftAndTakeTwoRows() {
        val sessions = listOf(
            session("w1", PetState.waiting), session("a"), session("w2", PetState.waiting),
            session("b"), session("c"), session("d"), session("e"),
        )
        val requests = cardRequests(body(request("r1", "w1", 1), request("r2", "w2", 2)))
        val (left, right) = proColumns(sessions, requests)
        assertEquals(listOf("w1", "w2", "e"), left.map { it.id })
        assertEquals(listOf("a", "b", "c", "d"), right.map { it.id })
    }
}
