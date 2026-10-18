package local.critter.core.net

import local.critter.core.protocol.sha256Hex
import okhttp3.OkHttpClient
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/** The server's certificate is not the one that was pinned when pairing. */
class PinMismatchException(val expected: String, val actual: String) :
    CertificateException("certificate fingerprint $actual does not match the pinned $expected")

/**
 * Trust exactly one certificate: the Mac's self-signed one, identified by the SHA-256 of its DER
 * encoding. No CA chain is validated, and host names are not checked because the pin already
 * fixes the peer's identity (the Mac's address changes whenever its network does).
 */
object PinnedTls {
    fun client(fingerprint: String, base: OkHttpClient = OkHttpClient()): OkHttpClient {
        val trust = PinnedTrustManager(fingerprint.lowercase())
        val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
        return base.newBuilder()
            .sslSocketFactory(context.socketFactory, trust)
            .hostnameVerifier { _, _ -> true }
            .build()
    }

    private class PinnedTrustManager(private val fingerprint: String) : X509TrustManager {
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            val leaf = chain?.firstOrNull() ?: throw CertificateException("empty certificate chain")
            val actual = sha256Hex(leaf.encoded)
            if (actual != fingerprint) throw PinMismatchException(fingerprint, actual)
        }

        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
            throw CertificateException("client certificates are not accepted")

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
}
