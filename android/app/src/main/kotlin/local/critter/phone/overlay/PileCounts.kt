package local.critter.phone.overlay

import local.critter.core.protocol.BridgeSession
import local.critter.phone.ui.stateIcon

/** The order of the count tag: the desktop markers from the most to the least urgent. */
private val ICON_ORDER = listOf("q", "sun", "check", "bang", "z")

/**
 * The floating pile's count tag (design §8.4): each state's icon ([stateIcon]) and how many sessions are in it, in
 * the order `q, sun, check, bang, z`; states nobody is in are left out.
 */
fun pileCounts(sessions: List<BridgeSession>): List<Pair<String, Int>> {
    val counts = sessions.groupingBy { stateIcon(it.state) }.eachCount()
    return ICON_ORDER.mapNotNull { icon -> counts[icon]?.let { icon to it } }
}
