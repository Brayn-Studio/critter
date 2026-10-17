import Foundation

/// One pet's motion, advanced one tick (`skin.tickMs`) at a time and read out as an
/// `ActorSnapshot`. Pure logic and not thread-safe: create and use it on one thread.
///
/// Three playback layers, highest priority first: a one-shot clip (`play`), a mode loop
/// (`setMode`, e.g. while held) and the base loop (`setLoop`, the state's loop).
public final class MotionActor {
    public let skin: SkinManifest
    let rng: MotionRNG

    public var reduceMotion: Bool {
        didSet { if reduceMotion && !oldValue { reduceMotionTurnedOn() } }
    }
    public var tint: Tint?
    public var alpha: Double = 1
    public var z: Int = 2
    public var hidden = false
    public var noAccessory = false
    /// Height the actor is lifted off the ground, in cells (while held).
    public var lift = 0
    /// Sideways swing while held, in cells.
    public var lag = 0

    public internal(set) var clock = 0
    public internal(set) var modeName: String?
    /// Name of the clip playing now; nil for a generated clip.
    public internal(set) var currentClipName: String?
    public internal(set) var currentKeyIndex = 0
    public internal(set) var particles: [Particle] = []
    public var isPlayingOnce: Bool { onceActive }

    // Playback layers.
    var baseClip: MotionClip = []
    var baseName: String?
    var modeClip: MotionClip?
    var onceActive = false
    var onceCompletion: ((Bool) -> Void)?
    var current: MotionClip = []
    var keyTicks = 0
    /// Per effect name, how many times it fired (picks the next `cycle` group).
    var effectCycles: [String: Int] = [:]

    // State brain (MotionActor+State.swift).
    public internal(set) var state: PetState = .idle
    /// The running variant shown (or last shown).
    public internal(set) var variant = ""
    public internal(set) var asleep = false
    /// Whether the waiting state's resident "!" has appeared.
    public internal(set) var badgeVisible = true
    /// When false, nothing happens on its own: no fidgets, sleep, impatience or variant switch.
    public var brainEnabled = true
    var accessoryName: String?
    var propName: String?
    var idleTicks = 0
    var waitTicks = 0
    var fidgetIn = 80
    /// Ticks since the badge appeared; it hops for the first 2.
    var badgeAge = 99
    /// The variant the latest activity asks for, and for how many ticks it has asked.
    var desiredVariant = ""
    var desiredTicks = 0
    var variantShownTicks = 0

    // Travel, follow and gaze (MotionActor+Interaction.swift).
    public internal(set) var traveling = false
    public internal(set) var following = false
    var travelSeat: Seat?
    /// Still dragging: keep following even when caught up.
    var followHold = false
    var followLook: String?
    /// Follow offset in cells, y up.
    var offX: Double = 0
    var offY: Double = 0
    var gazePose: String?

    public init(skin: SkinManifest, rng: MotionRNG, reduceMotion: Bool = false) {
        self.skin = skin
        self.rng = rng
        self.reduceMotion = reduceMotion
        variant = skin.state(.running).defaultVariant ?? ""
        desiredVariant = variant
        tint = skin.state(.idle).tint
        accessoryName = skin.state(.idle).accessory
        setLoop(stateLoopName())
    }

    // MARK: - Playback

    public func setLoop(_ name: String) { setLoop(clip: skin.clips[name] ?? [], name: name) }

    public func setLoop(clip: MotionClip, name: String?) {
        baseClip = clip
        baseName = name
        if !onceActive && modeClip == nil { start(clip, name: name) }
    }

    public func setMode(_ name: String?) {
        modeName = name
        modeClip = name.map { skin.clips[$0] ?? [] }
        if !onceActive { resumeLoop() }
    }

    public func play(_ name: String, completion: ((Bool) -> Void)? = nil) {
        play(clip: skin.clips[name] ?? [], name: name, completion: completion)
    }

    /// Plays `clip` once over the loops. A one-shot it replaces completes with `false` — after
    /// the new one has started, so that callback may itself start another clip.
    public func play(clip: MotionClip, name: String?, completion: ((Bool) -> Void)? = nil) {
        let replaced = onceCompletion
        onceActive = true
        onceCompletion = completion
        start(clip, name: name)
        replaced?(false)
    }

    public func cancelOnce() {
        guard onceActive else { return }
        let done = onceCompletion
        onceActive = false
        onceCompletion = nil
        resumeLoop()
        done?(false)
    }

