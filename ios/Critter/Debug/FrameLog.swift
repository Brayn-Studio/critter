#if DEBUG
import Foundation

/// `-critterFrameLog`: every 10 seconds, "frames <n>" on standard output, n being how many ticks changed the picture
/// on any Critter stage in those 10 seconds (`CritterStageView.framesDrawn`). For the power check: Critters that
/// are all asleep change a few times a second (the snoring z), and in the background nothing is drawn.
@MainActor
enum FrameLog {
    private static var timer: Timer?
    private static var last = 0

    static func start() {
        guard timer == nil else { return }
        last = CritterStageView.framesDrawn
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated {
                let total = CritterStageView.framesDrawn
                FileHandle.standardOutput.write(Data("frames \(total - last)\n".utf8))
                last = total
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
#endif
