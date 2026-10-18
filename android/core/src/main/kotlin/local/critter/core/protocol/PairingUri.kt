package local.critter.core.protocol

import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest

/**
 * `critter-pair://<host>:<port>?fp=<64 lowercase hex>&code=<code>&name=<name>`, with IPv6 hosts
 * bracketed and every query value percent-encoded as UTF-8 (docs/critter-bridge-protocol.md).
 */
data class PairingUri(
    val host: String,
    val port: Int,
    val fingerprint: String,
    val code: String,
    val name: String,
) {
    override fun toString(): String {
        val h = if (':' in host) "[$host]" else host
        return "$SCHEME://$h:$port?fp=${escape(fingerprint)}&code=${escape(code)}&name=${escape(name)}"
    }

    companion object {
        const val SCHEME = "critter-pair"
        private val FINGERPRINT = Regex("[0-9a-f]{64}")

        /**
         * The first 16 hex characters of a fingerprint in groups of four, `"0123 4567 89ab cdef"`: the Mac's
         * "添加手机" sheet shows exactly this (Swift `PairingURI.fingerprintPrefix`), and the phone asks the user
         * to compare it before trusting a certificate it found on its own.
         */
        fun fingerprintPrefix(fingerprint: String): String = fingerprint.take(16).chunked(4).joinToString(" ")

        // URLEncoder is form-encoding: it turns a space into '+' and leaves '*' alone. Fix both up.
        private fun escape(s: String) =
            URLEncoder.encode(s, "UTF-8").replace("+", "%20").replace("*", "%2A")

        fun parse(s: String): PairingUri? {
            val prefix = "$SCHEME://"
            if (!s.startsWith(prefix)) return null
            val rest = s.removePrefix(prefix)
            val queryAt = rest.indexOf('?')
            if (queryAt < 0) return null
            val authority = rest.substring(0, queryAt)
            val query = rest.substring(queryAt + 1)

            val host: String
            val portText: String
            if (authority.startsWith("[")) {
                val close = authority.indexOf(']')
                if (close < 0 || authority.getOrNull(close + 1) != ':') return null
                host = authority.substring(1, close)
                portText = authority.substring(close + 2)
            } else {
                val colon = authority.lastIndexOf(':')
                if (colon < 0) return null
                host = authority.substring(0, colon)
                portText = authority.substring(colon + 1)
            }
            if (host.isEmpty() || portText.isEmpty() || !portText.all { it in '0'..'9' }) return null
            val port = portText.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null

            val items = try {
                query.split('&').filter { it.isNotEmpty() }.associate {
                    val eq = it.indexOf('=')
                    if (eq < 0) return null
                    URLDecoder.decode(it.substring(0, eq).replace("+", "%2B"), "UTF-8") to
                        URLDecoder.decode(it.substring(eq + 1).replace("+", "%2B"), "UTF-8")
                }
            } catch (_: IllegalArgumentException) {
                return null
            }
            val fp = items["fp"]?.takeIf { FINGERPRINT.matches(it) } ?: return null
            val code = items["code"]?.takeIf { it.isNotEmpty() } ?: return null
            val name = items["name"] ?: return null
            return PairingUri(host, port, fp, code, name)
        }
    }
}

/** SHA-256 of a certificate's DER bytes as 64 lowercase hex characters: the pinning fingerprint. */
fun sha256Hex(der: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02x".format(it) }
