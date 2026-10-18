package local.critter.phone.ui.answer

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity

/** Placeholder until the answer sheet lands; the notification actions already point here. */
class AnswerActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        finish()
    }

    companion object {
        const val EXTRA_REQUEST_ID = "requestId"

        fun intent(context: Context, requestId: String): Intent =
            Intent(context, AnswerActivity::class.java).putExtra(EXTRA_REQUEST_ID, requestId)
    }
}