    /// Ends the one-shot as if it played to the end: back to the start of the mode (or base)
    /// loop, then the completion with `true`.
    func finishOnce() {
        let done = onceCompletion
        onceActive = false
        onceCompletion = nil
        resumeLoop()
        done?(true)
    }

    func resumeLoop() {
        if let modeClip { start(modeClip, name: modeName) } else { start(baseClip, name: baseName) }
    }

    private func start(_ clip: MotionClip, name: String?) {
        current = clip
        currentClipName = name
        currentKeyIndex = 0
        keyTicks = 0
        enterKey()
    }

    private func enterKey() {
        if let effect = currentKey?.effect { emit(effect) }
    }

    var currentKey: ClipKey? { current.indices.contains(currentKeyIndex) ? current[currentKeyIndex] : nil }

    /// Fires a particle effect. Unknown names are ignored; names starting with "@" are
    /// engine-internal events, never particles.
    public func emit(_ effect: String) {
        if effect.hasPrefix("@") {
            if effect == MotionTravel.seatEffect, let travelSeat { applySeat(travelSeat) }
            return
        }
        guard !reduceMotion, let spec = skin.effects[effect] else { return }
        let turn = effectCycles[effect, default: 0]
        effectCycles[effect] = turn + 1
        particles += ParticleSpawner.spawn(spec, cycleIndex: turn, rng: rng)
    }

    // MARK: - Tick

    public func step() {
        followStep()
        brainStep()
        clock += 1
        badgeAge += 1
        let dt = Double(skin.tickMs) / 1000
        for i in particles.indices { particles[i].step(dt: dt) }
        particles.removeAll { !$0.isAlive }
        if let spec = accessorySpec, let every = spec.twinkleEvery, every > 0, let twinkle = spec.twinkle,
           clock % every == 0, !noAccessory {
            emit(twinkle)
        }
        advanceKey()
    }

    private func advanceKey() {
        guard let key = currentKey else {
            if onceActive { finishOnce() }
            return
        }
        keyTicks += 1
        guard keyTicks >= key.ticks else { return }
        keyTicks = 0
        currentKeyIndex += 1
        if currentKeyIndex >= current.count {
            if onceActive {
                finishOnce()
                return
            }
            currentKeyIndex = 0
        }
        enterKey()
    }

    // MARK: - Output

    public func snapshot() -> ActorSnapshot {
        let f = frame()
        let markers = !hidden && markersAllowed(dy: f.dy)
        let particleDraws: [GlyphDraw] = hidden ? [] : particles.map { p in
            var d = p.draw()
            d.x += f.dx + lag
            d.y -= lift
            return d
        }
        return ActorSnapshot(
            hidden: hidden, pose: f.pose, bodyX: f.dx + lag, bodyY: f.dy + lift,
            offsetX: jsRound(offX), offsetY: jsRound(offY),
            tint: tint, alpha: alpha, z: z, shadowWidth: Self.shadowWidth(air: f.dy + lift),
            accessory: markers ? accessoryDraw() : nil, badge: markers ? badgeDraw() : nil,
            particles: particleDraws, props: hidden ? [] : propDraws(dx: f.dx))
    }

    /// The pose and key offset to show now.
    func frame() -> (pose: String, dx: Int, dy: Int) {
        if following && !reduceMotion { return (followPose(), 0, 0) }
        if reduceMotion {
            if modeName == skin.interactions.held { return (skin.interactions.heldStill, 0, 0) }
            let st = skin.state(state)
            if asleep { return (st.sleep?.still ?? st.still, 0, 0) }
            return (activeGaze ?? st.still, 0, st.stillDy ?? 0)
        }
        let key = currentKey
        return (activeGaze ?? key?.pose ?? skin.interactions.lookCenter, key?.dx ?? 0, key?.dy ?? 0)
    }

    /// Shadow width in cells for a body `air` cells above the ground.
    static func shadowWidth(air: Int) -> Int {
        air <= 0 ? 0 : air <= 2 ? 10 : air <= 5 ? 6 : 2
    }

    /// Ticks until the snapshot can next change on its own (at least 1).
    public func ticksUntilChange() -> Int {
        if !particles.isEmpty || followMoving { return 1 }
        var n = Self.never
        if let key = currentKey { n = key.ticks - keyTicks } else if onceActive { n = 1 }
        n = Swift.min(n, markerTicksLeft(), brainTicksLeft())
        return Swift.max(1, n)
    }

    /// Returned by `ticksUntilChange` when nothing will change on its own.
    static let never = Int(Int32.max)
}
