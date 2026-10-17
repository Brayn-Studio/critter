import Foundation

/// States, the brain (fidgets, sleep, impatience, work-variant debounce), head markers and
/// props — animation v2 design §4.2–4.5, §4.7 and §4.12.
extension MotionActor {
    /// A new activity must persist this long before the running variant switches...
    static let variantSettleTicks = 20
    /// ...and the current variant must have shown at least this long.
    static let variantMinShowTicks = 40

    // MARK: - States

    /// The base loop the current state wants now.
    public func stateLoopName() -> String {
        let st = skin.state(state)
        if asleep, let sleep = st.sleep { return sleep.loop }
        if state == .running, let v = variantSpec(variant) { return v.loop }
        if isImpatient, let impatient = st.impatient { return impatient.loop }
        return st.loop ?? ""
    }

    public func enterState(_ s: PetState, quiet: Bool = false) {
        let previous = state
        let exit = previous == .running && s != .running ? variantSpec(variant)?.exit : nil
        let st = skin.state(s)
        state = s
        asleep = false
        idleTicks = 0
        waitTicks = 0
        tint = st.tint
        accessoryName = st.accessory
        if s == .running {
            variant = desiredVariant
            desiredTicks = 0
            variantShownTicks = 0
        }
        propName = s == .running ? variantSpec(variant)?.prop : nil
        setLoop(stateLoopName())
        fidgetIn = rng.integer(in: 40...90)
        badgeVisible = quiet || reduceMotion
        if quiet { return }
        if reduceMotion {                      // no entrances or exits under reduced motion
            cancelOnce()
            return
        }
        let enter = s == .running ? variantSpec(variant)?.enter ?? st.enter : st.enter
        if let exit {
            play(exit) { [weak self] ok in
                guard let self, self.state == s else { return }
                // An interrupted exit skips the entrance, but the badge must still show.
                if ok { self.startEntrance(enter) } else { self.revealBadge() }
            }
            if currentClipName == exit { onceEntrance = enter }
        } else if enter == nil, previous == .done, s == .idle, let seen = skin.state(.done).seen {
            play(seen)
            onceEntrance = seen
        } else {
            startEntrance(enter)
        }
    }

    /// Plays the entrance (or cancels the one-shot when there is none); the waiting badge
    /// appears the moment it starts.
    func startEntrance(_ enter: String?) {
        revealBadge()
        if let enter {
            play(enter)
            onceEntrance = enter
        } else {
            cancelOnce()
        }
    }

    private func revealBadge() {
        guard skin.state(state).badge != nil else { return }
        badgeVisible = true
        badgeAge = 0
    }

    /// Records which kind of work the session is doing; nil or unknown means the default variant.
    /// Outside `running` it is just remembered; while running the switch is debounced.
    public func setActivity(_ activity: String?) {
        let running = skin.state(.running)
        let v = activity.flatMap { running.variants?[$0] == nil ? nil : $0 } ?? running.defaultVariant ?? ""
        guard v != desiredVariant else { return }
        desiredVariant = v
        desiredTicks = 0
    }

    public func wake() {
        guard asleep else { return }
        asleep = false
        idleTicks = 0
        setLoop(stateLoopName())
        if let wake = skin.state(state).sleep?.wake { play(wake) }
    }

    func variantSpec(_ name: String) -> VariantSpec? { skin.state(.running).variants?[name] }

    var isImpatient: Bool {
        guard state == .waiting, let impatient = skin.state(.waiting).impatient else { return false }
        return waitTicks >= impatient.after
    }

    // MARK: - Brain

    var brainActive: Bool { brainEnabled && modeName == nil && !traveling && !following }

