package local.critter.phone.critter

import local.critter.core.flock.FlockModel
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinLibrary

/**
 * The merged pile as Critter slots, like the desktop's: the most urgent session in front at ([x], [y]), and
 * up to two more behind it, raised a cell each, shifted to the side, dimmed and still (rows 1 and 2).
 */
object PileSlots {
    /** How far each back row sits to the right of the front Critter, in cells. */
    private val BACK_DX = intArrayOf(4, 7)

    /** The pile is this many cells wider than one Critter. */
    const val EXTRA_CELLS = 7

    fun build(sessions: List<BridgeSession>, library: SkinLibrary, dim: Double, x: Float, y: Float, scale: Float): List<CritterSlot> {
        if (sessions.isEmpty()) return emptyList()
        val lead = FlockModel.merged(sessions).lead
        val out = ArrayList<CritterSlot>(3)
        sessions.filter { it.id != lead.id }.take(2).forEachIndexed { i, s ->
            out += slot(s, library, dim, x + BACK_DX[i] * scale, y, scale, seatRow = i + 1)
        }
        out += slot(lead, library, dim, x, y, scale, seatRow = null)
        return out
    }

    /** The offline pile: one grey, sleeping Critter. */
    fun offline(skin: String, library: SkinLibrary, dim: Double, x: Float, y: Float, scale: Float) = CritterSlot(
        sessionId = OFFLINE_ID, manifest = library.manifest(skin), state = PetState.idle, activity = null,
        dimStrength = dim, x = x, y = y, scale = scale, sleeping = true,
    )

    fun slot(s: BridgeSession, library: SkinLibrary, dim: Double, x: Float, y: Float, scale: Float, seatRow: Int? = null) =
        CritterSlot(s.id, library.manifest(s.skin), s.state, s.activity, dim, x, y, scale, seatRow)

    const val OFFLINE_ID = "offline"
}
