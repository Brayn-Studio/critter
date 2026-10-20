package local.critter.core.net

import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.QueueDispatcher
import mockwebserver3.RecordedRequest
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import local.critter.core.protocol.sha256Hex
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** A stand-in for the Mac: a TLS WebSocket server with a self-signed certificate. */
class FakeMac(val cert: HeldCertificate = newCert()) {
    private val server = MockWebServer()

    /** Every text frame the phone sent, in order. */
    val received = LinkedBlockingQueue<String>()

    /** Server-side ends of the accepted sockets, so a test can drop one. */
    val sockets = LinkedBlockingQueue<WebSocket>()

    /** What the Mac does with a frame; the default does nothing. */
    var onFrame: (WebSocket, String) -> Unit = { _, _ -> }

    /** How many WebSockets were accepted. */
    val opened = AtomicInteger()

    /**
     * With [oneAtATime], a connection is only accepted once the one before it has ended on this side; one that is
     * still open [overlapWaitMs] after the next asks (the phone kept two) sets [overlapped]. No timing is sampled: a
     * correct phone closes the old socket before it opens a new one, so the wait always ends.
     */
    @Volatile var oneAtATime = false
    @Volatile var overlapWaitMs = 5_000L
    val overlapped = AtomicBoolean()
    private val turn = Semaphore(1)

    /** While set, an upgrade is answered only once this opens: the phone stays mid-handshake until then. */
    @Volatile var holdUpgrades: CountDownLatch? = null

    /** How many upgrade requests reached the Mac, answered or still held. */
    val upgradesAsked = AtomicInteger()

    init {
        server.dispatcher = object : QueueDispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (oneAtATime && !turn.tryAcquire(overlapWaitMs, TimeUnit.MILLISECONDS)) overlapped.set(true)
                upgradesAsked.incrementAndGet()
                holdUpgrades?.await(10, TimeUnit.SECONDS)
                return super.dispatch(request)
            }
        }
    }

    val fingerprint: String = sha256Hex(cert.certificate.encoded)
    val host: String get() = server.hostName
    val port: Int get() = server.port
    val address: Pair<String, Int> get() = host to port

    fun start(): FakeMac {
        val tls = HandshakeCertificates.Builder().heldCertificate(cert).build()
        server.useHttps(tls.sslSocketFactory())
        server.start()
        return this
    }

    /** Accept one more WebSocket upgrade. */
    fun expectConnection() {
        server.enqueue(MockResponse.Builder().webSocketUpgrade(object : WebSocketListener() {
            private val gone = AtomicBoolean()

            override fun onOpen(webSocket: WebSocket, response: Response) {
                opened.incrementAndGet()
                sockets.add(webSocket)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                received.add(text)
                onFrame(webSocket, text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = ended()

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = ended()

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = ended()

            private fun ended() {
                if (gone.compareAndSet(false, true) && oneAtATime) turn.release()
            }
        }).build())
    }

    fun nextFrame(timeoutMs: Long = 10_000): String =
        checkNotNull(received.poll(timeoutMs, TimeUnit.MILLISECONDS)) { "the Mac received nothing" }

    fun shutdown() {
        runCatching { server.close() }
    }

    companion object {
        fun newCert(): HeldCertificate =
            HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()

        /** Welcome, then the documented snapshot: what the Mac sends after a valid hello. */
        fun greet(ws: WebSocket) {
            ws.send("""{"macName":"Test Mac","type":"welcome","version":"1.4.0"}""")
            ws.send(
                """{"type":"snapshot","seq":1,"sentAt":1,"sessions":[],"pending":[],"prefs":{"skin":"clawd","randomSkins":false,"idleDim":1,"mergeThreshold":4}}""",
            )
        }
    }
}
