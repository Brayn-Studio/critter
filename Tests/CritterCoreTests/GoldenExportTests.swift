import Foundation
import Testing
@testable import CritterCore

/// Golden snapshots for the Android port of the motion engine (android/core, `GoldenTest`).
///
/// Each scenario drives one `MotionActor` with a fixed seed through a list of timed ops and
/// records, tick by tick, the snapshot and `ticksUntilChange` -- only on the ticks where either
/// differs from the one before. The Kotlin port replays the same ops and must match at every
/// tick. Files are written only when `CRITTER_EXPORT_GOLDEN=<directory>` is set; otherwise the
/// scenarios just have to run to the end.
///
///     CRITTER_EXPORT_GOLDEN=$PWD/android/core/src/test/resources/golden swift test --filter GoldenExportTests
private struct Scenario {
    var name: String
    var skin: String
    var seed: UInt64
    var reduceMotion = false
    var ticks: Int
    var ops: [[String: Any]]
}

private func op(_ at: Int, _ name: String, _ args: [String: Any] = [:]) -> [String: Any] {
    var o = args
    o["at"] = at
    o["op"] = name
    return o
}

/// The same state tour for the state scenarios: 300 ticks each.
private func stateTour(activity: String) -> [[String: Any]] {
    [
        op(300, "enterState", ["state": "running", "quiet": false]),
        op(600, "setActivity", ["activity": activity]),
        op(900, "enterState", ["state": "waiting", "quiet": false]),
        op(1200, "enterState", ["state": "done", "quiet": false]),
        op(1500, "enterState", ["state": "error", "quiet": false]),
    ]
}

private func scenarios() throws -> [Scenario] {
    let mochi = try bundledSkin("mochi").interactions
    let sprig = try bundledSkin("sprig").interactions
    return [
        // Fidgets, dozing off at tick 2000, sleeping, then waking.
        Scenario(name: "sprig-idle-2400", skin: "sprig", seed: 1, ticks: 2400, ops: [op(2200, "wake")]),
        Scenario(name: "bristle-states", skin: "bristle", seed: 2, ticks: 1800, ops: stateTour(activity: "read")),
        Scenario(name: "sprig-running-variants", skin: "sprig", seed: 3, ticks: 600, ops: [
            op(0, "setActivity", ["activity": "think"]),
            op(0, "enterState", ["state": "running", "quiet": false]),
            op(200, "setActivity", ["activity": "bash"]),
            op(400, "setActivity", ["activity": "juggle"]),
        ]),
        Scenario(name: "mochi-interactions", skin: "mochi", seed: 4, ticks: 360, ops: [
            op(40, "play", ["clip": mochi.notice]),
            op(80, "setMode", ["mode": mochi.press]),
            op(120, "setMode", ["mode": NSNull()]),
            op(120, "play", ["clip": mochi.boopEnd]),
            op(160, "setMode", ["mode": mochi.held]),
            op(160, "setLift", ["value": 3]),
            op(160, "setLag", ["value": 2]),
            op(180, "setLag", ["value": -1]),
            op(200, "setMode", ["mode": NSNull()]),
            op(200, "setLift", ["value": 0]),
            op(200, "setLag", ["value": 0]),
            op(200, "play", ["clip": mochi.drop]),
            op(240, "setMode", ["mode": mochi.pet]),
            op(280, "setMode", ["mode": NSNull()]),
            op(280, "play", ["clip": mochi.petEnd]),
        ]),
        Scenario(name: "peep-reduced-motion", skin: "peep", seed: 5, reduceMotion: true, ticks: 1800,
                 ops: stateTour(activity: "think")),
        // Beyond the five required scenarios: hops, follow, pile seat, gaze, under ground, hidden
        // and toggling reduced motion mid-run.
        Scenario(name: "sprig-travel-follow", skin: "sprig", seed: 6, ticks: 700, ops: [
            op(0, "enterState", ["state": "done", "quiet": false]),
            op(20, "travel", ["fromDx": 20, "fromDy": 0, "delay": 0]),
            op(100, "startFollow", ["lookLeft": true]),
            op(110, "followShift", ["dx": 6.0, "dy": 0.0]),
            op(130, "followShift", ["dx": -3.0, "dy": 2.0]),
            op(160, "releaseFollow"),
            op(200, "travel", ["fromDx": -20, "fromDy": 0, "delay": 4, "seatRow": 2]),
            op(260, "unseat"),
            op(300, "setGaze", ["zone": "left"]),
            op(340, "setGaze", ["zone": NSNull()]),
            op(360, "holdUnderground", ["depth": 12]),
            op(380, "play", ["clip": sprig.vanish]),
            op(440, "enterState", ["state": "waiting", "quiet": false]),
            op(460, "releaseUnderground"),
            op(480, "play", ["clip": sprig.appear]),
            op(520, "setHidden", ["value": true]),
            op(560, "setHidden", ["value": false]),
            op(600, "setReduceMotion", ["value": true]),
            op(640, "setReduceMotion", ["value": false]),
        ]),
    ]
}

