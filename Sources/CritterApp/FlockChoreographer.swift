import AppKit
import CritterCore

/// One request to show a presentation: what `PetController` computed, and how to move the
/// window there once the choreography is ready for it.
struct FlockRequest {
    var presentation: FlockPresentation
    var layout: FlockLayout.Result
    var sessions: [PetSession]
    /// The window frame `place` would set if called now (screen coordinates): anchored and
    /// kept on screen, so a collapse can seat the pile exactly where it will stand.
    var frame: () -> CGRect
    var place: () -> Void

    /// The Critters this presentation needs: every session, or the empty state's placeholder.
    var ids: [String] {
        if case .empty = presentation { return [""] }
        return sessions.map(\.id)
    }
}

/// Times the flock's structural changes on `FlockView`'s stage (design §4.8, §4.9, §5.3):
/// expanding (hopping out of the pile), collapsing (taking pile seats one by one), joining
/// (peeking up), leaving (waving and sinking), and showing/hiding the pet. It also decides
/// when the window moves (`FlockRequest.place`): before a hop when the new layout is where
/// the Critters hop to, after it when they hop within the old one.
///
/// One choreography runs at a time; requests arriving meanwhile wait, and only the latest
/// is kept (`ChoreographyQueue`). States never wait: the view applies them on arrival, and
/// `stateDidChange` keeps a Critter seated in the pile seated.
@MainActor
final class FlockChoreographer {
    /// A Critter waiting in the pile for its turn to hop out to its column (expand).
    private struct Departure {
        var id: String
        var ticksLeft: Int
        var row: Int
        var from: CGPoint
        var to: CGPoint
        var group: JobGroup
        var gen: Int
    }

    /// Cells per hop when hopping somewhere else.
    private static let hopLength = 14
    /// Ticks between two Critters setting off.
    private static let stagger = 2
    /// How far below the ground a sinking or sunk Critter is held: its whole body is clipped away.
    private static let underground = 12
    /// Showing: each Critter drops in this long after the previous one. Hiding: each sinks
    /// this long after the previous one.
    private static let appearStagger: TimeInterval = 0.09
    private static let vanishStagger: TimeInterval = 0.06

    private unowned let view: FlockView
    private var queue = ChoreographyQueue<FlockRequest>()
    /// The newest request: what everything ends up showing.
    private var latest: FlockRequest?
    /// The running choreography's name, for its `choreo … end` line.
    private var runningKind: String?
    /// Bumped whenever a choreography starts or is cut short; continuations of an older one
    /// then do nothing.
    private var generation = 0
    /// Pile row of each Critter seated in (or hopping to) the pile during a collapse.
    private var seatRows: [String: Int] = [:]
    /// Who took each pile row last (a later arrival covers the earlier one).
    private var seatOccupants: [Int: String] = [:]
    /// Critters hopping to a pile row they haven't taken yet.
    private var arriving: [String: Int] = [:]
    /// A collapse whose Critters are all seated, waiting for their landing dust to settle
    /// before the still pile replaces them.
    private var pendingCollapseEnd: (() -> Void)?
    /// Critters still in the pile during an expand, each waiting for its turn to hop out.
    private var departures: [Departure] = []
    /// Critters kept under ground after sinking (goodbye or hide) until shown again. Their
    /// actors hold them there (`MotionActor.holdUnderground`) from the moment they start
    /// sinking, so no state, fidget or mode brings them back up meanwhile.
    private var sunk: Set<String> = []
    /// Sunk Critters whose job ends once their last particles (the poof) have faded.
    private var settlingDust: [(id: String, group: JobGroup)] = []
    /// Critters playing their goodbye / their peek-up right now.
    private var leaving: Set<String> = []
    private var joining: Set<String> = []
    /// Until a real session has been shown, a state is taken quietly (app launch).
    private var hasShownSessions = false
    /// Bumped by every show/hide, so a superseded one's staggered steps and completion lapse.
    private var showHideGeneration = 0
    private var vanishGroup: JobGroup?
    /// Critters playing their hide (sink) right now.
    private var vanishing: Set<String> = []

    init(view: FlockView) {
        self.view = view
    }

    func isLeaving(_ id: String) -> Bool {
        leaving.contains(id)
    }

