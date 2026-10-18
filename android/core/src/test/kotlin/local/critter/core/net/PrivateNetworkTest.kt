package local.critter.core.net

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The same table as the Mac's `privateNetworkTable` (Tests/CritterCoreTests/PrivateNetworkTests.swift), plus a few more. */
class PrivateNetworkTest {
    @Test fun privateNetworkTable() {
        for (host in listOf(
            "192.168.1.5", "10.0.0.2", "172.31.255.1", "127.0.0.1", "169.254.1.1", "100.64.0.1", "::1",
            "fe80::1%en0", "fd00::1", "::ffff:192.168.1.5",
        )) {
            assertTrue(PrivateNetwork.isAllowed(host), host)
        }
        for (host in listOf("8.8.8.8", "172.32.0.1", "172.15.0.1", "100.128.0.1", "2001:db8::1", "::ffff:8.8.8.8", "garbage", "")) {
            assertFalse(PrivateNetwork.isAllowed(host), host)
        }
    }

    @Test fun edgesOfEachRange() {
        for (host in listOf(
            "10.255.255.255", "172.16.0.0", "192.168.0.0", "192.168.255.255", "169.254.0.1", "100.127.255.255",
            "127.255.0.1", "[fe80::1]", "FE80::abcd:1", "febf::1", "fc00::1", "fdff:ffff::1",
            "0:0:0:0:0:0:0:1", "::ffff:10.1.2.3", "0:0:0:0:0:ffff:c0a8:0105",
        )) {
            assertTrue(PrivateNetwork.isAllowed(host), host)
        }
        for (host in listOf(
            "11.0.0.1", "192.169.0.1", "169.255.0.1", "100.63.255.255", "128.0.0.1", "fec0::1", "fe00::1",
            "fe00::", "::", "::2", "2001:db8::ffff:192.168.1.5", "::ffff:100.128.0.1",
        )) {
            assertFalse(PrivateNetwork.isAllowed(host), host)
        }
    }

    /** Only literal addresses: names are never resolved, and malformed addresses are refused. */
    @Test fun namesAndMalformedAddressesAreRefused() {
        for (host in listOf(
            "localhost", "mac.local", "evil.example", "192.168.1", "192.168.1.256", "192.168.01.5", "192.168.1.5.6",
            "1.2.3.4:80", "fe80:::1", "fe80::1::2", "1:2:3:4:5:6:7:8:9", "fe80::g", "12345::1", ":1", "1:", "[]",
            "fe80::1.2.3", "fe80::192.168.1.5:1",
        )) {
            assertFalse(PrivateNetwork.isAllowed(host), host)
        }
    }
}
