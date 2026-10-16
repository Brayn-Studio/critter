import CoreGraphics
import Testing
@testable import ClawdCore

private func s(_ id: String, state: PetState) -> PetSession {
    PetSession(
        id: id, name: "name-\(id)", source: .terminal, state: state, detail: "detail \(id)", cwd: "/x", pid: nil,
        transcriptPath: nil, tracked: true, eventTime: 1, sortKey: Int64(id) ?? 0
    )
}

private func allPresentations() -> [FlockPresentation] {
    let four = (0..<4).map { s("\($0)", state: [.waiting, .done, .running, .idle][$0]) }
    let five = (0..<5).map { s("\($0)", state: [.waiting, .done, .running, .running, .idle][$0]) }
    return [
        .empty,
        .expanded([s("0", state: .idle)], showCollapse: false),
        .expanded(four, showCollapse: true),
        FlockModel.present(five, threshold: 4, override: nil),
        .merged(lead: s("0", state: .idle), counts: [StateCount(state: .idle, count: 5)], total: 5),
        .merged(
            lead: s("0", state: .waiting),
            counts: PetState.allCases.map { StateCount(state: $0, count: 9) },
            total: 45
        ),
    ]
}

@Test func expandedSlotsNeverOverlap() {
    let sessions = (0..<4).map { s("\($0)", state: [.waiting, .done, .running, .idle][$0]) }
    let r = FlockLayout.layout(.expanded(sessions, showCollapse: true), metrics: .init(scale: 1))
    let rects = r.slots.flatMap { [$0.clawd, $0.tag] + ($0.bubble.map { [$0] } ?? []) }
    for (i, a) in rects.enumerated() { for b in rects[(i+1)...] { #expect(!a.intersects(b)) } }
    #expect(r.slots.filter { $0.bubble != nil }.count == 3)   // idle 没有气泡
    #expect(r.handle != nil)
}

@Test func clawdScalesLinearly() {
    let one = FlockLayout.layout(.empty, metrics: .init(scale: 1)).slots[0].clawd.size
    let two = FlockLayout.layout(.empty, metrics: .init(scale: 2)).slots[0].clawd.size
    #expect(one == CGSize(width: 54, height: 30)); #expect(two == CGSize(width: 108, height: 60))
}

@Test func everythingInsideBounds() {
    for scale in [0.5, 1, 1.5, 2] as [CGFloat] {
        for p in allPresentations() {
            let r = FlockLayout.layout(p, metrics: .init(scale: scale))
            let bounds = CGRect(origin: .zero, size: r.size)
            for rect in r.hitRects + r.slots.map(\.accessory) {
                #expect(bounds.contains(rect), "\(rect) escapes \(bounds) at scale \(scale) for \(p)")
            }
        }
    }
}

@Test func mergedHasChipsAndOneBubble() {
    let five = (0..<5).map { s("\($0)", state: $0 == 2 ? .waiting : .running) }
    let merged = FlockModel.present(five, threshold: 4, override: nil)
    let r = FlockLayout.layout(merged, metrics: .init(scale: 1))
    #expect(r.chips != nil)
    #expect(r.slots.count == 1)
    #expect(r.slots[0].id == "2")
    #expect(r.slots[0].bubble != nil)
    #expect(r.handle == nil)
    // The pile is wider than one Clawd: two more are stacked behind it, offset 12·scale each.
    #expect(r.slots[0].clawd.width == CGFloat(54 + 24))

    let idleLead = FlockLayout.layout(
        .merged(lead: s("0", state: .idle), counts: [StateCount(state: .idle, count: 5)], total: 5),
        metrics: .init(scale: 1)
    )
    #expect(idleLead.slots[0].bubble == nil)
    #expect(idleLead.chips != nil)
}

@Test func emptyIsOneIdleClawdWithoutBubble() {
    let r = FlockLayout.layout(.empty, metrics: .init(scale: 1))
    #expect(r.slots.count == 1)
    #expect(r.slots[0].bubble == nil)
    #expect(r.handle == nil && r.chips == nil)
}

@Test func columnWidthsAndBubbleRowAlignment() {
    let m = FlockLayout.Metrics(scale: 1)
    let sessions = (0..<4).map { s("\($0)", state: [.waiting, .done, .running, .idle][$0]) }
    let r = FlockLayout.layout(.expanded(sessions, showCollapse: true), metrics: m)
    // 3 bubble columns (132) + 1 bare column (54 + 12), gaps, the collapse handle, padding.
    let expectedWidth = m.padding * 2 + 132 * 3 + 66 + m.columnGap * 3 + m.columnGap + m.handleSize.width
    #expect(r.size.width == expectedWidth)
    // Every bubble's bottom edge sits on the same line, above every accessory row.
    let bubbleBottoms = Set(r.slots.compactMap { $0.bubble?.minY })
    #expect(bubbleBottoms.count == 1)
    let accessoryTop = r.slots.map(\.accessory.maxY).max()!
    #expect(bubbleBottoms.first! >= accessoryTop)
    // Columns run left to right in session order.
    #expect(r.slots.map(\.id) == ["0", "1", "2", "3"])
    #expect(zip(r.slots, r.slots.dropFirst()).allSatisfy { $0.clawd.maxX < $1.clawd.minX })
}

@Test func withoutBubblesTheWindowIsShorter() {
    let idle = FlockLayout.layout(.expanded([s("0", state: .idle)], showCollapse: false), metrics: .init(scale: 1))
    let busy = FlockLayout.layout(.expanded([s("0", state: .running)], showCollapse: false), metrics: .init(scale: 1))
    #expect(idle.size.height < busy.size.height)
    #expect(idle.handle == nil)
}

@Test func hitRectsCoverEveryInteractivePart() {
    let sessions = (0..<4).map { s("\($0)", state: [.waiting, .done, .running, .idle][$0]) }
    let r = FlockLayout.layout(.expanded(sessions, showCollapse: true), metrics: .init(scale: 1))
    for slot in r.slots {
        #expect(r.hitRects.contains(slot.clawd))
        #expect(r.hitRects.contains(slot.tag))
        if let bubble = slot.bubble { #expect(r.hitRects.contains(bubble)) }
    }
    #expect(r.hitRects.contains(r.handle!))
    // A point in the gap between two columns is not a hit (click-through).
    let gap = CGPoint(x: r.slots[0].bubble!.maxX + 5, y: r.slots[0].clawd.midY)
    #expect(!r.hitRects.contains { $0.contains(gap) })
}

@Test func mergedTagText() {
    #expect(FlockLayout.mergedTagText(total: 5) == "5 个会话 · 点击展开")
}

@Test func bareColumnWidensForItsTagUpToBubbleWidth() {
    func idle(_ name: String, tracked: Bool) -> PetSession {
        var session = s("0", state: .idle)
        session.name = name
        session.tracked = tracked
        return session
    }
    func tagWidth(_ session: PetSession) -> CGFloat {
        FlockLayout.layout(.expanded([session], showCollapse: false), metrics: .init(scale: 1)).slots[0].tag.width
    }
    #expect(FlockLayout.tagText(for: idle("robocup-81", tracked: false)) == "robocup-81·未接入")
    #expect(tagWidth(idle("api", tracked: true)) == CGFloat(54 + 12))           // short names: narrow column
    #expect(tagWidth(idle("robocup-81", tracked: false)) > CGFloat(54 + 12))    // room for "robocup-81·未接入"
    #expect(tagWidth(idle(String(repeating: "x", count: 80), tracked: true)) == CGFloat(132)) // capped
}

@Test func clickTargets() {
    let sessions = (0..<3).map { s("\($0)", state: [.waiting, .idle, .done][$0]) }
    let r = FlockLayout.layout(.expanded(sessions, showCollapse: true), metrics: .init(scale: 1))
    let first = r.slots[0], second = r.slots[1]
    #expect(r.target(at: CGPoint(x: first.clawd.midX, y: first.clawd.midY)) == .slot(0))
    #expect(r.target(at: CGPoint(x: first.bubble!.midX, y: first.bubble!.midY)) == .slot(0))
    #expect(r.target(at: CGPoint(x: second.tag.midX, y: second.tag.midY)) == .slot(1))
    #expect(r.target(at: CGPoint(x: r.handle!.midX, y: r.handle!.midY)) == .handle)
    // Above an idle Clawd (no bubble) is empty space: click-through, no target.
    #expect(r.target(at: CGPoint(x: second.clawd.midX, y: r.size.height - 10)) == nil)

    let merged = FlockLayout.layout(
        FlockModel.present((0..<5).map { s("\($0)", state: .running) }, threshold: 4, override: nil),
        metrics: .init(scale: 1)
    )
    #expect(merged.target(at: CGPoint(x: merged.chips!.midX, y: merged.chips!.midY)) == .chips)
    #expect(merged.target(at: CGPoint(x: merged.slots[0].clawd.midX, y: merged.slots[0].clawd.midY)) == .slot(0))
}
