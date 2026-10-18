package local.critter.phone.bridge

import android.annotation.SuppressLint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import local.critter.core.protocol.sha256Hex
import java.net.InetSocketAddress
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/**
 * Reads the certificate fingerprint a Mac presents, for the manual pairing path (spec §6.5): the user is
 * shown it and confirms before it is pinned. It only reads the certificate and sends nothing.
 */
object CertProbe {
    @SuppressLint("CustomX509TrustManager", "TrustAllX509TrustManager")
    suspend fun fingerprint(host: String, port: Int): String? = withContext(Dispatchers.IO) {
        var seen: ByteArray? = null
        val reader = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                seen = chain?.firstOrNull()?.encoded
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        try {
            val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(reader), null) }
            (context.socketFactory.createSocket() as SSLSocket).use { socket ->
                socket.soTimeout = 3_000
                socket.connect(InetSocketAddress(host, port), 3_000)
                socket.startHandshake()
            }
        } catch (_: Exception) {
            // Whatever was seen before the failure still counts; usually that is nothing.
        }
        seen?.let(::sha256Hex)
    }
}
