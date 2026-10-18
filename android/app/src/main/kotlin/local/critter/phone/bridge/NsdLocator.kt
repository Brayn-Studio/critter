package local.critter.phone.bridge

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.net.Inet4Address
import kotlin.coroutines.resume

/** A Critter bridge seen on the local network. */
data class FoundMac(val name: String, val host: String, val port: Int)

/** Finds the Mac by its `_critter._tcp` Bonjour service. Holds a MulticastLock only while discovering. */
class NsdLocator(context: Context) {
    private val app = context.applicationContext
    private val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = app.getSystemService(Context.WIFI_SERVICE) as WifiManager

    /** Resolved services as they are found, until the collector goes away. */
    fun browse(): Flow<FoundMac> = callbackFlow {
        val lock = wifi.createMulticastLock("critter-nsd").apply {
            setReferenceCounted(false)
            acquire()
        }
        val resolving = Mutex() // resolveService accepts one request at a time before API 34
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                close()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                launch {
                    val found = resolving.withLock { resolve(serviceInfo) }
                    if (found != null) trySend(found)
                }
            }
        }
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: RuntimeException) {
            close()
        }
        awaitClose {
            try {
                nsd.stopServiceDiscovery(listener)
            } catch (_: RuntimeException) {
                // never started
            }
            if (lock.isHeld) lock.release()
        }
    }

    /** The address of the Mac called [macName], or null if it does not show up within [timeoutMs]. */
    suspend fun find(macName: String, timeoutMs: Long = 5_000): Pair<String, Int>? =
        withTimeoutOrNull(timeoutMs) { browse().firstOrNull { namesMatch(it.name, macName) } }
            ?.let { it.host to it.port }

    @Suppress("DEPRECATION")
    private suspend fun resolve(service: NsdServiceInfo): FoundMac? = withTimeoutOrNull(3_000) {
        suspendCancellableCoroutine { cont ->
            nsd.resolveService(service, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    if (cont.isActive) cont.resume(null)
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    val addresses =
                        if (Build.VERSION.SDK_INT >= 34) serviceInfo.hostAddresses else listOfNotNull(serviceInfo.host)
                    val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()
                    val host = address?.hostAddress?.substringBefore('%')
                    if (cont.isActive) cont.resume(host?.let { FoundMac(serviceInfo.serviceName, it, serviceInfo.port) })
                }
            })
        }
    }

    companion object {
        const val SERVICE_TYPE = "_critter._tcp."

        /** Bonjour may add " (2)" to a name that is taken; the pinned fingerprint is what really identifies the Mac. */
        fun namesMatch(serviceName: String, macName: String): Boolean =
            serviceName.equals(macName, ignoreCase = true) ||
                (macName.isNotEmpty() && serviceName.startsWith("$macName (", ignoreCase = true))
    }
}
