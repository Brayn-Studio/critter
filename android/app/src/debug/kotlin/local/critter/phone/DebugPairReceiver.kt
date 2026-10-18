package local.critter.phone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import local.critter.core.protocol.PairingUri

/**
 * Debug builds only: `adb shell am broadcast -a local.critter.phone.DEBUG_PAIR --es uri '<critter-pair://…>'
 * -n local.critter.phone/.DebugPairReceiver` pairs without the camera.
 */
class DebugPairReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "local.critter.phone.DEBUG_PAIR") return
        val uri = intent.getStringExtra("uri")?.let(PairingUri::parse)
        if (uri == null) {
            Log.w("CritterDebug", "DEBUG_PAIR: missing or invalid uri")
            return
        }
        val repo = context.applicationContext.repository
        val pending = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                Log.i("CritterDebug", "DEBUG_PAIR result: ${repo.pair(uri)}")
            } finally {
                pending.finish()
            }
        }
    }
}
