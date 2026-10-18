package local.critter.core.protocol

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MessagesTest {
    private fun resource(name: String): String =
        checkNotNull(javaClass.getResourceAsStream("/protocol/$name")) { "missing $name" }
            .readBytes().decodeToString().trim()

    private fun json(name: String): JsonElement = BridgeJson.parseToJsonElement(resource(name))

    private fun assertEncodes(expected: String, msg: ClientMessage) =
        assertEquals(json(expected), BridgeJson.parseToJsonElement(encode(msg)), expected)

    @Test fun decodesEveryDocumentedServerExample() {
        val welcome = assertIs<ServerMessage.Welcome>(decodeServer(resource("server-welcome.json")))
        assertEquals("Xuan's MacBook", welcome.macName)
        assertEquals("1.4.0", welcome.version)

        val paired = assertIs<ServerMessage.Paired>(decodeServer(resource("server-paired.json")))
        assertEquals("6F1C2A4E-8B7D-4C3A-9E2F-1A5B7C9D0E11", paired.deviceId)
        assertEquals("dG9rZW4tZXhhbXBsZS1iYXNlNjR1cmw", paired.token)

        val denied = assertIs<ServerMessage.Denied>(decodeServer(resource("server-denied.json")))
        assertEquals(DenyReason.badToken, denied.reason)

        val skin = assertIs<ServerMessage.Skin>(decodeServer(resource("server-skin.json")))
        assertEquals("c7", skin.id)
        assertEquals("clawd", skin.name)
        assertEquals("clawd", skin.manifest?.get("name")?.jsonPrimitive?.content)

        val ok = assertIs<ServerMessage.Result>(decodeServer(resource("server-result-ok.json")))
        assertTrue(ok.ok)
        assertNull(ok.reason)
        assertNull(ok.message)

        val failed = assertIs<ServerMessage.Result>(decodeServer(resource("server-result-failed.json")))
        assertEquals("c1", failed.id)
        assertEquals(ResultReason.resolved, failed.reason)
        assertEquals("已在电脑上处理", failed.message)
    }

    @Test fun decodesTheDocumentedSnapshot() {
        val snap = assertIs<ServerMessage.Snapshot>(decodeServer(resource("server-snapshot.json")))
        assertEquals(7, snap.seq)
        assertEquals(1760000000000, snap.sentAt)

        val s = snap.body.sessions.single()
        assertEquals("s1", s.id)
        assertEquals(SessionSource.terminal, s.source)
        assertEquals(PetState.waiting, s.state)
        assertEquals("Bash: swift test", s.detail)
        assertEquals("bash", s.activity)
        assertEquals("main", s.branch)
        assertEquals("Opus 5.5", s.model)
        assertEquals(42.5, s.context?.usedPercent)
        assertEquals(1_000_000L, s.context?.windowSize)
        assertEquals(false, s.context?.estimated)
        assertEquals(1759990000000, s.startedAt)
        assertTrue(s.tracked)

        val limits = snap.body.limits
        assertEquals(12.5, limits?.fiveHour?.usedPercentage)
        assertEquals(1760500000000, limits?.sevenDay?.resetsAt)
        assertEquals(1760000000000, limits?.updatedAt)

        val p = snap.body.pending.single()
        assertEquals("r1", p.requestId)
        assertEquals(PendingKind.permission, p.kind)
        assertEquals("Bash", p.toolName)
        assertEquals("swift test", p.input?.get("command")?.jsonPrimitive?.content)
        assertEquals(1760000600000, p.expiresAt)

        assertEquals(0.6, snap.body.prefs.idleDim)
        assertEquals(5, snap.body.prefs.mergeThreshold)
        assertEquals(SoundTheme.pixel, snap.body.prefs.soundTheme)
    }

    @Test fun optionalSnapshotFieldsMayBeAbsent() {
        val s = """{"type":"snapshot","seq":1,"sentAt":2,"sessions":[{"id":"a","name":"n","source":"vscode","state":"idle","cwd":"~","skin":"clawd","eventTime":1,"startedAt":1,"tracked":false}],"pending":[],"prefs":{"skin":"clawd","randomSkins":true,"idleDim":1,"mergeThreshold":4}}"""
        val snap = assertIs<ServerMessage.Snapshot>(decodeServer(s))
        assertNull(snap.body.limits)
        assertNull(snap.body.sessions[0].context)
        assertNull(snap.body.sessions[0].detail)
        assertNull(snap.body.prefs.soundTheme)
    }

    @Test fun encodesClientMessagesToDocumentedShape() {
        assertEncodes(
            "client-hello.json",
            ClientMessage.Hello("critter-android/1.0", "6F1C2A4E-8B7D-4C3A-9E2F-1A5B7C9D0E11", "dG9rZW4tZXhhbXBsZS1iYXNlNjR1cmw"),
        )
        assertEncodes("client-pair.json", ClientMessage.Pair("K7M2QX9P", "Pixel 9"))
        assertEncodes("client-answer-allow.json", ClientMessage.Answer("c1", "req-1", AnswerPayload(decision = "allow")))
        assertEncodes("client-answer-deny.json", ClientMessage.Answer("c2", "req-2", AnswerPayload(decision = "deny", message = "Not now")))
        assertEncodes(
            "client-answer-question.json",
            ClientMessage.Answer("c3", "req-3", AnswerPayload(answers = mapOf("Which database?" to "PostgreSQL"))),
        )
        assertEncodes("client-answer-revise.json", ClientMessage.Answer("c4", "req-4", AnswerPayload(decision = "revise", message = "Split step 2")))
        assertEncodes("client-seen.json", ClientMessage.Seen("c5", "s1"))
        assertEncodes("client-say.json", ClientMessage.Say("c6", "s1", "continue"))
        assertEncodes("client-skin.json", ClientMessage.SkinRequest("c7", "clawd"))
    }

    @Test fun commandsOmitTheIdWhenAbsentAndCanBeGivenOne() {
        val seen = ClientMessage.Seen(null, "s1")
        val obj = BridgeJson.parseToJsonElement(encode(seen)) as JsonObject
        assertTrue("id" !in obj)
        val withId = BridgeJson.parseToJsonElement(encode(seen.withId("x"))) as JsonObject
        assertEquals("x", withId["id"]?.jsonPrimitive?.content)
    }

    @Test fun decodeToleratesUnknownFieldsAndEnums() {
        val s = """{"type":"snapshot","seq":1,"sentAt":1,"future":true,"sessions":[{"id":"a","name":"n","source":"jetbrains","state":"sleeping","cwd":"~","skin":"clawd","eventTime":1,"startedAt":1,"tracked":true,"newField":[1]}],"pending":[{"requestId":"r","sessionId":"a","kind":"telepathy","createdAt":1}],"prefs":{"skin":"clawd","randomSkins":false,"idleDim":1.0,"mergeThreshold":4,"soundTheme":"theremin"}}"""
        val snap = assertIs<ServerMessage.Snapshot>(decodeServer(s))
        assertEquals(SessionSource.other, snap.body.sessions[0].source)
        assertEquals(PetState.unknown, snap.body.sessions[0].state)
        assertEquals(PendingKind.unknown, snap.body.pending[0].kind)
        assertEquals(SoundTheme.unknown, snap.body.prefs.soundTheme)

        val denied = assertIs<ServerMessage.Denied>(decodeServer("""{"type":"denied","reason":"futureReason"}"""))
        assertEquals(DenyReason.unknown, denied.reason)
        val result = assertIs<ServerMessage.Result>(decodeServer("""{"type":"result","ok":false,"reason":"weird"}"""))
        assertEquals(ResultReason.unknown, result.reason)
    }

    @Test fun unknownMessageTypeDecodesToNull() {
        assertNull(decodeServer("""{"type":"teleport"}"""))
        assertNull(decodeServer("""{"no":"type"}"""))
        assertNull(decodeServer("not json"))
        assertNull(decodeServer("[]"))
    }

    @Test fun sha256HexIsLowercaseHex() {
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sha256Hex(ByteArray(0)))
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256Hex("abc".toByteArray()))
    }
}
