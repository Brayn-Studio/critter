package local.critter.phone.ui.detail

import android.app.Activity
import android.content.Context
import android.content.Intent

/** Placeholder until the session details sheet (task 7) lands. */
class DetailActivity : Activity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        finish()
    }

    companion object {
        const val EXTRA_SESSION_ID = "sessionId"

        fun intent(context: Context, sessionId: String): Intent =
            Intent(context, DetailActivity::class.java).putExtra(EXTRA_SESSION_ID, sessionId)
    }
}