    func brainStep() {
        guard brainActive else { return }
        let st = skin.state(state)
        if state == .idle, !asleep, let sleep = st.sleep {
            idleTicks += 1
            if idleTicks >= sleep.after {
                asleep = true
                setLoop(sleep.loop)
                play(sleep.doze)
                return
            }
        }
        if state == .waiting, let impatient = st.impatient {
            waitTicks += 1
            if waitTicks == impatient.after { setLoop(impatient.loop) }
        }
        if state == .running { debounceVariant() }
        // Nobody sees a hidden Clawd fidget (a pile member behind the lead), and its one-shot
        // would keep the clock waking for nothing: its countdown waits until it shows again.
        if let fidget = st.fidget, !onceActive, !asleep, !reduceMotion, !hidden {
            fidgetIn -= 1
            if fidgetIn <= 0 {
                if let clip = rng.pick(fidget.pick) { play(clip) }
                let lo = fidget.every.first ?? 1
                fidgetIn = rng.integer(in: lo...Swift.max(lo, fidget.every.last ?? lo))
            }
        }
    }

    private func debounceVariant() {
        variantShownTicks += 1
        guard desiredVariant != variant else { return }
        desiredTicks += 1
        if desiredTicks >= Self.variantSettleTicks && variantShownTicks >= Self.variantMinShowTicks {
            switchVariant(to: desiredVariant)
        }
    }

    /// Old variant's exit (if any), then the new variant's own enter (if any) over its loop.
    private func switchVariant(to v: String) {
        let old = variantSpec(variant), new = variantSpec(v)
        variant = v
        desiredTicks = 0
        variantShownTicks = 0
        propName = new?.prop
        setLoop(stateLoopName())
        if reduceMotion { return }
        if let exit = old?.exit {
            play(exit) { [weak self] ok in
                guard ok, let self, self.state == .running, self.variant == v, let enter = new?.enter else { return }
                self.play(enter)
            }
        } else if let enter = new?.enter {
            play(enter)
        }
    }

    func brainTicksLeft() -> Int {
        guard brainActive else { return Self.never }
        let st = skin.state(state)
        var n = Self.never
        if st.fidget != nil, !onceActive, !asleep, !reduceMotion, !hidden { n = Swift.min(n, fidgetIn) }
        if state == .idle, !asleep, let sleep = st.sleep { n = Swift.min(n, sleep.after - idleTicks) }
        if state == .waiting, let impatient = st.impatient, waitTicks < impatient.after {
            n = Swift.min(n, impatient.after - waitTicks)
        }
        if state == .running, desiredVariant != variant {
            n = Swift.min(n, Swift.max(Self.variantSettleTicks - desiredTicks, Self.variantMinShowTicks - variantShownTicks))
        }
        return n
    }

    // MARK: - Head markers and props

    var accessorySpec: AccessorySpec? { accessoryName.flatMap { skin.accessories[$0] } }

    /// Head marker and badge are hidden while merged, held, traveling, asleep, or when the key
    /// sinks or rises too far.
    func markersAllowed(dy: Int) -> Bool {
        !noAccessory && modeName != skin.interactions.held && !traveling && !asleep && dy > -6 && dy < 7
    }

    func accessoryDraw() -> GlyphDraw? {
        guard let spec = accessorySpec else { return nil }
        let glyph: String, top: Int
        var bob = 0
        if let frames = spec.frames, !frames.isEmpty {
            glyph = reduceMotion ? spec.reduced ?? frames[0] : frames[spinnerFrame(spec, frames, at: clock)]
            let h = glyphSize(glyph).h, box = spec.box ?? h
            top = -2 - box + Int(floor(Double(box - h) / 2))
        } else if let g = spec.glyph {
            glyph = g
            top = -2 - glyphSize(g).h
            if let every = spec.bobEvery, every > 0, !reduceMotion, (clock / every) % 2 == 1 { bob = -1 }
        } else {
            return nil
        }
        return GlyphDraw(glyph: glyph, color: spec.color, x: centeredX(glyph) + drawnLag, y: top + bob - lift, alpha: 1)
    }

