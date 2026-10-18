package local.critter.core.net

/**
 * Whether a host is on a private / local network: the ranges the Mac serves (docs/critter-bridge-protocol.md;
 * the Swift `PrivateNetwork`), 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, 127/8, ::1, fe80::/10,
 * fc00::/7, and IPv4-mapped IPv6 addresses of the IPv4 ones. A pairing pointing anywhere else is refused: its
 * fingerprint would only pin a certificate the link's author chose.
 *
 * Only literal addresses count (brackets and a `%zone` are allowed); a host name is never looked up.
 */
object PrivateNetwork {
    fun isAllowed(host: String): Boolean {
        var h = host
        if (h.startsWith("[") && h.endsWith("]")) h = h.substring(1, h.length - 1)
        val zone = h.indexOf('%')
        if (zone >= 0) h = h.substring(0, zone)

        parseV4(h)?.let { return allowedV4(it) }
        val b = parseV6(h) ?: return false
        fun u(i: Int) = b[i].toInt() and 0xff
        if ((0 until 15).all { u(it) == 0 } && u(15) == 1) return true // ::1
        if (u(0) == 0xfe && (u(1) and 0xc0) == 0x80) return true // fe80::/10
        if ((u(0) and 0xfe) == 0xfc) return true // fc00::/7
        if ((0 until 10).all { u(it) == 0 } && u(10) == 0xff && u(11) == 0xff) { // ::ffff:a.b.c.d
            return allowedV4((u(12).toLong() shl 24) or (u(13).toLong() shl 16) or (u(14).toLong() shl 8) or u(15).toLong())
        }
        return false
    }

    private fun allowedV4(a: Long): Boolean = when ((a shr 24) and 0xff) {
        10L, 127L -> true
        172L -> (a shr 20) and 0xf == 1L // 172.16/12
        192L -> (a shr 16) and 0xff == 168L
        169L -> (a shr 16) and 0xff == 254L
        100L -> (a shr 16) and 0xc0 == 0x40L // 100.64/10
        else -> false
    }

    /** `a.b.c.d` with decimal parts 0…255 and no leading zeros (as `inet_pton` reads it), or null. */
    private fun parseV4(s: String): Long? {
        val parts = s.split('.')
        if (parts.size != 4) return null
        var a = 0L
        for (p in parts) {
            if (p.isEmpty() || p.length > 3 || !p.all { it in '0'..'9' }) return null
            if (p.length > 1 && p[0] == '0') return null
            val v = p.toInt()
            if (v > 255) return null
            a = (a shl 8) or v.toLong()
        }
        return a
    }

    /** The 16 bytes of an RFC 4291 text address (one `::` at most, a dotted IPv4 tail allowed), or null. */
    private fun parseV6(s: String): ByteArray? {
        if (s.count { it == ':' } < 2) return null
        val gap = s.indexOf("::")
        if (gap >= 0 && s.indexOf("::", gap + 1) >= 0) return null
        val head = words(if (gap >= 0) s.substring(0, gap) else s, last = gap < 0) ?: return null
        val tail = if (gap >= 0) words(s.substring(gap + 2), last = true) ?: return null else emptyList()
        val total = head.size + tail.size
        if (if (gap >= 0) total > 7 else total != 8) return null
        val all = head + List(8 - total) { 0 } + tail
        val bytes = ByteArray(16)
        all.forEachIndexed { i, w ->
            bytes[2 * i] = (w shr 8).toByte()
            bytes[2 * i + 1] = w.toByte()
        }
        return bytes
    }

    /** The 16-bit words of the colon-separated [part]; when it is the [last] part it may end in a dotted IPv4. */
    private fun words(part: String, last: Boolean): List<Int>? {
        if (part.isEmpty()) return emptyList()
        val groups = part.split(':')
        val out = ArrayList<Int>(8)
        for ((i, g) in groups.withIndex()) {
            if (last && i == groups.lastIndex && '.' in g) {
                val v4 = parseV4(g) ?: return null
                out += ((v4 shr 16) and 0xffff).toInt()
                out += (v4 and 0xffff).toInt()
            } else {
                if (g.isEmpty() || g.length > 4 || !g.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
                out += g.toInt(16)
            }
        }
        return out
    }
}
