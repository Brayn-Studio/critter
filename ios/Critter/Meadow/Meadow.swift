import CritterClient
import CritterKit
import SwiftUI
import UIKit

/// The home screen's meadow (mockup "首页", Android `Meadow`): `height` of sky and grass, the ground `ground` from
/// the top, and the sessions standing on it in one row (`BoardLayout.placeRow`) at 3 pt a cell, on one live
/// `CritterStage`. Each has its name on a tag at its feet; one in `pending` wears the orange "等你确认" bubble above
/// its head. More than five merge into a pile, the most urgent in front, with "n 个会话" below it and the counts
/// that need a look above. One carried away from its place leaves its tag as its home and hides its bubble until it
/// has walked back. `offline` puts them all to sleep, greyed like idle ones, and drops the bubbles. With `opening`,
/// the first time there are Critters they pop up one by one (`appear`, 80 ms apart) and `onOpening` is told.
/// A tap on a Critter is `onTap` with its session id.
struct Meadow: View {
    let sessions: [BridgeSession]
    /// The sessions that wear the "等你确认" bubble.
    let pending: Set<String>
    let skins: PhoneSkinLibrary
    /// How much idle and done Critters are dimmed (the Mac's `idleDim`).
    var dim: Double
    let time: SkyTime
    var offline = false
    var height: CGFloat = 236
    var ground: CGFloat = 200
    var moon: CGPoint = HomeMoon.standard
    var opening = false
    var onOpening: () -> Void = {}
    let onTap: (String) -> Void

    @State private var stage = CritterStageControl()
    /// Carried away from their place, until they have walked back (`onCarry`).
    @State private var carried: Set<String> = []
    /// Whether the opening has had its chance in this meadow.
    @State private var risen = false

    /// Points per cell (design §8.3).
    private static let scale: CGFloat = 3
    private static let margin: CGFloat = 12
    private static let maxPerRow = 5
    private static let openingStagger: Duration = .milliseconds(80)
    /// The clear space kept between two neighbours' name tags.
    private static let tagGap: CGFloat = 4
    /// Tags, bubbles and counts may reach this close to the meadow's sides (the Critters keep `margin`).
    private static let edge: CGFloat = 4
    /// The base box is this many cells wide.
    private static let columns: CGFloat = 18

    /// Only the pile's states that need a look are counted above it (as on the board).
    private static let counted: Set<PetState> = [.waiting, .error, .done]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let layout = BoardLayout.placeRow(
                count: sessions.count, width: width, ground: ground, scale: Self.scale, margin: Self.margin,
                maxPerRow: Self.maxPerRow
            )
            let shown = layout.pileFrom.map { Array(sessions.prefix($0)) } ?? sessions
            let pile = layout.pileFrom.map { Array(sessions.dropFirst($0)) } ?? []
            let slots = slots(layout: layout, shown: shown, pile: pile)
            ZStack(alignment: .topLeading) {
                MeadowBackdrop(time: time, size: CGSize(width: width, height: height), ground: ground, moon: moon)
                CritterStage(
                    slots: slots, carryOnDrag: true, control: stage,
                    onTap: onTap,
                    onCarry: { id, away in
                        if away { carried.insert(id) } else { carried.remove(id) }
                    }
                )
                labels(layout: layout, shown: shown, pile: pile, width: width)
                    .allowsHitTesting(false)
            }
            .onChange(of: slots.isEmpty, initial: true) { _, empty in
                // Before the first frame with Critters, so they never stand there before popping up.
                guard !empty, !risen else { return }
                risen = true
                if opening {
                    stage.riseAll(stagger: Self.openingStagger)
                    onOpening()
                }
            }
        }
        .frame(height: height)
        .onChange(of: sessions.map(\.id)) { _, ids in
            carried.formIntersection(ids)
        }
        // The cards below say all of it; the Critters are there to be looked at and touched.
        .accessibilityHidden(true)
    }

    // MARK: - The Critters

    private func slots(layout: BoardLayout.Layout, shown: [BridgeSession], pile: [BridgeSession]) -> [CritterSlot] {
        var out: [CritterSlot] = []
        for (i, point) in layout.slots.enumerated() {
            let origin = CGPoint(x: point.x.rounded(), y: ground)
            if i < shown.count {
                out.append(PileSlots.slot(shown[i], library: skins, dim: dim, origin: origin, scale: Self.scale))
            } else {
                out += PileSlots.build(pile, library: skins, dim: dim, origin: origin, scale: Self.scale)
            }
        }
        guard offline else { return out }
        return out.map { slot in
            var slot = slot
            slot.state = .idle
            slot.activity = nil
            slot.sleeping = true
            return slot
        }
    }

    // MARK: - Tags, bubbles and counts

    @ViewBuilder
    private func labels(layout: BoardLayout.Layout, shown: [BridgeSession], pile: [BridgeSession], width: CGFloat) -> some View {
        let sky = SkyColors.of(time)
        let indices = Array(layout.slots.indices)
        let centers = indices.map { i in
            // A Critter's base box; the pile's is `PileSlots.extraCells` wider.
            let cells = i == layout.pileFrom ? Self.columns + PileSlots.extraCells : Self.columns
            return layout.slots[i].x.rounded() + cells / 2 * Self.scale
        }
        let headTop = ground - 21 * Self.scale
        let counts = pile.isEmpty ? [] : Self.counts(pile)
        let bubbles = indices.map { i -> String? in
            guard i < shown.count, !offline, pending.contains(shown[i].id) else { return nil }
            return "等你确认"
        }
        // What stands above the heads: a bubble, or the pile's counts.
        let above = indices.map { i in i < shown.count ? bubbles[i] != nil : !counts.isEmpty }
        let tagTexts = indices.map { i in i < shown.count ? shown[i].name : "\(pile.count) 个会话" }
        // How wide each label would like to be (1 pt spare for rounding); a short one leaves its neighbour more room.
        // The pile's counts are not measured: they take their full half.
        let tagWidths = tagTexts.map { MeadowTag.width($0) }
        let bubbleWidths = bubbles.map { text in text.map(MeadowBubble.width) ?? .greatestFiniteMagnitude }
        ZStack(alignment: .topLeading) {
            ForEach(indices, id: \.self) { i in
                let tagRoom = LabelRoom.room(
                    centers: centers, natural: tagWidths, index: i, width: width, gap: Self.tagGap, edge: Self.edge
                )
                let aboveRoom = LabelRoom.room(
                    centers: centers, natural: bubbleWidths, index: i, width: width, gap: 0, edge: Self.edge,
                    taken: { above[$0] }
                )
                MeadowTag(text: tagTexts[i], sky: sky)
                    .frame(maxWidth: tagRoom)
                    .frame(width: tagRoom, alignment: .top)
                    .offset(x: centers[i] - tagRoom / 2, y: ground + 5)
                if i < shown.count {
                    if let text = bubbles[i], !carried.contains(shown[i].id) {
                        // The tail's tip stays 5 pt below the head line; a larger font grows the bubble upwards.
                        MeadowBubble(text: text)
                            .frame(maxWidth: aboveRoom)
                            .frame(width: aboveRoom, height: headTop + 5, alignment: .bottom)
                            .offset(x: centers[i] - aboveRoom / 2)
                    }
                } else if !counts.isEmpty {
                    PileCounts(counts: counts, sky: sky)
                        .frame(maxWidth: aboveRoom)
                        .frame(width: aboveRoom, height: headTop, alignment: .bottom)
                        .offset(x: centers[i] - aboveRoom / 2)
                }
            }
        }
    }

    private static func counts(_ pile: [BridgeSession]) -> [StateCount] {
        guard case .merged(_, let counts, _) = PhoneFlock.merged(pile) else { return [] }
        return counts.filter { counted.contains($0.state) }
    }
}

