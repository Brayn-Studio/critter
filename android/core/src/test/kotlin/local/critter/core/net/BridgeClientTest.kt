package local.critter.core.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import local.critter.core.protocol.BridgeJson
import local.critter.core.protocol.ClientMessage
import local.critter.core.protocol.AnswerPayload
import local.critter.core.protocol.PairingUri
import local.critter.core.protocol.ResultReason
import okhttp3.WebSocket
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import java.util.concurrent.atomic.AtomicInteger

class BridgeClientTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val macs = mutableListOf<FakeMac>()
    private val creds = Credentials("dev-1", "tok-1")

    @AfterTest fun tearDown() {
        scope.cancel()
        macs.forEach { it.shutdown() }
    }

    private fun mac(cert: okhttp3.tls.HeldCertificate = FakeMac.newCert()) = FakeMac(cert).start().also { macs += it }

    private fun type(frame: String) = BridgeJson.parseToJsonElement(frame).jsonObject["type"]?.jsonPrimitive?.content

    /** Replies to a valid hello with welcome + snapshot, like the real Mac. */
    private fun FakeMac.greetOnHello() {
        onFrame = { ws, text -> if (type(text) == "hello") FakeMac.greet(ws) }
    }

    private class CountingEndpoint(private val address: () -> Pair<String, Int>?) : Endpoint {
        val resolves = AtomicInteger()
        override suspend fun resolve(): Pair<String, Int>? {
            resolves.incrementAndGet()
            return address()
        }
    }

    private fun client(
        endpoint: Endpoint,
        fingerprint: String,
        requestTimeoutMs: Long = 10_000,
        pairTimeoutMs: Long = 120_000,
    ) = BridgeClient(
        scope, endpoint, fingerprint, { creds },
        requestTimeoutMs = requestTimeoutMs, pairTimeoutMs = pairTimeoutMs,
    )

    private suspend fun <T> StateFlow<T>.await(p: (T) -> Boolean): T = withTimeout(10_000) { first(p) }

    @Test fun helloThenSnapshotFlows() = runBlocking {
        val mac = mac().apply { greetOnHello(); expectConnection() }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint)
        c.start()

        assertEquals(ConnState.Connected("Test Mac"), c.state.await { it is ConnState.Connected })
        assertNotNull(c.snapshot.await { it != null })

        val hello = BridgeJson.parseToJsonElement(mac.nextFrame()).jsonObject
        assertEquals("hello", hello["type"]?.jsonPrimitive?.content)
        assertEquals("dev-1", hello["deviceId"]?.jsonPrimitive?.content)
        assertEquals("tok-1", hello["token"]?.jsonPrimitive?.content)
        assertEquals("1", hello["protocol"]?.jsonPrimitive?.content)
    }

    @Test fun requestMatchesResultById() = runBlocking {
        val mac = mac().apply { expectConnection() }
        mac.onFrame = { ws, text ->
            when (type(text)) {
                "hello" -> FakeMac.greet(ws)
                "answer" -> {
                    val id = BridgeJson.parseToJsonElement(text).jsonObject["id"]!!.jsonPrimitive.content
                    ws.send("""{"id":"$id","ok":true,"type":"result"}""")
                }
            }
        }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint)
        c.start()
        c.state.await { it is ConnState.Connected }

        val result = c.request(ClientMessage.Answer(null, "req-1", AnswerPayload(decision = "allow")))
        assertTrue(result.ok)
        mac.nextFrame() // hello
        val sentId = BridgeJson.parseToJsonElement(mac.nextFrame()).jsonObject["id"]!!.jsonPrimitive.content
        assertEquals(sentId, result.id)
    }

    @Test fun requestSkinReturnsTheManifestOrNull() = runBlocking {
        val mac = mac().apply { expectConnection() }
        mac.onFrame = { ws, text ->
            when (type(text)) {
                "hello" -> FakeMac.greet(ws)
                "skin" -> {
                    val obj = BridgeJson.parseToJsonElement(text).jsonObject
                    val id = obj["id"]!!.jsonPrimitive.content
                    val name = obj["name"]!!.jsonPrimitive.content
                    val manifest = if (name == "custom") ""","manifest":{"name":"custom"}""" else ""
                    ws.send("""{"id":"$id"$manifest,"name":"$name","type":"skin"}""")
                }
            }
        }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint)
        c.start()
        c.state.await { it is ConnState.Connected }

        val found = c.requestSkin("custom")
        assertEquals("custom", found?.manifest?.get("name")?.jsonPrimitive?.content)
        assertNull(c.requestSkin("nope")?.manifest)
    }

    @Test fun requestTimesOut() = runBlocking {
        val mac = mac().apply { greetOnHello(); expectConnection() }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint, requestTimeoutMs = 300)
        c.start()
        c.state.await { it is ConnState.Connected }

        val result = c.request(ClientMessage.Seen(null, "s1"))
        assertFalse(result.ok)
        assertEquals(ResultReason.unknown, result.reason)
        assertEquals("超时", result.message)
    }

    @Test fun requestWithoutAConnectionFailsFast() = runBlocking {
        val c = client(CountingEndpoint { null }, "00")
        val result = c.request(ClientMessage.Seen(null, "s1"))
        assertFalse(result.ok)
        assertEquals("未连接", result.message)
    }

    @Test fun pinMismatchStopsRetrying() = runBlocking {
        val mac = mac().apply { greetOnHello(); repeat(3) { expectConnection() } }
        val endpoint = CountingEndpoint { mac.address }
        val c = client(endpoint, fingerprint = "0".repeat(64))
        c.start()

        val state = c.state.await { it is ConnState.NeedsRepair }
        assertIs<ConnState.NeedsRepair>(state)
        delay(2_600) // longer than the first backoff step
        assertEquals(1, endpoint.resolves.get(), "must not retry after a pin mismatch")
        assertIs<ConnState.NeedsRepair>(c.state.value)
        assertTrue(mac.received.isEmpty(), "nothing may be sent to an unpinned peer")
    }

    @Test fun badTokenNeedsRepair() = runBlocking {
        val mac = mac().apply { expectConnection(); expectConnection() }
        mac.onFrame = { ws, _ -> ws.send("""{"reason":"badToken","type":"denied"}""") }
        val endpoint = CountingEndpoint { mac.address }
        val c = client(endpoint, mac.fingerprint)
        c.start()

        c.state.await { it is ConnState.NeedsRepair }
        delay(2_600)
        assertEquals(1, endpoint.resolves.get())
        assertIs<ConnState.NeedsRepair>(c.state.value)
    }

    @Test fun dropReconnectsWithBackoff() = runBlocking {
        val mac = mac().apply { greetOnHello(); expectConnection(); expectConnection() }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint)
        c.start()
        c.state.await { it is ConnState.Connected }

        mac.sockets.take().close(1001, "bye")
        val offline = c.state.await { it is ConnState.Offline }
        assertEquals(2_000, (offline as ConnState.Offline).retryInMs)
        c.state.await { it is ConnState.Connected }
        assertEquals(2, mac.received.count { type(it) == "hello" })
    }

    @Test fun clientReconnectsToNewAddressWithSamePin() = runBlocking {
        val cert = FakeMac.newCert()
        val first = mac(cert).apply { greetOnHello(); expectConnection() }
        val second = mac(cert).apply { greetOnHello(); expectConnection() }
        var current = first
        val c = client(CountingEndpoint { current.address }, first.fingerprint)
        c.start()
        c.state.await { it is ConnState.Connected }

        current = second
        first.sockets.take().close(1001, "mac restarted")
        first.shutdown()
        c.state.await { it is ConnState.Offline }
        c.state.await { it is ConnState.Connected }

        assertEquals("hello", type(second.nextFrame()))
    }

    @Test fun pairWaitsForApproval() = runBlocking {
        val mac = mac().apply { expectConnection() }
        mac.onFrame = { ws: WebSocket, text ->
            if (type(text) == "pair") thread {
                Thread.sleep(2_000)
                ws.send("""{"deviceId":"dev-9","macName":"Test Mac","token":"tok-9","type":"paired"}""")
                FakeMac.greet(ws)
            }
        }
        val c = client(CountingEndpoint { null }, "unused")
        val uri = PairingUri(mac.host, mac.port, mac.fingerprint, "K7M2QX9P", "Test Mac")

        val started = System.nanoTime()
        val pairing = async(Dispatchers.Default) { c.pair(uri, "Pixel 9") }
        c.state.await { it is ConnState.AwaitingApproval }
        assertFalse(pairing.isCompleted, "pair() must wait for the user to approve on the Mac")

        val result = withTimeout(10_000) { pairing.await() }
        val paired = assertIs<PairResult.Paired>(result).paired
        assertEquals("tok-9", paired.token)
        assertEquals("dev-9", paired.deviceId)
        assertTrue((System.nanoTime() - started) >= 1_500_000_000L)
        assertEquals(ConnState.Idle, c.state.value)
    }

    private fun FakeMac.uri() = PairingUri(host, port, fingerprint, "K7M2QX9P", "Test Mac")

    /** The Mac answers `pair` with `denied` [reason] and closes, as the protocol doc says. */
    private fun FakeMac.denyPair(reason: String) {
        onFrame = { ws, text ->
            if (type(text) == "pair") {
                ws.send("""{"reason":"$reason","type":"denied"}""")
                ws.close(1000, null)
            }
        }
    }

    @Test fun pairDeniedBadCodeSaysSo() = runBlocking {
        val mac = mac().apply { expectConnection(); denyPair("badCode") }
        val c = client(CountingEndpoint { null }, "unused")
        assertEquals(PairResult.Failed(PairFailure.BadCode), withTimeout(10_000) { c.pair(mac.uri(), "Pixel 9") })
    }

    @Test fun pairDeniedRejectedSaysSo() = runBlocking {
        val mac = mac().apply { expectConnection(); denyPair("rejected") }
        val c = client(CountingEndpoint { null }, "unused")
        assertEquals(PairResult.Failed(PairFailure.Rejected), withTimeout(10_000) { c.pair(mac.uri(), "Pixel 9") })
        assertEquals(ConnState.Idle, c.state.value)
    }

    @Test fun pairTimesOutAsNoAnswer() = runBlocking {
        val mac = mac().apply { expectConnection() } // never answers the pair frame
        val c = client(CountingEndpoint { null }, "unused", pairTimeoutMs = 300)
        assertEquals(PairResult.Failed(PairFailure.NoAnswer), withTimeout(10_000) { c.pair(mac.uri(), "Pixel 9") })
        assertEquals("pair", type(mac.nextFrame()))
    }

    /** Nobody approved within the Mac's 300 s: it closes without `denied`, which is no answer, not a refusal. */
    @Test fun pairPlainCloseIsNoAnswer() = runBlocking {
        val mac = mac().apply { expectConnection() }
        mac.onFrame = { ws, text -> if (type(text) == "pair") ws.close(1000, null) }
        val c = client(CountingEndpoint { null }, "unused")
        assertEquals(PairResult.Failed(PairFailure.NoAnswer), withTimeout(10_000) { c.pair(mac.uri(), "Pixel 9") })
    }

    @Test fun pairWithAnotherCertificateIsCertMismatch() = runBlocking {
        val mac = mac().apply { expectConnection() }
        val c = client(CountingEndpoint { null }, "unused")
        val uri = mac.uri().copy(fingerprint = "0".repeat(64))
        assertEquals(PairResult.Failed(PairFailure.CertMismatch), withTimeout(10_000) { c.pair(uri, "Pixel 9") })
        assertTrue(mac.received.isEmpty(), "nothing may be sent to an unpinned peer")
    }

    @Test fun pairWithNobodyListeningIsUnreachable() = runBlocking {
        val mac = mac()
        val uri = mac.uri()
        mac.shutdown()
        val c = client(CountingEndpoint { null }, "unused")
        assertEquals(PairResult.Failed(PairFailure.Unreachable), withTimeout(10_000) { c.pair(uri, "Pixel 9") })
    }

    /** Opening or closing the board changes the heartbeat for the next connection, without dropping this one. */
    @Test fun pingIntervalChangeKeepsTheConnection() = runBlocking {
        val mac = mac().apply { greetOnHello(); expectConnection(); expectConnection() }
        val endpoint = CountingEndpoint { mac.address }
        val c = client(endpoint, mac.fingerprint)
        c.setPingInterval(180_000)
        c.start()
        c.state.await { it is ConnState.Connected }

        c.setPingInterval(30_000)
        assertEquals(30_000L, c.nextPingIntervalMs)
        c.setPingInterval(180_000)
        delay(500)
        assertIs<ConnState.Connected>(c.state.value)
        assertEquals(1, endpoint.resolves.get(), "a ping interval change must not reconnect")
        assertEquals(180_000L, c.nextPingIntervalMs)
        c.stop()
    }
}