    /// Whether a choreography has `id`'s Critter in hand: peeking up, waving goodbye, sinking or
    /// sunk, or seated in (hopping to, waiting in) the pile. A one-shot, a mode or a follow
    /// started on it would cut that short or pull it out of place.
    func isBusy(_ id: String) -> Bool {
        leaving.contains(id) || joining.contains(id) || vanishing.contains(id) || sunk.contains(id)
            || seatRows[id] != nil || arriving[id] != nil || departures.contains { $0.id == id }
    }

    func submit(_ request: FlockRequest) {
        latest = request
        if let next = queue.submit(request) { run(next) }
    }

    /// `id`'s Critter has left the stage (`FlockView.removeActor`): nothing of it may linger
    /// here, or a session coming back under the same id would get a Critter that counts as busy
    /// for good and ignores the pointer. Jobs still waiting on it end now.
    func forget(_ id: String) {
        sunk.remove(id)
        leaving.remove(id)
        joining.remove(id)
        vanishing.remove(id)
        seatRows[id] = nil
        arriving[id] = nil
        seatOccupants = seatOccupants.filter { $0.value != id }
        let dust = settlingDust.filter { $0.id == id }
        settlingDust.removeAll { $0.id == id }
        let waiting = departures.filter { $0.id == id }
        departures.removeAll { $0.id == id }
        for job in dust { job.group.leave() }
        for departure in waiting { departure.group.leave() }
    }

    /// `id` just took a new state. A Critter seated in (or hopping to) the pile stays there,
    /// dimmed and still: the new state's loop or entrance would put it on the ground.
    func stateDidChange(_ id: String) {
        guard let row = seatRows[id], let actor = view.actors[id] else { return }
        actor.cancelOnce()
        seat(actor, row: row)
    }

    /// Ends any choreography at once and snaps to the latest request (the pet is being hidden
    /// or shown: nobody should watch half a hop).
    func settle() {
        guard let kind = runningKind, let latest else { return }
        generation += 1
        runningKind = nil
        DiagnosticLog.shared.log("choreo \(kind) end")
        pendingCollapseEnd = nil
        for id in leaving { view.removeActor(id) }
        leaving.removeAll()
        for (id, actor) in view.actors where actor.traveling || joining.contains(id) {
            actor.cancelOnce()
        }
        joining.removeAll()
        queue = ChoreographyQueue()
        if let next = queue.submit(latest) { run(next, snap: true) }
    }

    // MARK: - Per tick

    /// Called after every tick's step. Critters waiting in the pile set off when their turn
    /// comes; a Critter takes its pile row on the very tick its seat is applied (covering
    /// whoever sat there), and a finished collapse switches to the still pile once no seated
    /// Critter has dust in the air.
    func didStep() {
        for index in departures.indices { departures[index].ticksLeft -= 1 }
        launchDue()
        for (id, row) in arriving {
            let seat = PileSeating.seat(row: row)
            guard let actor = view.actors[id] else {
                arriving[id] = nil
                continue
            }
            if actor.alpha == seat.alpha && actor.z == seat.z { took(row: row, id: id) }
        }
        endCollapseIfSettled()
        let waiting = settlingDust
        settlingDust = []
        for job in waiting {
            if let actor = view.actors[job.id], !actor.hidden, !actor.particles.isEmpty {
                settlingDust.append(job)
            } else {
                job.group.leave()
            }
        }
    }

    /// Ticks until the next Critter waiting in the pile sets off (so the clock wakes for it).
    func ticksUntilCue() -> Int {
        departures.map(\.ticksLeft).min().map { max(1, $0) } ?? TickGrid.maxSleepTicks
    }

    /// The pet is being shown: a hide still sinking is called off, and sunk Critters come back
    /// up to their state's loop. (After `playAppear` there is no hide left to call off.)
    func surface() {
        if vanishGroup != nil {
            showHideGeneration += 1
            vanishGroup = nil
            for id in vanishing {
                view.actors[id]?.cancelOnce()
                view.actors[id]?.releaseUnderground()
            }
            vanishing.removeAll()
            settle()
        }
        for id in sunk where !leaving.contains(id) {
            view.actors[id]?.releaseUnderground()
        }
        sunk = sunk.filter { leaving.contains($0) }
    }

