import CritterClient
import CritterKit
import CoreGraphics

/// The merged pile as Critter slots, like the desktop's (Android `PileSlots`): the most urgent session in front at
/// `origin`, and up to two more behind it, shifted to the side and seated a row higher each, dimmed and still (seat
/// rows 1 and 2, which `CritterStageView` plays as `PileSeating`).
enum PileSlots {
    /// How far each back row sits to the right of the front Critter, in cells.
    private static let backDx: [CGFloat] = [4, 7]

    /// The pile is this many cells wider than one Critter.
    static let extraCells: CGFloat = 7

    /// The session id of the offline pile's one sleeper.
    static let offlineId = "offline"

    /// `sessions` (the pile's, in order) as slots: the back rows first, so the lead is drawn over them.
    static func build(
        _ sessions: [BridgeSession], library: PhoneSkinLibrary, dim: Double, origin: CGPoint, scale: CGFloat
    ) -> [CritterSlot] {
        guard !sessions.isEmpty, case .merged(let lead, _, _) = PhoneFlock.merged(sessions) else { return [] }
        var out: [CritterSlot] = []
        for (i, session) in sessions.filter({ $0.id != lead.id }).prefix(backDx.count).enumerated() {
            let at = CGPoint(x: origin.x + backDx[i] * scale, y: origin.y)
            out.append(slot(session, library: library, dim: dim, origin: at, scale: scale, seatRow: i + 1))
        }
        out.append(slot(lead, library: library, dim: dim, origin: origin, scale: scale))
        return out
    }

    /// The offline pile: one grey, sleeping Critter.
    static func offline(
        skin: String, library: PhoneSkinLibrary, dim: Double, origin: CGPoint, scale: CGFloat
    ) -> CritterSlot {
        CritterSlot(
            sessionId: offlineId, manifest: library.manifest(skin), state: .idle, activity: nil, dimStrength: dim,
            origin: origin, scale: scale, sleeping: true
        )
    }

    /// One session's Critter at `origin`.
    static func slot(
        _ session: BridgeSession, library: PhoneSkinLibrary, dim: Double, origin: CGPoint, scale: CGFloat,
        seatRow: Int? = nil
    ) -> CritterSlot {
        CritterSlot(
            sessionId: session.id, manifest: library.manifest(session.skin), state: session.state,
            activity: session.activity, dimStrength: dim, origin: origin, scale: scale, seatRow: seatRow
        )
    }
}
