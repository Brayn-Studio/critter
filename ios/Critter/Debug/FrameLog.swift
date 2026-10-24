#if DEBUG
import Foundation

/// `-critterFrameLog`: every 10 seconds, "frames <n> (board <b>, home <h>)" on standard output, n being how many
/// ticks changed the picture on any Critter stage in those 10 seconds (`CritterStageView.framesDrawn`), and in
/// brackets the same for each screen a stage has been on (`critterFrameTag`: the home screen with its sheets, the
/// board, "other" for the rest), 0 for one that drew nothing. For the power check: Critters that are all asleep
/// change a few times a second (the snoring z), in the background nothing is drawn, and while the board is up the
/// home screen under it draws nothing.
@MainActor
enum FrameLog {
    private static var timer: Timer?
    private static var last = 0
    private static var lastByTag: [String: Int] = [:]

    static func start() {
        guard timer == nil else { return }
        last = CritterStageView.framesDrawn
        lastByTag = CritterStageView.framesByTag
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated {
                let total = CritterStageView.framesDrawn
                let byTag = CritterStageView.framesByTag
                let tags = byTag.keys.sorted().map { "\($0) \(byTag[$0, default: 0] - lastByTag[$0, default: 0])" }
                let detail = tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))"
                FileHandle.standardOutput.write(Data("frames \(total - last)\(detail)\n".utf8))
                last = total
                lastByTag = byTag
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
#endif