    // MARK: - Running

    private func run(_ item: FlockRequest, snap forceSnap: Bool = false) {
        generation += 1
        let gen = generation
        let transition = forceSnap || !view.isRunning
            ? FlockTransition.snap
            : FlockTransition.between(FlockStructure(view.presentation), FlockStructure(item.presentation))
        let kind = Self.name(transition)
        runningKind = kind
        DiagnosticLog.shared.log("choreo \(kind) start")
        let done: () -> Void = { [weak self] in self?.finish(gen) }

        switch transition {
        case .update, .reorder:
            if case .merged = item.presentation {
                snap(item, done)
            } else {
                rearrange(item, added: [], gen: gen, done)
            }
        case .expand:
            expand(item, gen: gen, done)
        case .collapse:
            collapse(item, gen: gen, done)
        case .join(let added):
            rearrange(item, added: added, gen: gen, done)
        case .leave(let removed):
            leave(removed, gen: gen) { [weak self] in _ = self?.rearrange(item, added: [], gen: gen, done) }
        case .leaveThenJoin(let removed, let added):
            leave(removed, gen: gen) { [weak self] in _ = self?.rearrange(item, added: added, gen: gen, done) }
        case .reuse(let from, let to):
            reuse(item, from: from, to: to, done)
        case .snap:
            snap(item, done)
        }
    }

    private func finish(_ gen: Int) {
        guard gen == generation, let kind = runningKind else { return }
        runningKind = nil
        DiagnosticLog.shared.log("choreo \(kind) end")
        if let next = queue.finish() { run(next) }
    }

    private static func name(_ transition: FlockTransition) -> String {
        switch transition {
        case .update: "update"
        case .expand: "expand"
        case .collapse: "collapse"
        case .join: "join"
        case .leave: "leave"
        case .leaveThenJoin: "leaveThenJoin"
        case .reorder: "reorder"
        case .reuse: "reuse"
        case .snap: "snap"
        }
    }

    /// A job group whose completion runs after the current tick/batch, and only while
    /// choreography `gen` is still the current one.
    private func makeGroup(_ gen: Int, _ done: @escaping () -> Void) -> JobGroup {
        JobGroup { [weak self] in
            self?.view.deferWork {
                guard let self, gen == self.generation else { return }
                done()
            }
        }
    }

    // MARK: - Stage helpers

    /// Creates the Critters `item` needs (quietly, hidden until placed) and drops the ones it
    /// doesn't (leaving ones excepted: they go when their goodbye ends).
    private func cast(_ item: FlockRequest) {
        let ids = item.ids
        view.ensureActors(ids, hidden: true)
        let keep = Set(ids)
        for id in view.actors.keys where !keep.contains(id) && !leaving.contains(id) {
            view.removeActor(id)
        }
    }

    /// Moves the window for `item` and lays the view out for it; returns how far to shift
    /// coordinates taken before the move so they still mean the same spot on screen.
    private func moveWindow(_ item: FlockRequest) -> CGVector {
        let before = view.window?.frame.origin ?? .zero
        item.place()
        let after = view.window?.frame.origin ?? .zero
        view.adopt(item.presentation, layout: item.layout)
        if case .empty = item.presentation {} else { hasShownSessions = true }
        return CGVector(dx: before.x - after.x, dy: before.y - after.y)
    }

    private func seat(_ actor: MotionActor, row: Int) {
        actor.setLoop(clip: [ClipKey(pose: view.skin.interactions.land, ticks: 9999, dx: 0, dy: row)], name: nil)
        let seat = PileSeating.seat(row: row)
        actor.tint = .dim
        actor.alpha = seat.alpha
        actor.z = seat.z
        actor.brainEnabled = false
    }

    private func unseatAll() {
        for id in seatRows.keys {
            view.actors[id]?.unseat()
            view.actors[id]?.brainEnabled = true
            view.setSeatRow(id, nil)
        }
        seatRows.removeAll()
        seatOccupants.removeAll()
        arriving.removeAll()
        departures.removeAll()
    }

