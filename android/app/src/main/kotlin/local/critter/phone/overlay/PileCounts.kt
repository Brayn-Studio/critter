package local.critter.phone.overlay

import androidx.compose.ui.graphics.Color
import local.critter.core.motion.GazeZone
import local.critter.core.overlay.Edge
import local.critter.core.protocol.BridgeSession
import local.critter.phone.ui.stateIcon
import local.critter.phone.ui.theme.CritterColors

/** The order of the count tag: the desktop markers from the most to the least urgent. */
private val ICON_ORDER = listOf("q", "sun", "check", "bang", "z")

/** Which states a tag that is too narrow leaves out first: idle, then done, running and error; waiting always stays. */
private val DROP_ORDER = listOf("z", "check", "sun", "bang")

/**
 * The floating pile's count tag (design §8.4): each state's icon ([stateIcon]) and how many sessions are in it, in
 * the order `q, sun, check, bang, z`; states nobody is in are left out.
 */
fun pileCounts(sessions: List<BridgeSession>): List<Pair<String, Int>> {
    val counts = sessions.groupingBy { stateIcon(it.state) }.eachCount()
    return ICON_ORDER.mapNotNull { icon -> counts[icon]?.let { icon to it } }
}

/**
 * What of [counts] a tag [maxWidth] wide shows, [width] being how wide a tag with those entries is: the least
 * urgent states are left out until it fits ([DROP_ORDER]), but never the last one. The total is on the "n 个会话"
 * tag anyway, so a crowded pile loses detail, not information that matters.
 */
fun fitCounts(counts: List<Pair<String, Int>>, maxWidth: Float, width: (List<Pair<String, Int>>) -> Float): List<Pair<String, Int>> {
    var entries = counts
    for (drop in DROP_ORDER) {
        if (entries.size <= 1 || width(entries) <= maxWidth) break
        entries = entries.filter { it.first != drop }
    }
    return entries
}

/**
 * Where the collapsed pile's calm Critters rest their gaze (design §8.4 "贴右边时宠物朝左，贴左边朝右"): into the
 * screen, away from the edge it is snapped to. The engine only lets idle and done Critters look; busy ones keep
 * their animations.
 */
fun inwardGaze(edge: Edge): GazeZone = if (edge == Edge.Right) GazeZone.left else GazeZone.right

/** A count icon's color, as on the mockup: the deep orange question mark, the sun, the check, the bang, a grey z. */
fun countIconColor(icon: String, colors: CritterColors): Color = when (icon) {
    "q" -> colors.waitDeep
    "sun" -> colors.runGlyph
    "check" -> colors.doneGlyph
    "bang" -> colors.errGlyph
    else -> colors.ink3
}
