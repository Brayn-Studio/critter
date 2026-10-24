import CritterClient
import CritterKit
import SwiftUI

// The bottom sheet the answer card and the session details share (visual design §7, §8.5, §8.6; Android
// `SheetScaffold`). Drawn by the app rather than the system's `.sheet`, so it can move as the design says: up in
// 300 ms with a slight overshoot at the end, then the content is told it has settled (its Critter looks up at you);
// down in 200 ms; a 150 ms fade both ways under reduce motion. A tap on the scrim, a drag down on the top of the
// sheet, or VoiceOver's escape closes it. It rises with the keyboard and keeps clear of the home indicator.

extension View {
    /// Shows `content` for `item` in a sheet over this view while `item` is set; setting it to nil closes the sheet
    /// (it slides away first). A drag that starts within `handle` points of the sheet's top can pull it down;
    /// `meadowTop` content starts at the very top (it begins with a meadow) and the grabber is drawn light over it.
    func sheetShell<Item: Identifiable, Content: View>(
        item: Binding<Item?>, handle: CGFloat = 110, meadowTop: Bool = false,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        overlay {
            SheetHost(item: item, handle: handle, meadowTop: meadowTop, content: content)
        }
    }
}

/// Closes the sheet the view is in, as `dismiss` does for a system sheet. Nothing outside a sheet.
struct SheetCloseAction {
    let run: () -> Void

    func callAsFunction() {
        run()
    }
}

extension EnvironmentValues {
    /// Closes the sheet this view is in (it slides away).
    @Entry var closeSheet = SheetCloseAction {}
    /// Whether the sheet this view is in has come to rest after opening: the cue for "looks at you".
    @Entry var sheetSettled = false
}

private struct SheetHost<Item: Identifiable, Content: View>: View {
    @Binding var item: Item?
    let handle: CGFloat
    let meadowTop: Bool
    let content: (Item) -> Content

    @Environment(\.reduceMotion) private var reduceMotion
    /// What is on screen: it stays while the sheet slides away after `item` was cleared.
    @State private var shown: Item?
    @State private var settled = false
    @State private var drag: CGFloat = 0
    /// Counts the openings and closings: a late completion of an earlier one does nothing.
    @State private var generation = 0

    /// The enter curve: `cubic-bezier(.18, .9, .28, 1.08)`, which overshoots by about 1.7 % at the end.
    private static var enter: Animation { .timingCurve(0.18, 0.9, 0.28, 1.08, duration: 0.3) }
    private static var exit: Animation { .easeIn(duration: 0.2) }
    private static var fade: Animation { .easeInOut(duration: 0.15) }
    /// Room above the sheet, below the status bar, where the scrim always shows.
    private static var topRoom: CGFloat { 24 }
    /// Where the content starts under the grabber (the mockups' 10 pt padding and 2 pt margins around it).
    private static var contentTop: CGFloat { 31 }
    /// How far below its bottom edge the sheet is painted, so the overshoot never opens a gap under it.
    private static var below: CGFloat { 80 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                if shown != nil {
                    Theme.scrim
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { item = nil }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
                if let shown {
                    sheet(content(shown), maxHeight: max(proxy.size.height - Self.topRoom, 0))
                        .id(shown.id)
                        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(SheetSlide()))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .onChange(of: item?.id, initial: true) { _, _ in present() }
    }

    private func sheet(_ content: Content, maxHeight: CGFloat) -> some View {
        SheetFit(maxHeight: maxHeight) {
            content
                .environment(\.sheetSettled, settled)
                .environment(\.closeSheet, SheetCloseAction { item = nil })
                .foregroundStyle(Theme.ink)
                .padding(.top, meadowTop ? 0 : Self.contentTop)
                .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) {
            Theme.surface
                .padding(.bottom, -Self.below)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .clipShape(SheetEdge(below: Self.below))
        .overlay(alignment: .top) {
            Grabber(onMeadow: meadowTop)
                .padding(.top, meadowTop ? 8 : 12)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dragDown)
        .offset(y: drag)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { item = nil }
    }

    /// A drag that starts on the top of the sheet pulls it down; let go far or fast enough, it closes.
    private var dragDown: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard value.startLocation.y < handle else { return }
                drag = max(0, value.translation.height)
            }
            .onEnded { value in
                guard value.startLocation.y < handle else { return }
                if value.translation.height > 110 || value.predictedEndTranslation.height > 260 {
                    item = nil
                } else {
                    withAnimation(reduceMotion ? Self.fade : .spring(response: 0.3, dampingFraction: 0.8)) { drag = 0 }
                }
            }
    }

