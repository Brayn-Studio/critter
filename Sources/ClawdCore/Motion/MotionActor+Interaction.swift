import Foundation

/// Travel and pile seats, drag-follow and gaze — design §4.8–4.11.
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
    public func travel(fromDx: Int, fromDy: Int, delay: Int, hopLength: Int = 14, seat: Seat? = nil,
                       completion: ((Bool) -> Void)? = nil) {
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

    // MARK: - Follow

    /// While another Clawd is dragged, this one stays put on screen and walks after the window,
    /// looking toward the dragged one once caught up. Ignored while traveling or hidden.
    public func startFollow(lookLeft: Bool) {
        guard !traveling, !hidden else { return }
        cancelOnce()
        gazePose = nil
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
        let names = skin.interactions
        gazePose = zone.map {
            switch $0 {
            case .left: names.lookLeft
            case .right: names.lookRight
            case .up: names.lookUp
            case .down: names.lookDown
            case .center: names.lookCenter
            }
        }
    }

    /// The gaze pose, when it may replace the current one: idle and awake, or done; no
    /// one-shot, no mode, not following.
    var activeGaze: String? {
        guard let gazePose, (state == .idle && !asleep) || state == .done,
              !onceActive, modeName == nil, !following else { return nil }
        return gazePose
    }
}