private func state(_ name: Any?) -> PetState { PetState(rawValue: name as! String)! }

private func zone(_ name: Any?) -> GazeZone? {
    switch name as? String {
    case "left": .left
    case "right": .right
    case "up": .up
    case "down": .down
    case "center": .center
    default: nil
    }
}

private func apply(_ o: [String: Any], to a: MotionActor) {
    switch o["op"] as! String {
    case "enterState": a.enterState(state(o["state"]), quiet: o["quiet"] as! Bool)
    case "setActivity": a.setActivity(o["activity"] as? String)
    case "wake": a.wake()
    case "play": a.play(o["clip"] as! String)
    case "setMode": a.setMode(o["mode"] as? String)
    case "cancelOnce": a.cancelOnce()
    case "setLift": a.lift = o["value"] as! Int
    case "setLag": a.lag = o["value"] as! Int
    case "setGaze": a.setGaze(zone(o["zone"]))
    case "startFollow": a.startFollow(lookLeft: o["lookLeft"] as! Bool)
    case "followShift": a.followShift(dx: o["dx"] as! Double, dy: o["dy"] as! Double)
    case "releaseFollow": a.releaseFollow()
    case "travel":
        a.travel(fromDx: o["fromDx"] as! Int, fromDy: o["fromDy"] as! Int, delay: o["delay"] as! Int,
                 seat: (o["seatRow"] as? Int).map { PileSeating.seat(row: $0) })
    case "unseat": a.unseat()
    case "holdUnderground": a.holdUnderground(depth: o["depth"] as! Int)
    case "releaseUnderground": a.releaseUnderground()
    case "setHidden": a.hidden = o["value"] as! Bool
    case "setNoAccessory": a.noAccessory = o["value"] as! Bool
    case "setReduceMotion": a.reduceMotion = o["value"] as! Bool
    default: Issue.record("unknown op \(o["op"] ?? "nil")")
    }
}

private func json(_ g: GlyphDraw?) -> Any {
    guard let g else { return NSNull() }
    return ["glyph": g.glyph, "color": g.color, "x": g.x, "y": g.y, "alpha": g.alpha] as [String: Any]
}

private func json(_ s: ActorSnapshot) -> [String: Any] {
    [
        "hidden": s.hidden, "pose": s.pose, "bodyX": s.bodyX, "bodyY": s.bodyY,
        "offsetX": s.offsetX, "offsetY": s.offsetY,
        "tint": s.tint.map { $0.rawValue as Any } ?? NSNull(),
        "alpha": s.alpha, "z": s.z, "shadowWidth": s.shadowWidth,
        "accessory": json(s.accessory), "badge": json(s.badge),
        "particles": s.particles.map { json($0) }, "props": s.props.map { json($0) },
    ]
}

/// Runs the scenario and returns its JSON document.
private func run(_ sc: Scenario) throws -> (document: [String: Any], recorded: Int) {
    let actor = MotionActor(skin: try bundledSkin(sc.skin), rng: MotionRNG(seed: sc.seed), reduceMotion: sc.reduceMotion)
    var frames: [[String: Any]] = []
    var last: (snapshot: ActorSnapshot, until: Int)?
    for tick in 0..<sc.ticks {
        for o in sc.ops where o["at"] as! Int == tick { apply(o, to: actor) }
        let snapshot = actor.snapshot(), until = actor.ticksUntilChange()
        if last == nil || last!.snapshot != snapshot || last!.until != until {
            frames.append(["tick": tick, "snapshot": json(snapshot), "ticksUntilChange": until])
            last = (snapshot, until)
        }
        actor.step()
    }
    let document: [String: Any] = [
        "name": sc.name, "skin": sc.skin, "seed": sc.seed, "reduceMotion": sc.reduceMotion,
        "ticks": sc.ticks, "ops": sc.ops, "frames": frames,
    ]
    return (document, frames.count)
}

@Test func goldenScenariosRunAndExportWhenAsked() throws {
    let dir = ProcessInfo.processInfo.environment["CRITTER_EXPORT_GOLDEN"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    for sc in try scenarios() {
        let (document, recorded) = try run(sc)
        #expect(recorded > 1, "\(sc.name) never changes")
        if let dir {
            let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try data.write(to: dir.appendingPathComponent("\(sc.name).json"))
        }
    }
}