// MARK: - Pieces

/// The width `text` takes in Nunito at `size` and `weight`, scaled with the text size like `Font.nunito`.
func nunitoWidth(_ text: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
    let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .nunito(size: size, weight: weight))
    return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
}

/// A name tag on the meadow (white, dark at night), one line, cut short when there is no room.
struct MeadowTag: View {
    let text: String
    let sky: SkyColors

    private static let fontSize: CGFloat = 10.5
    private static let padding: CGFloat = 6

    /// How wide the tag would like to be, with 1 pt spare.
    static func width(_ text: String) -> CGFloat {
        nunitoWidth(text, size: fontSize, weight: .heavy) + 2 * padding + 1
    }

    var body: some View {
        Text(verbatim: text)
            .font(.nunito(size: Self.fontSize, weight: .heavy))
            .foregroundStyle(Color(rgb: sky.tagInk))
            .lineLimit(1)
            .padding(.horizontal, Self.padding)
            .frame(minHeight: 15)
            .background(Color(rgb: sky.tag, opacity: sky.tagOpacity), in: PixelShape(step: 2))
    }
}

/// The orange bubble above a Critter that is waiting for you, its stepped tail pointing down at it (the mockups'
/// `.mbub.wait`).
struct MeadowBubble: View {
    let text: String

    private static let fontSize: CGFloat = 11.5
    private static let padding: CGFloat = 9

    /// How wide the bubble would like to be, with 1 pt spare.
    static func width(_ text: String) -> CGFloat {
        nunitoWidth(text, size: fontSize, weight: .black) + 2 * padding + 1
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: text)
                .font(.nunito(size: Self.fontSize, weight: .black))
                .foregroundStyle(Theme.inkOnWait)
                .lineLimit(1)
                .padding(.horizontal, Self.padding)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .pixelSurface(fill: Theme.wait, lip: Color.black.opacity(0.12), step: 3, lipHeight: 2)
            BubbleTail(color: Theme.wait)
        }
    }
}

/// A bubble's tail: a row of three 2 × 3 pt cells and the middle one under it.
struct BubbleTail: View {
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().frame(width: 6, height: 3)
            Rectangle().frame(width: 2, height: 3)
        }
        .foregroundStyle(color)
    }
}

/// The pile's counts above it: each state's mark in its colour and the number in pixel digits.
private struct PileCounts: View {
    let counts: [StateCount]
    let sky: SkyColors

    var body: some View {
        HStack(spacing: 7) {
            ForEach(counts, id: \.state) { count in
                HStack(spacing: 3) {
                    PixelIconView(.forState(count.state))
                        .foregroundStyle(count.state == .waiting ? Theme.waitDeep : Theme.state(count.state).glyph)
                    Text(verbatim: "\(count.count)")
                        .font(.silkscreen(size: 11.5))
                        .foregroundStyle(Color(rgb: sky.tagInk))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 3)
        .background(Color(rgb: sky.tag, opacity: sky.tagOpacity), in: PixelShape(step: 2))
    }
}
