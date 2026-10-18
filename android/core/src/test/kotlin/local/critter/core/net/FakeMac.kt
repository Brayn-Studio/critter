package local.critter.core.net

import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import local.critter.core.protocol.sha256Hex
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** A stand-in for the Mac: a TLS WebSocket server with a self-signed certificate. */
class FakeMac(val cert: HeldCertificate = newCert()) {
    private val server = MockWebServer()

    /** Every text frame the phone sent, in order. */
    val received = LinkedBlockingQueue<String>()

    /** Server-side ends of the accepted sockets, so a test can drop one. */
    val sockets = LinkedBlockingQueue<WebSocket>()

    /** What the Mac does with a frame; the default does nothing. */
    var onFrame: (WebSocket, String) -> Unit = { _, _ -> }

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
            override fun onOpen(webSocket: WebSocket, response: Response) {
                sockets.add(webSocket)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                received.add(text)
                onFrame(webSocket, text)
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
