package local.critter.core.net

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import local.critter.core.protocol.BridgeJson
import local.critter.core.protocol.ClientMessage
import local.critter.core.protocol.AnswerPayload
import local.critter.core.protocol.PairingUri
import local.critter.core.protocol.ResultReason
import okhttp3.HttpUrl
import okhttp3.Request
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

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
        backoff: ReconnectBackoff = ReconnectBackoff(),
        clock: () -> Long = System::currentTimeMillis,
    ) = BridgeClient(
        scope, endpoint, fingerprint, { creds }, clock = clock,
        requestTimeoutMs = requestTimeoutMs, pairTimeoutMs = pairTimeoutMs, backoff = backoff,
    )

    /** Answers `hello` like the real Mac, and every command right away with an ok `result`. */
    private fun FakeMac.answerEverything() {
        onFrame = { ws, text ->
            val obj = BridgeJson.parseToJsonElement(text).jsonObject
            when (obj["type"]?.jsonPrimitive?.content) {
                "hello" -> FakeMac.greet(ws)
                else -> ws.send("""{"id":"${obj["id"]!!.jsonPrimitive.content}","ok":true,"type":"result"}""")
            }
        }
    }

    /** Polls [condition] (test side only) until it holds or [timeoutMs] passes. */
    private suspend fun eventually(timeoutMs: Long = 10_000, condition: () -> Boolean): Boolean =
        withTimeoutOrNull(timeoutMs) {
            while (!condition()) delay(20)
            true
        } ?: false

    private fun answer(id: String) = ClientMessage.Answer(null, id, AnswerPayload(decision = "allow"))

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

    // --- start, stop, reconnect -----------------------------------------------------------------

    /** The stopped run's cleanup must not take the new run's socket (or its requests) with it. */
    @Test fun stopThenStartKeepsTheNewSocket() = runBlocking {
        val mac = mac().apply { answerEverything(); repeat(4) { expectConnection() } }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint)
        c.start()
        c.state.await { it is ConnState.Connected }

        repeat(3) { round ->
            c.stop()
            c.start()
            c.state.await { it is ConnState.Connected }
            val result = c.request(answer("req-$round"))
            assertTrue(result.ok, "round $round: ${result.message}")
        }
    }

    /** Stopped while it was still finding the Mac: the stale run must not open or clear anything once it gets there. */
    @Test fun stopWhileResolvingKeepsTheNewSocket() = runBlocking {
        val mac = mac().apply { answerEverything(); repeat(3) { expectConnection() } }
        val slowFirst = AtomicInteger()
        val endpoint = object : Endpoint {
            override suspend fun resolve(): Pair<String, Int> {
                // Not cancellable, like a blocking reachability probe.
                if (slowFirst.getAndIncrement() == 0) Thread.sleep(600)
                return mac.address
            }
        }
        val c = client(endpoint, mac.fingerprint)
        c.start()
        c.state.await { it is ConnState.Connecting }
        delay(100)
        c.stop()
        c.start()
        c.state.await { it is ConnState.Connected }

        delay(900) // the first run's resolve is long over
        assertIs<ConnState.Connected>(c.state.value)
        assertTrue(c.request(answer("req-1")).ok)
        assertEquals(1, mac.opened.get(), "the stopped run must not connect")
    }

    @Test fun stopResetsOfflineSinceAndBackoff() = runBlocking {
        val now = AtomicLong(1_000)
        val c = client(CountingEndpoint { null }, "00", backoff = ReconnectBackoff(initialMs = 500), clock = now::get)
        c.start()
        assertEquals(ConnState.Offline(500, 1_000), c.state.await { it is ConnState.Offline })
        assertEquals(ConnState.Offline(1_000, 1_000), c.state.await { it is ConnState.Offline && it.retryInMs == 1_000L })

        now.set(5_000)
        c.stop()
        c.start()
        assertEquals(ConnState.Offline(500, 5_000), c.state.await { it is ConnState.Offline })
    }

    /** A reconnect asked for while a connection is being made is moot: it must not cut the next backoff short. */
    @Test fun reconnectNowWhileConnectingLeavesNoWake() = runBlocking {
        val answers = Channel<Pair<String, Int>?>(Channel.UNLIMITED)
        val resolves = AtomicInteger()
        val endpoint = object : Endpoint {
            override suspend fun resolve(): Pair<String, Int>? {
                resolves.incrementAndGet()
                return answers.receive()
            }
        }
        val c = client(endpoint, "00")
        c.start()
        assertTrue(eventually { resolves.get() == 1 })
        assertIs<ConnState.Connecting>(c.state.value)

        c.reconnectNow()
        answers.send(null) // nobody there
        assertEquals(2_000, (c.state.await { it is ConnState.Offline } as ConnState.Offline).retryInMs)
        delay(1_000)
        assertEquals(1, resolves.get(), "the backoff must not be skipped")
    }

    @Test fun reconnectNowSkipsTheBackoff() = runBlocking {
        val endpoint = CountingEndpoint { null }
        val c = client(endpoint, "00")
        c.start()
        assertEquals(2_000, (c.state.await { it is ConnState.Offline } as ConnState.Offline).retryInMs)
        assertEquals(1, endpoint.resolves.get())

        c.reconnectNow()
        assertTrue(eventually(timeoutMs = 200) { endpoint.resolves.get() == 2 }, "a new attempt right away")
    }

    /**
     * Network callbacks, sheets and the service may all ask within the same moment: still one socket at a time. The
     * Mac accepts a connection only after the one before it has closed, so two at once would show as an overlap.
     */
    @Test fun rapidReconnectsKeepOneSocket() = runBlocking {
        val mac = mac().apply { oneAtATime = true; answerEverything(); repeat(6) { expectConnection() } }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint)
        c.start()
        c.state.await { it is ConnState.Connected }

        repeat(3) {
            c.reconnectNow()
            delay(40)
        }
        c.state.await { it is ConnState.Connected }
        delay(1_000)
        assertIs<ConnState.Connected>(c.state.value)
        assertTrue(c.request(answer("req-1")).ok)
        assertFalse(mac.overlapped.get(), "a new connection while the old one was still open")
        assertTrue(mac.opened.get() in 2..4, "one reconnect per call at most, got ${mac.opened.get()}")
    }

    /** The check above has teeth: two sockets kept open together are caught. */
    @Test fun fakeMacCatchesTwoSocketsAtOnce() = runBlocking {
        val mac = mac().apply { oneAtATime = true; overlapWaitMs = 300; expectConnection(); expectConnection() }
        val http = PinnedTls.client(mac.fingerprint)
        val url = HttpUrl.Builder().scheme("https").host(mac.host).port(mac.port).build()
        val quiet = object : WebSocketListener() {}
        val first = http.newWebSocket(Request.Builder().url(url).build(), quiet)
        assertTrue(eventually { mac.opened.get() == 1 })
        assertFalse(mac.overlapped.get())
        val second = http.newWebSocket(Request.Builder().url(url).build(), quiet)
        assertTrue(eventually { mac.opened.get() == 2 })
        assertTrue(mac.overlapped.get())
        first.cancel()
        second.cancel()
    }

    @Test fun closedClientDoesNotStartAgain() = runBlocking {
        val endpoint = CountingEndpoint { null }
        val c = client(endpoint, "00")
        c.start()
        c.state.await { it is ConnState.Offline }
        c.close()
        assertEquals(ConnState.Idle, c.state.value)

        c.start()
        delay(300)
        assertEquals(ConnState.Idle, c.state.value)
        assertEquals(1, endpoint.resolves.get())
    }

    // --- requests ---------------------------------------------------------------------------------

    /** The Mac answers within milliseconds: no reply in time means the connection is broken, so it is dropped. */
    @Test fun timeoutDropsTheLink() = runBlocking {
        val mac = mac().apply { greetOnHello(); expectConnection(); expectConnection() } // swallows every command
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint, requestTimeoutMs = 300)
        c.start()
        c.state.await { it is ConnState.Connected }

        val result = c.request(answer("req-1"))
        assertFalse(result.ok)
        assertEquals(ResultReason.unknown, result.reason)
        assertEquals("超时", result.message)
        c.state.await { it !is ConnState.Connected }
        c.state.await { it is ConnState.Connected }
        assertEquals(2, mac.opened.get())
    }

    /**
     * A command issued while the connection is still being made (a 做完了 session tapped, a skin asked for) must not
     * go out ahead of `hello`: the Mac refuses any other first frame with `denied(protocol)`, which would leave the
     * phone asking to update Critter until it restarts. Until the Mac's `welcome` the client is not connected, so
     * such a command gets "未连接" (a skin, null) at once, as at any other time the connection is down.
     */
    @Test fun commandsDuringTheHandshakeDoNotPrecedeHello() = runBlocking {
        val release = CountDownLatch(1)
        val mac = mac().apply { holdUpgrades = release; expectConnection() }
        val greeted = AtomicBoolean()
        mac.onFrame = { ws, text ->
            val obj = BridgeJson.parseToJsonElement(text).jsonObject
            when {
                // Like the Mac's BridgeConnection.receiveFirst: a first frame that is not `hello` is refused.
                !greeted.get() && type(text) != "hello" -> {
                    ws.send("""{"reason":"protocol","type":"denied"}""")
                    ws.close(1000, null)
                }
                type(text) == "hello" -> {
                    greeted.set(true)
                    FakeMac.greet(ws)
                }
                type(text) == "skin" ->
                    ws.send("""{"id":"${obj["id"]!!.jsonPrimitive.content}","name":"custom","type":"skin"}""")
                else -> ws.send("""{"id":"${obj["id"]!!.jsonPrimitive.content}","ok":true,"type":"result"}""")
            }
        }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint)
        c.start()
        assertTrue(eventually { mac.upgradesAsked.get() == 1 }, "the phone asks to upgrade")
        delay(100) // the socket exists; the upgrade is held, so the handshake is not done
        assertIs<ConnState.Connecting>(c.state.value)

        val seen = async(Dispatchers.Default) { c.request(ClientMessage.Seen(null, "s1")) }
        val skin = async(Dispatchers.Default) { c.requestSkin("custom") }
        delay(200) // both have been sent, or turned away, while the handshake is in flight
        release.countDown()

        val settled = c.state.await { it is ConnState.Connected || it is ConnState.NeedsRepair }
        assertEquals("hello", type(mac.nextFrame()), "the first frame on the wire (the client ended $settled)")
        assertIs<ConnState.Connected>(settled)
        assertEquals("未连接", withTimeout(5_000) { seen.await() }.message)
        assertNull(withTimeout(5_000) { skin.await() })

        delay(300)
        assertIs<ConnState.Connected>(c.state.value)
        assertTrue(c.request(ClientMessage.Seen(null, "s1")).ok, "commands go out once connected")
        assertEquals(1, mac.opened.get())
    }

    /** A `skin` reply settles the request that asked for it, whichever way it was asked. */
    @Test fun skinReplySettlesTheRequest() = runBlocking {
        val mac = mac().apply { expectConnection() }
        mac.onFrame = { ws, text ->
            when (type(text)) {
                "hello" -> FakeMac.greet(ws)
                "skin" -> {
                    val obj = BridgeJson.parseToJsonElement(text).jsonObject
                    val id = obj["id"]!!.jsonPrimitive.content
                    val name = obj["name"]!!.jsonPrimitive.content
                    // No such skin: the reply leaves `manifest` out.
                    val manifest = if (name == "custom") ""","manifest":{"name":"custom"}""" else ""
                    ws.send("""{"id":"$id"$manifest,"name":"$name","type":"skin"}""")
                }
            }
        }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint, requestTimeoutMs = 5_000)
        c.start()
        c.state.await { it is ConnState.Connected }

        val started = System.nanoTime()
        assertEquals("custom", c.requestSkin("custom")?.manifest?.get("name")?.jsonPrimitive?.content)
        assertNull(c.requestSkin("nope"))
        assertTrue(c.request(ClientMessage.SkinRequest(null, "custom")).ok)
        assertTrue(System.nanoTime() - started < 2_000_000_000L, "settled by the replies, not by the timeout")
    }

    // --- heartbeat --------------------------------------------------------------------------------

    /** The board's 30 s heartbeat applies now: OkHttp fixes a socket's ping interval, so the link is renewed. */
    @Test fun shorterPingReconnects() = runBlocking {
        val mac = mac().apply { greetOnHello(); expectConnection(); expectConnection() }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint)
        c.start()
        c.state.await { it is ConnState.Connected }
        c.setPingInterval(180_000)
        delay(300)
        assertEquals(1, mac.opened.get(), "a longer interval waits for the next connection")

        c.setPingInterval(30_000)
        assertEquals(30_000L, c.nextPingIntervalMs)
        assertTrue(eventually { mac.received.count { type(it) == "hello" } == 2 }, "a second connection")
        c.state.await { it is ConnState.Connected }
        assertEquals(2, mac.opened.get())
    }

    @Test fun longerPingWaitsForTheNextConnection() = runBlocking {
        val mac = mac().apply { greetOnHello(); expectConnection(); expectConnection() }
        val endpoint = CountingEndpoint { mac.address }
        val c = client(endpoint, mac.fingerprint)
        c.setPingInterval(30_000)
        c.start()
        c.state.await { it is ConnState.Connected }

        c.setPingInterval(180_000)
        delay(500)
        assertIs<ConnState.Connected>(c.state.value)
        assertEquals(1, endpoint.resolves.get(), "a longer ping interval must not reconnect")
        assertEquals(180_000L, c.nextPingIntervalMs)
    }

    /** Renewing the link for the heartbeat must not fail an answer that is waiting for its reply. */
    @Test fun shorterPingWaitsForInFlightRequests() = runBlocking {
        val events = ConcurrentLinkedQueue<String>()
        val answerSeen = CompletableDeferred<Unit>()
        val mac = mac().apply { expectConnection(); expectConnection() }
        mac.onFrame = { ws, text ->
            when (type(text)) {
                "hello" -> {
                    events += "hello"
                    FakeMac.greet(ws)
                }
                "answer" -> thread {
                    answerSeen.complete(Unit)
                    Thread.sleep(600)
                    val id = BridgeJson.parseToJsonElement(text).jsonObject["id"]!!.jsonPrimitive.content
                    events += "result"
                    ws.send("""{"id":"$id","ok":true,"type":"result"}""")
                }
            }
        }
        val c = client(CountingEndpoint { mac.address }, mac.fingerprint)
        c.setPingInterval(180_000)
        c.start()
        c.state.await { it is ConnState.Connected }

        val reply = async(Dispatchers.Default) { c.request(answer("req-1")) }
        withTimeout(5_000) { answerSeen.await() }
        c.setPingInterval(30_000)
        assertTrue(reply.await().ok)
        assertTrue(eventually { events.count { it == "hello" } == 2 }, "renewed once the reply is in")
        assertEquals(listOf("hello", "result", "hello"), events.toList())
    }
}
