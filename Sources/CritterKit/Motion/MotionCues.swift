/// Clips the phone app builds from any skin's interaction names (design §7), played with `MotionActor.play`.
public enum MotionCues {
    /// "Looks at you" when a sheet settles: the notice hop, then a held look up with a blink (about 1.7 s).
    public static func lookAtYou(_ skin: SkinManifest) -> MotionClip {
        let n = skin.interactions
        let notice = skin.clips[n.notice] ?? []
        return notice + [
            ClipKey(pose: n.lookUp, ticks: 12),
            ClipKey(pose: n.blinkPose, ticks: 2),
            ClipKey(pose: n.lookUp, ticks: 10),
            ClipKey(pose: n.lookCenter, ticks: 2),
        ]
    }

    /// One small hop that lands with dust (the floating shelf opening and closing).
    public static func hop(_ skin: SkinManifest) -> MotionClip {
        let n = skin.interactions
        return [
            ClipKey(pose: n.hop, ticks: 1, dx: 0, dy: 2),
            ClipKey(pose: n.hop, ticks: 1, dx: 0, dy: 4),
            ClipKey(pose: n.hop, ticks: 1, dx: 0, dy: 3),
            ClipKey(pose: n.hop, ticks: 1, dx: 0, dy: 1),
            ClipKey(pose: n.land, ticks: 2, dx: 0, dy: 0, effect: n.landDust),
        ]
    }

    /// How long `hop(_:)` lasts on `skin`'s clock, in milliseconds.
    public static func hopMs(_ skin: SkinManifest) -> Int {
        hop(skin).reduce(0) { $0 + $1.ticks } * skin.tickMs
    }
}
