package local.critter.phone

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import android.widget.FrameLayout
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinLibrary
import local.critter.phone.critter.CritterSlot
import local.critter.phone.critter.CritterTouchListener
import local.critter.phone.critter.CritterView
import kotlin.math.roundToInt

/**
 * Debug builds only: every bundled skin in every state, for checking the drawing against the desktop
 * (`am start -n local.critter.phone/.SkinGalleryActivity`). `--es mode sleep` shows one dozing Sprig instead;
 * it logs `debugFrameCount` every 10 s under the tag `CritterGallery`, to check that a resting Critter
 * barely redraws.
 */
class SkinGalleryActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var view: CritterView
    private lateinit var counter: android.widget.TextView
    private val startedAt = android.os.SystemClock.uptimeMillis()
    private val report = object : Runnable {
        override fun run() {
            val secs = (android.os.SystemClock.uptimeMillis() - startedAt) / 1000
            val text = "frames=${view.debugFrameCount} after ${secs}s"
            Log.i(TAG, text)
            counter.text = text
            handler.postDelayed(this, 5_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val library = SkinLibrary({ path ->
            try {
                assets.open(path).bufferedReader().use { it.readText() }
            } catch (_: java.io.IOException) {
                null
            }
        })
        val density = resources.displayMetrics.density
        val unit = (3 * density).roundToInt().toFloat() // whole pixels per cell keeps the art crisp
        val sleepOnly = intent.getStringExtra("mode") == "sleep"

        view = CritterView(this)
        view.listener = object : CritterTouchListener {
            override fun onTap(sessionId: String) { Log.i(TAG, "tap $sessionId") }
            override fun onLongDragEnd(sessionId: String) { Log.i(TAG, "dropped $sessionId") }
        }
        val slots = if (sleepOnly) {
            listOf(CritterSlot("sleeper", library.manifest("sprig"), PetState.idle, null, 1.0, 40 * density, 200 * density, unit, sleeping = true))
        } else {
            val states = listOf(PetState.idle, PetState.running, PetState.waiting, PetState.done, PetState.error)
            val skins = listOf("sprig", "mochi", "peep", "bristle", "frill", "spout", "bonnet")
            skins.flatMapIndexed { row, skin ->
                states.mapIndexed { col, state ->
                    CritterSlot(
                        sessionId = "$skin/$state",
                        manifest = library.manifest(skin),
                        state = state,
                        activity = null,
                        dimStrength = 1.0,
                        x = 8 * density + col * 19 * unit,
                        y = 60 * density + row * 22 * unit,
                        scale = unit,
                    )
                }
            }
        }
        view.setActors(slots)
        view.setBackgroundColor(Color.WHITE)
        counter = android.widget.TextView(this).apply { setTextColor(Color.BLACK); text = "frames=0"; setPadding(24, 120, 24, 0) }
        val root = FrameLayout(this)
        root.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        root.addView(counter)
        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        handler.postDelayed(report, 1_000)
    }

    override fun onPause() {
        handler.removeCallbacks(report)
        super.onPause()
    }

    private companion object {
        const val TAG = "CritterGallery"
    }
}
