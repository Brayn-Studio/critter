import CoreGraphics
import Testing
@testable import CritterCore

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
    let rects = r.slots.flatMap { [$0.critter, $0.tag] + ($0.bubble.map { [$0] } ?? []) }
    for (i, a) in rects.enumerated() { for b in rects[(i+1)...] { #expect(!a.intersects(b)) } }
    #expect(r.slots.filter { $0.bubble != nil }.count == 3)   // idle 没有气泡
    #expect(r.handle != nil)
}

@Test func critterScalesLinearly() {
    let one = FlockLayout.layout(.empty, metrics: .init(scale: 1)).slots[0].critter.size
    let two = FlockLayout.layout(.empty, metrics: .init(scale: 2)).slots[0].critter.size
    #expect(one == CGSize(width: 54, height: 30)); #expect(two == CGSize(width: 108, height: 60))
}

@Test func everythingInsideBounds() {
    for scale in [0.5, 1, 1.5, 2] as [CGFloat] {
        for p in allPresentations() {
            let r = FlockLayout.layout(p, metrics: .init(scale: scale))
            let bounds = CGRect(origin: .zero, size: r.size)
            for rect in r.hitRects + r.slots.map(\.accessory) {
                #expect(bounds.contains(rect), "\(rect) escapes \(bounds) at scale \(scale) for \(p)")
                #expect(r.content.contains(rect), "\(rect) escapes content \(r.content) at scale \(scale) for \(p)")
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
    // The pile is wider than one Critter: two more are stacked behind it, offset 12·scale each.
    #expect(r.slots[0].critter.width == CGFloat(54 + 24))
    #expect(FlockLayout.Metrics(scale: 1).pileStep == CGSize(width: 12, height: 3))

    let idleLead = FlockLayout.layout(
        .merged(lead: s("0", state: .idle), counts: [StateCount(state: .idle, count: 5)], total: 5),
        metrics: .init(scale: 1)
    )
    #expect(idleLead.slots[0].bubble == nil)
    #expect(idleLead.chips != nil)
}

@Test func emptyIsOneIdleCritterWithoutBubble() {
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
    #expect(r.content.width == expectedWidth)
    // Every bubble's bottom edge sits on the same line, above every accessory row.
    let bubbleBottoms = Set(r.slots.compactMap { $0.bubble?.minY })
    #expect(bubbleBottoms.count == 1)
    let accessoryTop = r.slots.map(\.accessory.maxY).max()!
    #expect(bubbleBottoms.first! >= accessoryTop)
    // Columns run left to right in session order.
    #expect(r.slots.map(\.id) == ["0", "1", "2", "3"])
    #expect(zip(r.slots, r.slots.dropFirst()).allSatisfy { $0.critter.maxX < $1.critter.minX })
}

@Test func withoutBubblesTheWindowIsShorter() {
    let idle = FlockLayout.layout(.expanded([s("0", state: .idle)], showCollapse: false), metrics: .init(scale: 1))
    let busy = FlockLayout.layout(.expanded([s("0", state: .running)], showCollapse: false), metrics: .init(scale: 1))
    #expect(idle.content.height < busy.content.height)
    #expect(idle.handle == nil)
}

@Test func hitRectsCoverEveryInteractivePart() {
    let sessions = (0..<4).map { s("\($0)", state: [.waiting, .done, .running, .idle][$0]) }
    let r = FlockLayout.layout(.expanded(sessions, showCollapse: true), metrics: .init(scale: 1))
    for slot in r.slots {
        #expect(r.hitRects.contains(slot.critter))
        #expect(r.hitRects.contains(slot.tag))
        if let bubble = slot.bubble { #expect(r.hitRects.contains(bubble)) }
    }
    #expect(r.hitRects.contains(r.handle!))
    // A point in the gap between two columns is not a hit (click-through).
    let gap = CGPoint(x: r.slots[0].bubble!.maxX + 5, y: r.slots[0].critter.midY)
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
    #expect(r.target(at: CGPoint(x: first.critter.midX, y: first.critter.midY)) == .slot(0))
    #expect(r.target(at: CGPoint(x: first.bubble!.midX, y: first.bubble!.midY)) == .slot(0))
    #expect(r.target(at: CGPoint(x: second.tag.midX, y: second.tag.midY)) == .slot(1))
    #expect(r.target(at: CGPoint(x: r.handle!.midX, y: r.handle!.midY)) == .handle)
    // Above an idle Critter (no bubble) is empty space: click-through, no target.
    #expect(r.target(at: CGPoint(x: second.critter.midX, y: r.content.maxY - 10)) == nil)

    let merged = FlockLayout.layout(
        FlockModel.present((0..<5).map { s("\($0)", state: .running) }, threshold: 4, override: nil),
        metrics: .init(scale: 1)
    )
    #expect(merged.target(at: CGPoint(x: merged.chips!.midX, y: merged.chips!.midY)) == .chips)
    #expect(merged.target(at: CGPoint(x: merged.slots[0].critter.midX, y: merged.slots[0].critter.midY)) == .slot(0))
}

/// F4: columns don't wrap, so on a 1440 pt display a flock of 11+ (threshold 10, or a manual
/// "展开") is wider than the screen -- and the "⇥ 收起" handle at its far end ends up out of
/// reach. Whatever is presented must keep the whole window, the handle and every hit target
/// inside the visible frame, whichever side the pet is anchored on.
@Test func flockAndItsHandleStayInsideTheVisibleFrame() {
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let metrics = FlockLayout.Metrics(scale: 1)
    let maxWidth = PositionModel.usableWidth(of: visible)
    for count in 2...24 {
        let sessions = (0..<count).map { s("\($0)", state: .running) } // bubbles: the widest columns
        for override in [nil, FlockOverride(merged: false, sessionCount: count)] {
            let presentation = FlockLayout.fitted(
                FlockModel.present(sessions, threshold: 10, override: override), metrics: metrics, maxWidth: maxWidth
            )
            let layout = FlockLayout.layout(presentation, metrics: metrics)
            for anchor in [PositionModel.defaultAnchor(visible: visible), Anchor(side: .left, x: 40, y: 60)] {
                let contentFrame = PositionModel.frame(size: layout.content.size, anchor: anchor, visible: visible)
                let frame = layout.windowFrame(contentFrame: contentFrame)
                func onScreen(_ rect: CGRect) -> Bool { visible.contains(rect.offsetBy(dx: frame.minX, dy: frame.minY)) }
                #expect(visible.contains(contentFrame), "count=\(count) override=\(String(describing: override))")
                if let handle = layout.handle {
                    #expect(onScreen(handle), "handle off screen: count=\(count)")
                }
                #expect(layout.hitRects.allSatisfy(onScreen), "count=\(count)")
            }
        }
    }
}

/// ... while a flock that fits stays expanded, handle and all.
@Test func fittingFlockStaysExpanded() {
    let sessions = (0..<5).map { s("\($0)", state: .running) }
    let expanded = FlockModel.present(sessions, threshold: 10, override: nil)
    let metrics = FlockLayout.Metrics(scale: 1)
    #expect(FlockLayout.fitted(expanded, metrics: metrics, maxWidth: 1432) == expanded)
    #expect(FlockLayout.layout(expanded, metrics: metrics).handle != nil)
    // Too narrow for it: merged, with the same lead and counts the automatic rule would pick.
    #expect(FlockLayout.fitted(expanded, metrics: metrics, maxWidth: 300) == FlockModel.present(sessions, threshold: 2, override: nil))
    // Merged and empty presentations are left alone.
    let merged = FlockModel.present(sessions, threshold: 2, override: nil)
    #expect(FlockLayout.fitted(merged, metrics: metrics, maxWidth: 10) == merged)
    #expect(FlockLayout.fitted(.empty, metrics: metrics, maxWidth: 10) == .empty)
}

@Test func metricsUseSquarePixelUnit() {
    let m = FlockLayout.Metrics(scale: 1)
    #expect(m.unit == 3)
    #expect(m.accessoryHeight == 24)
    #expect(m.pileStep == CGSize(width: 12, height: 3))
    #expect(FlockLayout.Metrics(scale: 2).accessoryHeight == 48)
    #expect(FlockLayout.Metrics(scale: 1, accessoryHeight: 5).accessoryHeight == 5)
    #expect(m.overscan == FlockLayout.Insets(top: 36, left: 36, bottom: 24, right: 36))
}

@Test func overscanSurroundsContent() {
    for p in allPresentations() {
        for scale in [1, 2] as [CGFloat] {
            let r = FlockLayout.layout(p, metrics: .init(scale: scale))
            #expect(r.size.width == r.content.width + 72 * scale)
            #expect(r.size.height == r.content.height + 60 * scale)
            #expect(r.content.origin == CGPoint(x: 36 * scale, y: 24 * scale))
        }
    }
}

@Test func everyRectLiesInsideContent() {
    for scale in [0.5, 1, 2] as [CGFloat] {
        for p in allPresentations() {
            let r = FlockLayout.layout(p, metrics: .init(scale: scale))
            let rects = r.hitRects + r.slots.flatMap { [$0.critter, $0.accessory, $0.tag] + ($0.bubble.map { [$0] } ?? []) }
                + (r.handle.map { [$0] } ?? []) + (r.chips.map { [$0] } ?? [])
            #expect(rects.allSatisfy(r.content.contains))
        }
    }
}

@Test func windowContentRoundTrip() {
    let r = FlockLayout.layout(.empty, metrics: .init(scale: 1))
    let content = CGRect(x: 500, y: 40, width: r.content.width, height: r.content.height)
    let window = r.windowFrame(contentFrame: content)
    #expect(window.size == r.size)
    #expect(window.origin == CGPoint(x: 464, y: 16))
    #expect(r.contentFrame(windowFrame: window) == content)
}

@Test func fittedComparesContentWidth() {
    let sessions = (0..<3).map { s("\($0)", state: .running) }
    let expanded = FlockModel.present(sessions, threshold: 10, override: nil)
    let m = FlockLayout.Metrics(scale: 1)
    let width = FlockLayout.layout(expanded, metrics: m).content.width
    #expect(FlockLayout.fitted(expanded, metrics: m, maxWidth: width) == expanded)
    #expect(FlockLayout.fitted(expanded, metrics: m, maxWidth: width - 1) != expanded)
}

@Test func mergedChipsKeepTheirHeightAtTheBottomOfTheAccessoryRow() {
    let five = (0..<5).map { s("\($0)", state: $0 == 2 ? .waiting : .running) }
    let merged = FlockModel.present(five, threshold: 4, override: nil)
    for scale in [1, 2] as [CGFloat] {
        let m = FlockLayout.Metrics(scale: scale)
        let r = FlockLayout.layout(merged, metrics: m)
        guard let chips = r.chips else {
            Issue.record("no chips at scale \(scale)")
            continue
        }
        #expect(chips.height == 14, "chips are \(chips.height) pt tall at scale \(scale)")
        // Bottom of the accessory row: just above the pile, like before the square-pixel rows.
        #expect(chips.minY == r.slots[0].critter.maxY + 2)
        #expect(m.accessoryHeight > chips.height)
    }
}

/// The flock is anchored by its content edge, so with whole-point content sizes every window
/// for a given anchor shares one fractional offset: AppKit's frame rounding then shifts the
/// expanded row and the merged pile alike, and a collapse's predicted pile position (aligned
/// on the anchored edge) is where the still pile really appears -- no sub-pixel jump.
@Test func contentSizesAreWholePoints() {
    for scale in [1, 1.25, 1.3, 1.75, 2] as [CGFloat] {
        for p in allPresentations() {
            let r = FlockLayout.layout(p, metrics: .init(scale: scale))
            #expect(r.content.width == r.content.width.rounded(.down), "width \(r.content.width) at scale \(scale)")
            #expect(r.content.height == r.content.height.rounded(.down), "height \(r.content.height) at scale \(scale)")
        }
        let five = (0..<5).map { s("\($0)", state: [.waiting, .done, .running, .running, .idle][$0]) }
        let row = FlockLayout.layout(.expanded(five, showCollapse: true), metrics: .init(scale: scale))
        let pile = FlockLayout.layout(FlockModel.merged(five), metrics: .init(scale: scale))
        let shift = row.content.maxX - pile.content.maxX
        #expect(shift == shift.rounded(.down), "right-edge alignment shift \(shift) at scale \(scale)")
    }
}