    /// `id` has sunk into the ground (goodbye or hide), where its hold keeps it until shown
    /// again; `group`'s job ends once its poof has faded.
    private func stayUnderground(_ id: String, _ actor: MotionActor, then group: JobGroup) {
        sunk.insert(id)
        if actor.particles.isEmpty || actor.hidden {
            group.leave()
        } else {
            settlingDust.append((id, group))
        }
    }

    /// Hops `id` from `from` (view coordinates, after any window move) to `to`, raised `raise`
    /// cells at the start, after `delay` ticks. With `reveal`, its bubble and tag fade back in
    /// on landing. A hop cut short by a state change counts as arrived.
    private func hop(_ id: String, from: CGPoint, to: CGPoint, raise: Int = 0, delay: Int, seat: Seat? = nil,
                     reveal: Bool, group: JobGroup, landed: (() -> Void)? = nil) {
        guard let actor = view.actors[id] else { return }
        let u = view.unit
        view.setGroundOrigin(id, to)
        view.hold([id])
        group.enter()
        let gen = generation
        actor.travel(
            fromDx: jsRound((from.x - to.x) / u), fromDy: jsRound((from.y - to.y) / u) + raise,
            delay: delay, hopLength: Self.hopLength, seat: seat
        ) { [weak self] _ in
            if let self, gen == self.generation {
                landed?()
                if reveal { self.view.release(id, fade: true) }
            }
            group.leave()
        }
    }

    /// Nearest first: `distance` per id, ties in the given order.
    private func departureOrder<T>(_ items: [T], distance: (T) -> CGFloat) -> [T] {
        items.enumerated()
            .sorted { (distance($0.element), $0.offset) < (distance($1.element), $1.offset) }
            .map(\.element)
    }

    // MARK: - Choreographies

    /// No animation: the window and every Critter go straight to the new layout.
    private func snap(_ item: FlockRequest, _ done: @escaping () -> Void) {
        cast(item)
        unseatAll()
        _ = moveWindow(item)
        view.placeAtRest()
        view.releaseAll(fade: false)
        done()
    }

    /// The single Critter of one presentation becomes the single Critter of the other (empty ↔
    /// one session), taking the new state on the spot.
    private func reuse(_ item: FlockRequest, from: String, to: String, _ done: @escaping () -> Void) {
        view.rekey(from: from, to: to)
        if let actor = view.actors[to] {
            let session = view.session(to)
            actor.setActivity(session?.activity)
            let state = session?.state ?? .idle
            if actor.state != state { actor.enterState(state, quiet: !hasShownSessions) }
        }
        snap(item, done)
    }

    /// The window moves first; Critters whose column moved hop there from where they stood
    /// (nearest first), newcomers peek up in their own column. Covers join, the second half of
    /// leave, reorders and state-only updates (where usually nothing moves).
    private func rearrange(_ item: FlockRequest, added: [String], gen: Int, _ done: @escaping () -> Void) {
        let newcomers = Set(added)
        var before: [String: CGPoint] = [:]
        for id in view.actors.keys where !newcomers.contains(id) {
            before[id] = view.groundOrigin(id)
        }
        cast(item)
        view.hold(newcomers)
        let shift = moveWindow(item)
        let u = view.unit

        var moves: [(id: String, from: CGPoint, to: CGPoint)] = []
        for slot in item.layout.slots {
            guard let actor = view.actors[slot.id] else { continue }
            let to = slot.critter.origin
            actor.hidden = view.restHidden(slot.id)
            actor.noAccessory = false
            guard !newcomers.contains(slot.id), let old = before[slot.id] else {
                view.setGroundOrigin(slot.id, to)
                continue
            }
            let from = CGPoint(x: old.x + shift.dx, y: old.y + shift.dy)
            if jsRound((from.x - to.x) / u) == 0 && jsRound((from.y - to.y) / u) == 0 {
                view.setGroundOrigin(slot.id, to)
            } else {
                moves.append((slot.id, from, to))
            }
        }

        let group = makeGroup(gen) { [weak self] in
            self?.view.releaseChrome(fade: true)
            done()
        }
        if !moves.isEmpty || !newcomers.isEmpty { view.holdChrome() }
        let order = departureOrder(moves) { abs($0.from.x - $0.to.x) }
        for (k, move) in order.enumerated() {
            hop(move.id, from: move.from, to: move.to, delay: Self.stagger * k, reveal: true, group: group)
        }
        for id in added {
            join(id, gen: gen, group: group)
        }
        group.seal()
    }

