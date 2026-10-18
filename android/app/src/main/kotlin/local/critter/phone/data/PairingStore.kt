package local.critter.phone.data

import android.content.Context
import androidx.core.content.edit

/** Everything needed to reconnect to the Mac without pairing again. */
data class Pairing(
    val host: String,
    val port: Int,
    val fingerprint: String,
    val macName: String,
    val deviceId: String,
    val token: String,
)

/** The pairing, in app-private SharedPreferences (spec §10). */
class PairingStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("pairing", Context.MODE_PRIVATE)

    fun load(): Pairing? {
        val host = prefs.getString("host", null) ?: return null
        val fingerprint = prefs.getString("fingerprint", null) ?: return null
        val deviceId = prefs.getString("deviceId", null) ?: return null
        val token = prefs.getString("token", null) ?: return null
        return Pairing(
            host = host,
            port = prefs.getInt("port", 0).takeIf { it > 0 } ?: return null,
            fingerprint = fingerprint,
            macName = prefs.getString("macName", "") ?: "",
            deviceId = deviceId,
            token = token,
        )
    }

    fun save(p: Pairing) = prefs.edit(commit = true) {
        putString("host", p.host)
        putInt("port", p.port)
        putString("fingerprint", p.fingerprint)
        putString("macName", p.macName)
        putString("deviceId", p.deviceId)
        putString("token", p.token)
    }

    fun clear() = prefs.edit(commit = true) { clear() }
}
