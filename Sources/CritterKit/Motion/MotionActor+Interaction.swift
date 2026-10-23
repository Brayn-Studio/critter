import Foundation

/// Travel and pile seats, holding under ground, drag-follow and gaze — design §4.8–4.11.
extension MotionActor {
    /// Follow offset limits, in cells.
    static let followMaxX: Double = 12
    static let followMaxY: Double = 8
    /// Beyond this horizontal offset a follower trots: 2 cells a tick instead of 1.
    static let followTrotBeyond: Double = 6

    // MARK: - Travel

    /// Hops from (`fromDx`, `fromDy`) cells relative to the new anchor to it. With `seat`, it
    /// lands raised on the back of the pile and stays there dimmed. Under reduced motion it
    /// arrives at once and `completion(true)` runs before returning.
    ///
    /// A hop that cuts short the state's entrance (or the exit leading into it) plays that
    /// entrance again once it lands, as long as the state is still the same: a state change
    /// that also moves the Critter's column must show both.
    public func travel(fromDx: Int, fromDy: Int, delay: Int, hopLength: Int = 14, seat: Seat? = nil,
                       completion: ((Bool) -> Void)? = nil) {
        var fromDx = fromDx, fromDy = fromDy
        // Hopping somewhere else ends a follow: the hop starts where the body is drawn (the
        // follow offset folded into its start, y up like the keys), not at the anchor.
        if following {
            fromDx += jsRound(offX)
            fromDy += jsRound(offY)
            following = false
            followHold = false
            offX = 0
            offY = 0
        }
        let resumeEntrance = onceActive ? onceEntrance : nil
        let resumeState = state
        if let seat { setLoop(clip: [ClipKey(pose: skin.interactions.land, ticks: 9999, dx: 0, dy: seat.row)], name: nil) }
        if reduceMotion {
            if let seat { applySeat(seat) }
            completion?(true)
            return
        }
        let keys = MotionTravel.keys(fromDx: fromDx, fromDy: fromDy, toDy: seat?.row ?? 0, delay: delay,
                                     hopLength: hopLength, names: skin.interactions)
        // The flags belong to this travel only: a replaced travel's callback (or whatever it
        // starts) must neither clear them for this one nor leave them set after it.
        travelID += 1
        let id = travelID
        travelSeat = seat
        traveling = true
        play(clip: keys, name: nil) { [weak self] ok in
            if let self, self.travelID == id {
                self.traveling = false
                self.travelSeat = nil
                if ok, seat == nil, let resumeEntrance, self.state == resumeState, !self.reduceMotion {
                    self.startEntrance(resumeEntrance)
                }
            }
            completion?(ok)
        }
    }

    /// Back from a pile seat to the state's own look and loop.
    public func unseat() {
        alpha = 1
        z = 2
        tint = skin.state(state).tint
        noAccessory = false
        setLoop(stateLoopName())
    }

    func applySeat(_ seat: Seat) {
        tint = .dim
        alpha = seat.alpha
        z = seat.z
    }

    /// Reduced motion just turned on: drop particles and follow offsets, land any hop at once.
    func reduceMotionTurnedOn() {
        particles.removeAll()
        offX = 0
        offY = 0
        if skin.state(state).badge != nil { badgeVisible = true }
        if traveling {
            if let travelSeat { applySeat(travelSeat) }
            finishOnce()
        }
    }

    // MARK: - Under ground

    /// Sinks for good (a goodbye or a hide): from now on its loop is `depth` cells under
    /// ground, above any mode or state loop, until `releaseUnderground()`. Only one-shots still
    /// show over it (the sink itself, a drop-in); the brain rests, a state is taken quietly,
    /// and a follow, a lift or a mode ends -- nothing brings it back up on its own.
    public func holdUnderground(depth: Int) {
        underground = depth
        modeName = nil
        modeClip = nil
        following = false
        followHold = false
        offX = 0
        offY = 0
        lift = 0
        lag = 0
        if !onceActive { resumeLoop() }
    }

    /// Back up from under ground: the state's loop resumes (after any one-shot playing).
    public func releaseUnderground() {
        guard underground != nil else { return }
        underground = nil
        if !onceActive { resumeLoop() }
    }

    // MARK: - Follow

    /// While another Critter is dragged, this one stays put on screen and walks after the window,
    /// looking toward the dragged one once caught up. Ignored while traveling, hidden or held
    /// under ground.
    public func startFollow(lookLeft: Bool) {
        guard !traveling, !hidden, underground == nil else { return }
        cancelOnce()
        gazeZone = nil
        following = true
        followHold = true
        followLook = lookLeft ? skin.interactions.lookLeft : skin.interactions.lookRight
    }

    /// The window moved by (`dx`, `dy`) cells, y up.
    public func followShift(dx: Double, dy: Double) {
        guard following, !reduceMotion else { return }
        offX = min(max(offX - dx, -Self.followMaxX), Self.followMaxX)
        offY = min(max(offY - dy, -Self.followMaxY), Self.followMaxY)
    }

    /// The drag ended: stop following once caught up.
    public func releaseFollow() { followHold = false }

    func followStep() {
        guard following else { return }
        if reduceMotion {
            offX = 0
            offY = 0
        }
        let sx: Double = abs(offX) > Self.followTrotBeyond ? 2 : 1
        offX = abs(offX) <= sx ? 0 : offX - (offX > 0 ? sx : -sx)
        if offY != 0 {
            offY = abs(offY) <= 1 ? 0 : offY - (offY > 0 ? 1 : -1)
            if offY == 0 { emit(skin.interactions.landDust) }
        }
        if !followHold && offX == 0 && offY == 0 {
            following = false
            if !reduceMotion { play(skin.interactions.blink) }
        }
    }

    /// Where the body is drawn relative to its anchor while following, in whole cells (y up):
    /// the snapshot's `offsetX`/`offsetY`, without building a snapshot.
    public var followOffset: (x: Int, y: Int) { (jsRound(offX), jsRound(offY)) }

    /// Still catching up, or about to stop following.
    var followMoving: Bool { following && (offX != 0 || offY != 0 || !followHold) }

    /// Hop while catching up vertically, walk (trot when far) horizontally, else look at the
    /// dragged one.
    func followPose() -> String {
        let names = skin.interactions
        if abs(offY) >= 1 { return names.hop }
        if abs(offX) >= 1 {
            let cycle = offX < 0 ? names.walkRight : names.walkLeft
            let odd = (clock / (abs(offX) > Self.followTrotBeyond ? 1 : 2)) % 2 == 1
            return cycle[(odd ? 0 : 1) % cycle.count]
        }
        return followLook ?? names.lookCenter
    }

    // MARK: - Gaze

    public func setGaze(_ zone: GazeZone?) {
        gazeZone = zone
    }

    /// The gaze pose, when it may replace the current one: idle and awake, or done; no
    /// one-shot, no mode, not following, not under ground. A state with its own `gaze` poses
    /// looks around with those.
    var activeGaze: String? {
        guard let gazeZone, (state == .idle && !asleep) || state == .done,
              !onceActive, modeName == nil, !following, underground == nil else { return nil }
        if let poses = skin.state(state).gaze { return poses.pose(gazeZone) }
        let names = skin.interactions
        switch gazeZone {
        case .left: return names.lookLeft
        case .right: return names.lookRight
        case .up: return names.lookUp
        case .down: return names.lookDown
        case .center: return names.lookCenter
        }
    }
}