    private func join(_ id: String, gen: Int, group: JobGroup) {
        guard let actor = view.actors[id] else { return }
        joining.insert(id)
        actor.noAccessory = true
        group.enter()
        let arrived: (Bool) -> Void = { [weak self, weak actor] _ in
            if let self, gen == self.generation {
                self.joining.remove(id)
                actor?.noAccessory = false
                self.view.release(id, fade: true)
            }
            group.leave()
        }
        if view.reduceMotion {
            arrived(true)
        } else {
            actor.play(view.skin.interactions.join, completion: arrived)
        }
    }

    /// The window stays; each removed Critter waves and sinks, then is gone.
    private func leave(_ removed: [String], gen: Int, then: @escaping () -> Void) {
        let ids = removed.filter { view.actors[$0] != nil }
        leaving.formUnion(ids)
        view.hold(ids)
        view.holdChrome()
        let group = makeGroup(gen) { [weak self] in
            guard let self else { return }
            for id in ids { self.view.removeActor(id) }
            then()
        }
        for id in ids {
            guard let actor = view.actors[id] else { continue }
            actor.noAccessory = true
            actor.holdUnderground(depth: Self.underground)
            group.enter()
            let gone: (Bool) -> Void = { [weak self, weak actor] _ in
                guard let self, let actor else { return group.leave() }
                self.stayUnderground(id, actor, then: group)
            }
            if view.reduceMotion {
                gone(true)
            } else {
                actor.play(view.skin.interactions.leave, completion: gone)
            }
        }
        group.seal()
    }

    /// Pile → row. The window moves first; then every Critter hops from its pile seat (the lead
    /// from the front, the others from row nb, nb − 1, … in departure order) to its column,
    /// nearest first, `stagger` ticks apart. Until its own turn each seated Critter looks exactly
    /// like the still back row it replaces (dimmed, no shadow, one per row: the next one in a
    /// row shows when the one in front of it leaves).
    private func expand(_ item: FlockRequest, gen: Int, _ done: @escaping () -> Void) {
        guard case .merged(let oldLead, _, _) = view.presentation,
              let oldFront = view.layoutResult.slots.first?.critter.origin
        else { return snap(item, done) }
        cast(item)
        unseatAll()
        view.hold(item.layout.slots.map(\.id))
        view.holdChrome()
        let shift = moveWindow(item)
        let pile = CGPoint(x: oldFront.x + shift.dx, y: oldFront.y + shift.dy)
        let u = view.unit

        let order = departureOrder(item.layout.slots) { abs($0.critter.minX - pile.x) }
        let rows = PileSeating.seats(departureOrder: order.map(\.id), lead: oldLead.id, total: order.count)
        let group = makeGroup(gen) { [weak self] in
            self?.view.actors[oldLead.id]?.z = 2
            self?.view.releaseChrome(fade: true)
            done()
        }
        var shownRows: Set<Int> = []
        for (k, slot) in order.enumerated() {
            guard let actor = view.actors[slot.id] else { continue }
            let row = slot.id == oldLead.id ? 0 : rows[slot.id] ?? 1
            let spot = CGPoint(x: pile.x + CGFloat(4 * row) * u, y: pile.y)
            view.setGroundOrigin(slot.id, spot)
            if row == 0 {
                actor.z = 3
                actor.hidden = view.restHidden(slot.id)
            } else {
                actor.cancelOnce()
                seat(actor, row: row)
                seatRows[slot.id] = row
                view.setSeatRow(slot.id, row)
                actor.noAccessory = true
                actor.hidden = shownRows.contains(row) || view.restHidden(slot.id)
                shownRows.insert(row)
            }
            group.enter()
            departures.append(Departure(
                id: slot.id, ticksLeft: view.reduceMotion ? 0 : Self.stagger * k, row: row,
                from: spot, to: slot.critter.origin, group: group, gen: gen
            ))
        }
        launchDue()
        group.seal()
    }

    /// Starts every departure whose wait is over, in departure order.
    private func launchDue() {
        while let index = departures.firstIndex(where: { $0.ticksLeft <= 0 }) {
            takeOff(departures.remove(at: index))
        }
    }

