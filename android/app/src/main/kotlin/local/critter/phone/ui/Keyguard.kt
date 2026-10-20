package local.critter.phone.ui

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.ContextWrapper

/**
 * Runs [action] now if the phone is unlocked; on the lock screen, asks to unlock first and runs it only once that
 * worked (spec §8.6). Every path that sends something to the Mac from a screen goes through here.
 */
fun Activity.withKeyguardDismissed(action: () -> Unit) {
    val keyguard = getSystemService(KeyguardManager::class.java)
    if (!keyguard.isKeyguardLocked) {
        action()
        return
    }
    keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
        override fun onDismissSucceeded() = action()
    })
}

/** The activity behind a Compose screen's context (to dismiss the keyguard from, or for its window). */
tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
