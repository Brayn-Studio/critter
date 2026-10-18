package local.critter.phone.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import local.critter.phone.repository

/** Brings the bridge back after a reboot or an app update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val app = context.applicationContext
        BridgeService.sync(app, app.repository)
    }
}