    /// `departure`'s Critter leaves its seat: back to its own look and loop, and hop.
    private func takeOff(_ departure: Departure) {
        let id = departure.id
        guard departure.gen == generation, let actor = view.actors[id] else { return departure.group.leave() }
        if seatRows.removeValue(forKey: id) != nil {
            actor.unseat()
            actor.brainEnabled = true
            view.setSeatRow(id, nil)
        }
        actor.noAccessory = false
        actor.hidden = view.restHidden(id)
        // The next Critter waiting in this back row now shows in its place.
        if departure.row > 0, let next = departures.first(where: { $0.row == departure.row }) {
            view.actors[next.id]?.hidden = view.restHidden(next.id)
        }
        hop(id, from: departure.from, to: departure.to, raise: departure.row, delay: 0, reveal: true,
            group: departure.group)
        departure.group.leave()
    }

    /// Row → pile. The window stays until everyone is seated: nearest first, the lead hops to
    /// the front, the others take the back rows (the first home sits farthest back; a later
    /// arrival in the same row covers the earlier one). Then the window moves, and the still
    /// pile takes the seated Critters' place, pixel for pixel.
    private func collapse(_ item: FlockRequest, gen: Int, _ done: @escaping () -> Void) {
        guard case .merged(let lead, _, let total) = item.presentation,
              let mergedFront = item.layout.slots.first?.critter.origin
        else { return snap(item, done) }
        // Where the pile will stand, in today's window: its spot in the window `place` will
        // set (anchored, and kept on screen like it), so the still pile takes over in place.
        let old = view.layoutResult
        let now = view.window?.frame.origin ?? .zero
        let then = item.frame().origin
        let pile = CGPoint(x: mergedFront.x + then.x - now.x, y: mergedFront.y + then.y - now.y)
        let u = view.unit

        let keep = Set(item.ids)
        let movers: [(id: String, from: CGPoint)] = old.slots.compactMap { slot in
            guard keep.contains(slot.id), let origin = view.groundOrigin(slot.id) else { return nil }
            return (slot.id, origin)
        }
        cast(item)
        unseatAll()
        view.hold(Set(view.actors.keys).union(old.slots.map(\.id)))
        view.holdChrome()

        let order = departureOrder(movers) { abs($0.from.x - pile.x) }
        let rows = PileSeating.seats(departureOrder: order.map(\.id), lead: lead.id, total: total)
        let group = makeGroup(gen) { [weak self] in
            self?.pendingCollapseEnd = { [weak self] in self?.endCollapse(item, done) }
            self?.endCollapseIfSettled()
        }
        for (k, mover) in order.enumerated() {
            guard let actor = view.actors[mover.id] else { continue }
            actor.noAccessory = true
            if mover.id == lead.id {
                actor.z = 3
                hop(mover.id, from: mover.from, to: pile, delay: Self.stagger * k, reveal: false, group: group)
                continue
            }
            let row = rows[mover.id] ?? 1
            seatRows[mover.id] = row
            arriving[mover.id] = row
            actor.brainEnabled = false
            view.setSeatRow(mover.id, row)
            hop(mover.id, from: mover.from, to: CGPoint(x: pile.x + CGFloat(4 * row) * u, y: pile.y),
                delay: Self.stagger * k, seat: PileSeating.seat(row: row), reveal: false, group: group) { [weak self] in
                self?.took(row: row, id: mover.id)
            }
        }
        // A lead that wasn't in the row (it just arrived) stands in front from the start.
        if !movers.contains(where: { $0.id == lead.id }), let actor = view.actors[lead.id] {
            actor.hidden = false
            actor.noAccessory = true
            actor.z = 3
            view.setGroundOrigin(lead.id, pile)
        }
        group.seal()
    }

    private func took(row: Int, id: String) {
        arriving[id] = nil
        guard seatOccupants[row] != id else { return }
        if let earlier = seatOccupants[row] {
            view.actors[earlier]?.hidden = true
        }
        seatOccupants[row] = id
    }

    private func endCollapseIfSettled() {
        guard let end = pendingCollapseEnd else { return }
        let dusty = seatRows.keys.contains { id in
            guard let actor = view.actors[id] else { return false }
            return !actor.hidden && !actor.particles.isEmpty
        }
        guard !dusty else { return }
        pendingCollapseEnd = nil
        end()
    }

