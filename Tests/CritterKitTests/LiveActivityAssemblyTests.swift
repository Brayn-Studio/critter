import Foundation
import Testing
@testable import CritterKit

// The Live Activity content of a snapshot: the one rule the Mac (`LiveActivityPlanner`) and the phone
// (`LocalActivity`) share.

private func session(_ id: String, _ state: PetState, skin: String = "sprig", startedAt: Int64 = 1, name: String = "name") -> BridgeSession {
    BridgeSession(
        id: id, name: name, source: .terminal, state: state, detail: "detail of \(id)", activity: "activity", cwd: "/p/\(id)",
        branch: "main", skin: skin, eventTime: 5, startedAt: startedAt, tracked: true
    )
}

private func snapshot(_ sessions: [BridgeSession], fiveHour: Double? = nil, sevenDay: Double? = nil) -> SnapshotBody {
    let limits = (fiveHour == nil && sevenDay == nil) ? nil : BridgeLimits(
        fiveHour: fiveHour.map { RateWindow(usedPercentage: $0, resetsAt: 9) },
        sevenDay: sevenDay.map { RateWindow(usedPercentage: $0, resetsAt: 9) }, updatedAt: 1
    )
    return SnapshotBody(
        sessions: sessions, limits: limits, pending: [],
        prefs: BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 1.0, mergeThreshold: 4, soundTheme: "pixel")
    )
}

@Test func aSnapshotsContentLeadsWithTheMostUrgentAndKeepsTwoBehind() {
    let content = LiveActivityContent(snapshot: snapshot([
        session("a", .running, skin: "run1", startedAt: 10),
        session("b", .done, skin: "done1", startedAt: 20),
        session("c", .waiting, skin: "late", startedAt: 300),
        session("d", .waiting, skin: "early", startedAt: 100),
        session("e", .error, skin: "err1", startedAt: 40),
        session("f", .idle, skin: "idle1", startedAt: 50),
    ], fiveHour: 41.6, sevenDay: 7.4), updatedAt: 77)
    #expect(content.lead == PetBadge(skin: "early", state: .waiting))
    #expect(content.back == [PetBadge(skin: "late", state: .waiting), PetBadge(skin: "err1", state: .error)])
    #expect(content.total == 6 && content.updatedAt == 77)
    #expect(content.counts == [
        StateCount(state: .waiting, count: 2), StateCount(state: .error, count: 1), StateCount(state: .done, count: 1),
        StateCount(state: .running, count: 1), StateCount(state: .idle, count: 1),
    ])
    #expect(content.fiveHour == 42 && content.sevenDay == 7)
}

@Test func aSnapshotsContentBreaksTiesByIdAndHasNoText() throws {
    let content = LiveActivityContent(snapshot: snapshot([
        session("z", .running, skin: "mint", startedAt: 5, name: "Secret Name"),
        session("y", .running, skin: "sprig", startedAt: 5, name: "Secret Folder"),
    ], fiveHour: 150, sevenDay: .nan), updatedAt: 0)
    #expect(content.lead?.skin == "sprig" && content.back.map(\.skin) == ["mint"])
    #expect(content.fiveHour == 100 && content.sevenDay == nil)
    let text = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
    #expect(!text.contains("Secret") && !text.contains("/p/"))
}

@Test func anEmptySnapshotsContentIsEmpty() {
    let content = LiveActivityContent(snapshot: snapshot([]), updatedAt: 3)
    #expect(content == LiveActivityContent(counts: [], lead: nil, back: [], total: 0, fiveHour: nil, sevenDay: nil, updatedAt: 3))
}