    func badgeDraw() -> GlyphDraw? {
        guard badgeVisible, let badge = skin.state(state).badge else { return nil }
        let hop = !reduceMotion && badgeHops(clock: clock, age: badgeAge) ? -1 : 0
        return GlyphDraw(glyph: badge.glyph, color: badge.color, x: badge.x + drawnLag,
                         y: -2 - glyphSize(badge.glyph).h + hop - lift, alpha: 1)
    }

    private func badgeHops(clock c: Int, age: Int) -> Bool {
        guard let badge = skin.state(state).badge else { return false }
        let period = isImpatient ? badge.impatientHopEvery : badge.hopEvery
        return age < 2 || (period > 0 && c % period < 2)
    }

    /// The juggled balls, only while the variant's own loop plays.
    func propDraws(dx: Int) -> [GlyphDraw] {
        guard !reduceMotion, state == .running, let name = propName, let prop = skin.props[name],
              let loop = variantSpec(variant)?.loop, currentClipName == loop else { return [] }
        return prop.colors.indices.map { i in
            let ph = Double((clock + 6 * i) % 18) / 18
            return GlyphDraw(glyph: prop.glyph, color: prop.colors[i], x: jsRound(3 + 11 * ph) + dx + drawnLag,
                             y: -2 - jsRound(7 * sin(.pi * ph)) - lift, alpha: 1)
        }
    }

    /// Spinner frame on a cosine ease: slow at both ends of its period.
    private func spinnerFrame(_ spec: AccessorySpec, _ frames: [String], at c: Int) -> Int {
        guard let period = spec.periodMs, period > 0 else { return 0 }
        let t = Double(c * skin.tickMs)
        let i = jsRound((1 - cos(2 * .pi * t / Double(period))) / 2 * Double(frames.count - 1))
        return Swift.min(Swift.max(i, 0), frames.count - 1)
    }

    func markerTicksLeft() -> Int {
        var n = Self.never
        if !hidden, !propDraws(dx: 0).isEmpty { return 1 }
        if let spec = accessorySpec, let every = spec.twinkleEvery, every > 0, spec.twinkle != nil,
           !reduceMotion, !noAccessory {
            n = Swift.min(n, every - clock % every)
        }
        guard !hidden, !reduceMotion, markersAllowed(dy: frame().dy) else { return n }
        if let spec = accessorySpec {
            if let frames = spec.frames, frames.count > 1, spec.periodMs != nil {
                let now = spinnerFrame(spec, frames, at: clock)
                n = Swift.min(n, (1...34).first { spinnerFrame(spec, frames, at: clock + $0) != now } ?? 34)
            }
            if let every = spec.bobEvery, every > 0 { n = Swift.min(n, every - clock % every) }
        }
        if badgeVisible, let badge = skin.state(state).badge {
            let now = badgeHops(clock: clock, age: badgeAge)
            let span = Swift.max(badge.hopEvery, badge.impatientHopEvery) + 2
            if let k = (1...span).first(where: { badgeHops(clock: clock + $0, age: badgeAge + $0) != now }) {
                n = Swift.min(n, k)
            }
        }
        return n
    }

    private func glyphSize(_ name: String) -> (w: Int, h: Int) {
        let rows = skin.glyphs[name] ?? []
        return (rows.first?.count ?? 0, rows.count)
    }

    /// Left column that centres the glyph on the base box (`round(9 − w/2)` for an 18-wide box).
    private func centeredX(_ glyph: String) -> Int {
        jsRound(Double(skin.grid.first ?? 18) / 2 - Double(glyphSize(glyph).w) / 2)
    }
}

extension MotionRNG {
    /// A weighted pick, as the preview's `pickWeighted`.
    func pick(_ list: [WeightedClip]) -> String? {
        let total = list.reduce(0) { $0 + $1.weight }
        var r = unit() * Double(total)
        for w in list {
            r -= Double(w.weight)
            if r <= 0 { return w.clip }
        }
        return list.first?.clip
    }
}