    private func endCollapse(_ item: FlockRequest, _ done: @escaping () -> Void) {
        unseatAll()
        _ = moveWindow(item)
        view.placeAtRest()
        view.releaseAll(fade: true)
        done()
    }

    // MARK: - Show / hide

    /// Each Critter seen at rest drops in from above, `appearStagger` after the previous one
    /// (the others wait hidden). Any choreography is settled first.
    func playAppear() {
        showHideGeneration += 1
        let generation = showHideGeneration
        vanishGroup = nil
        // Called off mid-sink: back up (hidden until each drops in). The sunk ones come back
        // up in `surface`.
        for id in vanishing { view.actors[id]?.releaseUnderground() }
        vanishing.removeAll()
        settle()
        view.concealed = []
        let ids = view.restVisibleIds()
        view.concealed = Set(ids)
        for id in ids { view.actors[id]?.hidden = true }
        for (index, id) in ids.enumerated() {
            guard index > 0 else {
                dropIn(id, generation: generation)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.appearStagger * Double(index)) { [weak self] in
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated { self?.dropIn(id, generation: generation) }
            }
        }
    }

    private func dropIn(_ id: String, generation: Int) {
        guard generation == showHideGeneration else { return }
        view.batch {
            view.concealed.remove(id)
            guard let actor = view.actors[id] else { return }
            actor.hidden = view.restHidden(id)
            if !view.reduceMotion { actor.play(view.skin.interactions.appear) }
        }
        view.requestRender()
    }

    /// Each visible Critter sinks into the ground, `vanishStagger` after the previous one, and
    /// stays hidden; then `completion` (unless a later show/hide superseded this one). Any
    /// choreography is settled first.
    func playVanish(completion: @escaping () -> Void) {
        showHideGeneration += 1
        let generation = showHideGeneration
        settle()
        view.concealed = []
        let group = JobGroup { [weak self] in
            self?.view.deferWork {
                guard let self, generation == self.showHideGeneration else { return }
                self.vanishGroup = nil
                completion()
            }
        }
        vanishGroup = group
        holdForHide()
        let ids = view.restVisibleIds().filter { view.actors[$0]?.hidden == false }
        for (index, id) in ids.enumerated() {
            group.enter()
            guard index > 0 else {
                sinkOut(id, generation: generation)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.vanishStagger * Double(index)) { [weak self] in
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated { self?.sinkOut(id, generation: generation) }
            }
        }
        group.seal()
    }

    /// Keeps the queue busy while the hide plays, so no expand, join, leave… runs on top of
    /// sinking Critters; requests wait as `latest`, and whatever ends the hide (the panel going
    /// away, a show) settles to it.
    private func holdForHide() {
        guard let latest, queue.submit(latest) != nil else { return }
        runningKind = "hide"
        DiagnosticLog.shared.log("choreo hide start")
    }

    private func sinkOut(_ id: String, generation: Int) {
        guard generation == showHideGeneration, let group = vanishGroup else { return }
        view.batch {
            guard let actor = view.actors[id] else { return group.leave() }
            let gone: (Bool) -> Void = { [weak self, weak actor] _ in
                guard let self, let actor, generation == self.showHideGeneration else { return group.leave() }
                self.vanishing.remove(id)
                self.stayUnderground(id, actor, then: group)
            }
            actor.holdUnderground(depth: Self.underground)
            if view.reduceMotion {
                gone(true)
            } else {
                vanishing.insert(id)
                actor.play(view.skin.interactions.vanish, completion: gone)
            }
        }
        view.requestRender()
    }
}

/// Counts outstanding jobs (hops, peeks, goodbyes, sinks): `done` runs once, when every
/// `enter` has been matched by a `leave` and the group has been sealed.
final class JobGroup {
    private var count = 1
    private var done: (() -> Void)?

    init(_ done: @escaping () -> Void) {
        self.done = done
    }

    func enter() {
        count += 1
    }

    func leave() {
        guard count > 0 else { return }
        count -= 1
        guard count == 0, let done else { return }
        self.done = nil
        done()
    }

    /// No more jobs will be added.
    func seal() {
        leave()
    }
}
