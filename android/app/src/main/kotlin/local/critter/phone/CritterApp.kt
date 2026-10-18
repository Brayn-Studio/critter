package local.critter.phone

import android.app.Application
import android.content.Context
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.service.Alerts

class CritterApp : Application() {
    lateinit var repository: BridgeRepository
        private set

    override fun onCreate() {
        super.onCreate()
        Alerts.createChannels(this)
        repository = BridgeRepository(this)
    }
}

/** The app's single [BridgeRepository], from any context. */
val Context.repository: BridgeRepository
    get() = (applicationContext as CritterApp).repository
