package local.critter.core.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PairingUriTest {
    private val fp = "ab12".repeat(16)

    @Test fun pairingUriRoundTrip() {
        for (host in listOf("192.168.1.5", "fe80::1")) {
            val uri = PairingUri(host, 47823, fp, "ABCD2345", "小明的 MacBook & 家")
            assertEquals(uri, PairingUri.parse(uri.toString()))
        }
        val v6 = PairingUri("fe80::1", 1, fp, "A", "n")
        assertTrue(v6.toString().startsWith("critter-pair://[fe80::1]:1?"))
    }

    @Test fun parsesTheDocumentedExample() {
        val uri = PairingUri.parse(
            "critter-pair://192.168.1.20:47823?fp=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef&code=K7M2QX9P&name=Xuan%27s%20MacBook",
        )
        assertNotNull(uri)
        assertEquals("192.168.1.20", uri.host)
        assertEquals(47823, uri.port)
        assertEquals("K7M2QX9P", uri.code)
        assertEquals("Xuan's MacBook", uri.name)
    }

    @Test fun pairingUriRejectsGarbage() {
        assertNull(PairingUri.parse("http://x"))
        assertNull(PairingUri.parse("critter-pair://1.2.3.4:5?fp=zz&code=A&name=n"))
        assertNull(PairingUri.parse("critter-pair://1.2.3.4:5?code=A&name=n"))
        assertNull(PairingUri.parse("critter-pair://1.2.3.4:abc?fp=$fp&code=A&name=n"))
        assertNull(PairingUri.parse("critter-pair://1.2.3.4:70000?fp=$fp&code=A&name=n"))
        assertNull(PairingUri.parse("critter-pair://1.2.3.4:5?fp=${fp.uppercase()}&code=A&name=n"))
        assertNull(PairingUri.parse("critter-pair://1.2.3.4:5?fp=$fp&code=&name=n"))
        assertNull(PairingUri.parse("critter-pair://1.2.3.4:5?fp=$fp&code=A"))
        assertNull(PairingUri.parse("critter-pair://1.2.3.4?fp=$fp&code=A&name=n"))
        assertNull(PairingUri.parse(""))
    }

    /** The same text as the Mac's sheet shows (Swift `pairingFingerprintPrefixIsFourGroupsOfFour`). */
    @Test fun fingerprintPrefixIsFourGroupsOfFour() {
        assertEquals("0123 4567 89ab cdef", PairingUri.fingerprintPrefix("0123456789abcdef" + "0".repeat(48)))
        assertEquals("ab12 ab12 ab12 ab12", PairingUri.fingerprintPrefix("ab12".repeat(16)))
    }
}
