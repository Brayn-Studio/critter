package local.critter.core.motion

import local.critter.core.skin.ClipKey
import local.critter.core.skin.MotionClip
import local.critter.core.skin.SkinManifest

/** Clips the phone app builds from any skin's interaction names (design §7), played with `MotionActor.play`. */
object MotionCues {
    /** "Looks at you" when a sheet settles: the notice hop, then a held look up with a blink (about 1.7 s). */
    fun lookAtYou(skin: SkinManifest): MotionClip {
        val n = skin.interactions
        val notice = skin.clips[n.notice].orEmpty().map { it.copy() }
        return notice + listOf(
            ClipKey(n.lookUp, 12),
            ClipKey(n.blinkPose, 2),
            ClipKey(n.lookUp, 10),
            ClipKey(n.lookCenter, 2),
        )
    }

    /** One small hop that lands with dust (the floating shelf opening and closing). */
    fun hop(skin: SkinManifest): MotionClip {
        val n = skin.interactions
        return listOf(
            ClipKey(n.hop, 1, 0, 2),
            ClipKey(n.hop, 1, 0, 4),
            ClipKey(n.hop, 1, 0, 3),
            ClipKey(n.hop, 1, 0, 1),
            ClipKey(n.land, 2, 0, 0, n.landDust),
        )
    }
}
