import CritterClient
import CritterKit
import SwiftUI

/// A patch of meadow with one live Critter on it (Android `PetStage`): the empty home screen's sleeper, the answer
/// card's tile, the details' meadow, the gallery's skies. It fills the room it is given; the Critter stands
/// `groundInset` above the bottom edge, `cell` points a cell, in the middle or with its base box from `petX`.
/// Decorative Critters are `bright` (no idle dimming, visual design §8.2); one that is not dims like an idle one on
/// the Mac. The sky follows the clock (`SkyClock`) unless `time` fixes it. Hand it a `control` for one-off motions on
/// its Critter (`LonePet.petId`): `lookAtYou`, `notice`…
struct LonePet: View {
    let skin: SkinManifest
    var state: PetState
    var activity: String?
    var sleeping = false
    var cell: CGFloat = 4
    var groundInset: CGFloat = 22
    var bright = true
    var time: SkyTime?
    /// Where the base box's column 0 goes, from the left; nil centres the Critter.
    var petX: CGFloat?
    var meadowCell: CGFloat = 3
    var clouds: [CGPoint] = defaultMeadowClouds
    var moon: CGPoint = HomeMoon.standard
    var control: CritterStageControl?

    /// The session id of the one Critter, for `control`.
    static let petId = "stage"

    /// How much an idle Critter that is not `bright` is dimmed (Android `STAGE_DIM`).
    private static let dim = 0.5

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let ground = max(size.height - groundInset, 0).rounded()
            let slot = CritterSlot(
                sessionId: Self.petId, manifest: skin, state: state, activity: activity,
                dimStrength: bright ? 0 : Self.dim,
                origin: CGPoint(x: (petX ?? (size.width - 18 * cell) / 2).rounded(), y: ground), scale: cell,
                sleeping: sleeping
            )
            ZStack(alignment: .topLeading) {
                if let time {
                    MeadowBackdrop(
                        time: time, size: size, ground: ground, cell: meadowCell, clouds: clouds, moon: moon
                    )
                } else {
                    SkyClock { sky in
                        MeadowBackdrop(
                            time: sky, size: size, ground: ground, cell: meadowCell, clouds: clouds, moon: moon
                        )
                    }
                }
                CritterStage(slots: [slot], control: control)
            }
        }
        .accessibilityHidden(true)
    }
}