    /// Opens, switches or closes the sheet to match `item`.
    private func present() {
        generation += 1
        let current = generation
        if let item {
            guard shown?.id != item.id else { return }
            settled = false
            drag = 0
            withAnimation(reduceMotion ? Self.fade : Self.enter) {
                shown = item
            } completion: {
                if generation == current { settled = true }
            }
        } else if shown != nil {
            withAnimation(reduceMotion ? Self.fade : Self.exit) {
                shown = nil
            }
        }
    }
}

/// The content at its own height, offered `maxHeight` at most: short content keeps its height, long content is
/// held to `maxHeight` and scrolls inside (a `frame(maxHeight:)` would take all of it).
private struct SheetFit: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: maxHeight)) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The sheet comes up from below the screen and goes back down there.
private struct SheetSlide: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.offset(y: phase.isIdentity ? 0 : 1200)
    }
}

/// The sheet's outline: 6 pt steps at the top corners, and on down `below` past its bottom edge.
private struct SheetEdge: Shape {
    let below: CGFloat

    func path(in rect: CGRect) -> Path {
        PixelShape(step: 6, topOnly: true).path(in: CGRect(
            x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + below
        ))
    }
}

/// 40 × 5: the line colour with a darker bottom row; over a meadow, a light bar on the sky.
private struct Grabber: View {
    let onMeadow: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(onMeadow ? Theme.knob.opacity(0.7) : Theme.line)
            if !onMeadow {
                Rectangle().fill(Theme.shade).frame(height: 2)
            }
        }
        .frame(width: 40, height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: - What sheets share

/// A sheet that only has something to say ("正在连接电脑…").
struct SheetMessage: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.nunito(size: 16, weight: .heavy))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 30)
    }
}

/// The top of an answer card (Android `SheetHeader`, the mockups' `.hdr`): the session's Critter on a 72 × 64 tile
/// of grass on the waiting colour, then the `title` in 18 pt and "folder · branch · source".
struct SheetHeader: View {
    let manifest: SkinManifest
    let state: PetState
    let activity: String?
    let title: String
    let session: BridgeSession?
    let control: CritterStageControl

    var body: some View {
        HStack(spacing: 12) {
            PetTile(manifest: manifest, state: state, activity: activity, control: control)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.nunito(size: 18, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if let session {
                    PlaceRow(session: session)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The 72 × 64 tile: the waiting colour, an 8 pt strip of grass, the live Critter standing on it at 3 pt a cell,
/// never dimmed. Once the sheet has settled, it looks up at you.
struct PetTile: View {
    let manifest: SkinManifest
    let state: PetState
    let activity: String?
    let control: CritterStageControl

    @Environment(\.sheetSettled) private var settled
    @Environment(\.colorScheme) private var colorScheme

    private static let size = CGSize(width: 72, height: 64)
    private static let grass: CGFloat = 8
    private static let cell: CGFloat = 3

    var body: some View {
        let sky = SkyColors.of(colorScheme == .dark ? .night : .day)
        let slot = CritterSlot(
            sessionId: LonePet.petId, manifest: manifest, state: state, activity: activity, dimStrength: 0,
            origin: CGPoint(x: (Self.size.width - 18 * Self.cell) / 2, y: Self.size.height - Self.grass),
            scale: Self.cell
        )
        ZStack(alignment: .bottom) {
            Theme.waitBg
            VStack(spacing: 0) {
                Color(rgb: sky.grassHi).frame(height: 2)
                Color(rgb: sky.grass).frame(height: Self.grass - 2)
            }
            CritterStage(slots: [slot], control: control)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(PixelShape(step: 4))
        .accessibilityHidden(true)
        .onChange(of: settled, initial: true) { _, settled in
            guard settled else { return }
            // The stage may only just be in place (the card came after the sheet settled).
            Task { @MainActor in
                await Task.yield()
                control.lookAtYou(LonePet.petId)
            }
        }
    }
}
